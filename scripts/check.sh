#!/usr/bin/env bash
# Prove a built driver is what its archive will claim, BEFORE it is packaged or published.
#
# The claim is: a Vulkan 1.3 CPU driver that loads from wherever the archive is extracted, on the
# oldest OS the platform targets, needing nothing the OS does not provide. Every part of that can
# be false while the build is green — each failure below builds fine and breaks only on someone
# else's machine — so each is checked against the built files rather than inferred from flags.
#
# Usage: scripts/check.sh <platform>

set -euo pipefail

PLATFORM="${1:?usage: check.sh <platform>}"
# D:/a/... rather than /d/a/... under Git Bash: cmake, python and the compilers are native tools.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && { pwd -W 2>/dev/null || pwd; })"
# shellcheck source=/dev/null
source "${ROOT}/platforms/${PLATFORM}.conf"
# shellcheck source=/dev/null
source "${ROOT}/licenses/third-party.conf"

SRC="${ROOT}/src/swiftshader"
BUILD="${ROOT}/build/${PLATFORM}"
OUT="${ROOT}/out/${PLATFORM}"
# Not LIB: that is MSVC's library search path, already exported, and assigning it breaks the
# probe's link on Windows.
DRIVER="${OUT}/${PLATFORM_LIBRARY}"
REPORT="${ROOT}/out/${PLATFORM}.probe.txt"
# The Windows runner's python3 can be the Microsoft Store stub, so python first.
PY="$(command -v python || command -v python3)"

failures=0
fail() { echo "  *** FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "  ok: $*"; }

# The ICD manifest. The loader silently skips a manifest it cannot use, so a broken one looks
# exactly like "no CPU device" — which is all a consumer's tests would ever report. The path has
# to be relative AND contain a separator: the loader resolves "./lib" against the manifest's own
# directory, but treats a bare "lib" as a name for the system library search, which finds nothing
# (or, worse, some other copy).
echo "==> ICD manifest"
if resolved="$("${PY}" -I - "${OUT}/vk_swiftshader_icd.json" "${PLATFORM_LIBRARY}" <<'EOF'
import json, os, sys
manifest, expected = sys.argv[1], sys.argv[2]
with open(manifest) as f:
    data = json.load(f)
path = data["ICD"]["library_path"]
def die(why):
    sys.exit(f"library_path {path!r} {why}")
if os.path.isabs(path):
    die("is absolute; the archive could only be used where it was built")
if os.sep not in path and (os.altsep or "/") not in path:
    die("has no directory separator, so the loader would search the system for it")
library = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(manifest)), path))
if os.path.basename(library) != expected:
    die(f"names {os.path.basename(library)}, not {expected}")
if not os.path.isfile(library):
    die("does not resolve to a file beside the manifest")
print(f"file_format_version {data['file_format_version']}, api_version {data['ICD'].get('api_version', '?')}", file=sys.stderr)
print(library)
EOF
)"; then
	pass "library_path resolves to ${resolved}"
else
	fail "vk_swiftshader_icd.json is unusable"
	resolved="${DRIVER}"
fi

# The driver itself, loaded through the manifest's own path exactly as the loader would.
echo "==> driver"
compiler="$(sed -n 's/^CMAKE_C_COMPILER:[A-Z]*=//p' "${BUILD}/CMakeCache.txt")"
cmake -S "${ROOT}/tools" -B "${ROOT}/build/probe-${PLATFORM}" -G Ninja -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_C_COMPILER="${compiler}" -DSWIFTSHADER_INCLUDE="${SRC}/include" "${PLATFORM_CMAKE_ARGS[@]}" \
	--log-level=WARNING --no-warn-unused-cli >/dev/null
cmake --build "${ROOT}/build/probe-${PLATFORM}" >/dev/null
probe="${ROOT}/build/probe-${PLATFORM}/icdprobe"
[[ -f "${probe}.exe" ]] && probe="${probe}.exe"
if "${probe}" "${resolved}" > "${REPORT}"; then
	sed 's/^/  /' "${REPORT}"
	pass "a Vulkan 1.3 CPU device with synchronization2 + dynamicRendering"
else
	sed 's/^/  /' "${REPORT}"
	fail "the driver does not meet what the archive claims"
fi

# The thread cap patches/0001 adds. The README promises it of these archives, so it is held to
# the same standard as everything else: counts two apart must start worker pools two apart.
echo "==> SWIFTSHADER_THREAD_COUNT"
started() { SWIFTSHADER_THREAD_COUNT="$1" "${probe}" "${resolved}" | sed -n 's/^threads started by vkCreateDevice: //p'; }
one="$(started 1 || true)"
three="$(started 3 || true)"
if [[ -n "${one}" && -n "${three}" ]] && ((three - one == 2)); then
	pass "1 starts ${one} threads, 3 starts ${three}"
	echo "threads started with SWIFTSHADER_THREAD_COUNT=1: ${one}" >> "${REPORT}"
else
	fail "SWIFTSHADER_THREAD_COUNT does not size the pool: 1 started '${one}' threads, 3 started '${three}'"
fi

# Self-containment: the driver may depend on the OS and on nothing else. The build machine has
# far more on it than a user's does, so a dependency on any of it passes here and fails there.
echo "==> self-containment"
before=${failures}
case "${PLATFORM_SYSTEM}" in
Darwin)
	while IFS= read -r dep; do
		case "${dep}" in
		/usr/lib/* | /System/*) ;;
		"@rpath/${PLATFORM_LIBRARY}") ;; # its own install name
		*) fail "depends on ${dep}" ;;
		esac
	done < <(otool -L "${DRIVER}" | tail -n +2 | awk '{print $1}')
	while IFS= read -r rpath; do
		fail "carries an LC_RPATH of ${rpath}"
	done < <(otool -l "${DRIVER}" | awk '/cmd LC_RPATH/{f=1} f&&/ path /{print $2; f=0}')
	if codesign --verify "${DRIVER}" 2>/dev/null; then
		pass "code signature valid (arm64 will not load an unsigned or broken one)"
	else
		fail "code signature is invalid"
	fi
	;;
Linux)
	while IFS= read -r line; do
		case "${line}" in
		*"not found"*) fail "unresolved dependency: ${line}" ;;
		*"=> /lib/"* | *"=> /lib64/"* | *"=> /usr/lib/"* | *"=> /usr/lib64/"*) ;;
		*"=> /"*) fail "depends on a non-system path: ${line}" ;;
		esac
	done < <(ldd "${DRIVER}" | sed 's/^[[:space:]]*//')
	if readelf -d "${DRIVER}" | grep -qE 'RPATH|RUNPATH'; then
		fail "carries an rpath: $(readelf -d "${DRIVER}" | grep -E 'RPATH|RUNPATH' | sed 's/^ *//')"
	fi
	;;
Windows)
	system32="$(cygpath -u "${SYSTEMROOT}")/System32"
	while IFS= read -r dll; do
		lower="$(printf '%s' "${dll}" | tr '[:upper:]' '[:lower:]')"
		case "${lower}" in
		# Present wherever Visual Studio or the redistributable is — every CI runner — and absent
		# from a clean Windows install. The platform conf links the CRT statically for this.
		vcruntime* | msvcp* | msvcr* | concrt* | vccorlib* | vcomp* | ucrtbased*)
			fail "imports ${dll}, the Visual C++ runtime" ;;
		api-ms-win-*) ;; # an OS API set
		*) [[ -f "${system32}/${dll}" ]] || fail "imports ${dll}, which is not a Windows system DLL" ;;
		esac
	done < <(dumpbin -nologo -dependents "$(cygpath -w "${DRIVER}")" | tr -d '\r' | awk 'NF==1 && tolower($1) ~ /\.dll$/ {print $1}')
	;;
esac
((failures == before)) && pass "depends on nothing outside the OS"

# The OS floor the platform conf promises.
case "${PLATFORM_SYSTEM}" in
Darwin)
	echo "==> minimum macOS"
	minos="$(otool -l "${DRIVER}" | awk '/cmd LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
	if [[ "${minos}" == "${PLATFORM_MIN_OS}" ]]; then
		pass "minos ${minos}"
	else
		fail "minos is ${minos:-<none>}, not ${PLATFORM_MIN_OS}"
	fi
	;;
Linux)
	echo "==> minimum glibc"
	glibc="$(objdump -T "${DRIVER}" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)*' | sed 's/^GLIBC_//' | sort -uV | tail -1)"
	glibcxx="$(objdump -T "${DRIVER}" | grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)*' | sed 's/^GLIBCXX_//' | sort -uV | tail -1)"
	if [[ "$(printf '%s\n%s\n' "${glibc}" "${PLATFORM_MAX_GLIBC}" | sort -V | tail -1)" == "${PLATFORM_MAX_GLIBC}" ]]; then
		pass "newest symbol versions: GLIBC_${glibc}, GLIBCXX_${glibcxx:-none} (floor glibc ${PLATFORM_MAX_GLIBC})"
	else
		fail "requires GLIBC_${glibc}, newer than the ${PLATFORM_MAX_GLIBC} floor"
	fi
	printf 'glibc floor: %s\nlibstdc++ floor: GLIBCXX_%s\n' "${glibc}" "${glibcxx:-none}" >> "${REPORT}"
	;;
esac

# Licences, from the link step rather than from a list someone remembered to update: every
# third-party directory whose code is linked into the driver must have its licence on file. The
# link step is read from build.ninja, not from the command line, because MSVC links through a
# response file and the command line names no libraries at all.
echo "==> licences"
before=${failures}
linked="$(awk '/^build .*CXX_SHARED_LIBRARY_LINKER__vk_swiftshader_/{f=1} f&&/^$/{exit} f' "${BUILD}/build.ninja" |
	tr '\\' '/' | grep -oE 'third_party/[^/ ]+/' | sed -e 's|^third_party/||' -e 's|/$||' | sort -u)"
[[ -n "${linked}" ]] || fail "found no third-party libraries on the link step; build.ninja's layout has changed"
for component in ${linked}; do
	entry=""
	for e in "${THIRD_PARTY_LICENSES[@]}"; do
		[[ "${e%%|*}" == "${component}" ]] && entry="${e#*|}"
	done
	if [[ -z "${entry}" ]]; then
		fail "${component} is linked in, but licenses/third-party.conf has no licence for it"
	elif [[ ! -f "${ROOT}/${entry}" && ! -f "${SRC}/${entry}" ]]; then
		fail "${component}'s licence ${entry} does not exist"
	fi
done
[[ -f "${SRC}/LICENSE.txt" ]] || fail "SwiftShader's own LICENSE.txt is missing"
((failures == before)) && pass "linked: $(echo ${linked})"

echo
if ((failures)); then
	echo "FAILED (${failures} failure(s))"
	exit 1
fi
echo "PASSED — ${PLATFORM} driver matches what its archive claims"
