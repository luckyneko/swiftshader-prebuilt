#!/usr/bin/env bash
# Package a checked build into its release archive, with the manifest and licence texts that make
# it redistributable.
#
# Naming: swiftshader-<tag>-<platform>.tar.gz, where <tag> is <upstream commit date>-<commit>, so
# releases sort by upstream date and every name still says exactly what it was built from.
#
# The files sit at the archive's ROOT, not under a top-level directory. The ICD manifest names
# its library as "./<library>", relative to itself, so the two only have to stay side by side;
# a consumer stages them straight from the extracted tree. FetchContent treats either layout the
# same way, but this one is what was asked of the consumer contract.
#
# Usage: scripts/package.sh <platform>

set -euo pipefail

PLATFORM="${1:?usage: package.sh <platform>}"
# D:/a/... rather than /d/a/... under Git Bash: cmake, python and the compilers are native tools.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && { pwd -W 2>/dev/null || pwd; })"
# shellcheck source=/dev/null
source "${ROOT}/platforms/${PLATFORM}.conf"
# shellcheck source=/dev/null
source "${ROOT}/licenses/third-party.conf"
# shellcheck source=/dev/null
source "${ROOT}/src/SOURCE.env"

SRC="${ROOT}/src/swiftshader"
OUT="${ROOT}/out/${PLATFORM}"
DIST="${ROOT}/dist"
name="swiftshader-${SWIFTSHADER_TAG}-${PLATFORM}"
stage="${ROOT}/stage/${name}"

sha256() { (command -v sha256sum >/dev/null && sha256sum "$1" || shasum -a 256 "$1") | cut -d' ' -f1; }

rm -rf "${stage}"
mkdir -p "${stage}" "${DIST}"
cp "${OUT}/vk_swiftshader_icd.json" "${OUT}/${PLATFORM_LIBRARY}" "${stage}/"

# Upstream's licence, and the licence of everything compiled in with it — the part prebuilt
# binaries usually leave out. check.sh has already proved this list covers the link step.
cp "${SRC}/LICENSE.txt" "${stage}/LICENSE.txt"
{
	echo "Third-party components compiled into ${PLATFORM_LIBRARY}. SwiftShader's own licence is"
	echo "LICENSE.txt."
	for e in "${THIRD_PARTY_LICENSES[@]}"; do
		component="${e%%|*}"
		file="${e#*|}"
		[[ -f "${ROOT}/${file}" ]] && path="${ROOT}/${file}" || path="${SRC}/${file}"
		echo
		echo "================================================================================"
		echo "${component} (${file})"
		echo "================================================================================"
		echo
		cat "${path}"
	done
} > "${stage}/THIRD_PARTY_LICENSES.txt"

if [[ -n "${SWIFTSHADER_PATCHES}" ]]; then
	patch_lines=""
	for p in ${SWIFTSHADER_PATCHES}; do
		patch_lines+="  ${p}  sha256 $(sha256 "${ROOT}/patches/${p}")"$'\n'
	done
	patch_lines+="  The patches are in the build repo below, at the commit named here."
else
	patch_lines="  none"
fi

# The manifest makes the archive self-describing: what it was built from, how, and what the
# driver reported about itself when it was checked — readable without loading anything.
cat > "${stage}/MANIFEST.txt" <<EOF
swiftshader-prebuilt
  release          ${SWIFTSHADER_TAG}
  platform         ${PLATFORM}
  built            $(date -u +%Y-%m-%dT%H:%M:%SZ)
  build repo       ${BUILD_REPO_URL:-https://github.com/luckyneko/swiftshader-prebuilt}
  build commit     ${BUILD_COMMIT:-unknown}

upstream source
  ${SWIFTSHADER_UPSTREAM}
  commit           ${SWIFTSHADER_COMMIT}
  committed        ${SWIFTSHADER_COMMITTED}

patches
${patch_lines}

build
$(sed 's/^/  /' "${ROOT}/out/${PLATFORM}.build.txt")

contents
$(printf '  %-26s %s\n' \
	vk_swiftshader_icd.json "the ICD manifest; library_path is relative to it" \
	"${PLATFORM_LIBRARY}" "sha256 $(sha256 "${OUT}/${PLATFORM_LIBRARY}")" \
	LICENSE.txt "SwiftShader (Apache-2.0)" \
	THIRD_PARTY_LICENSES.txt "$(echo "${THIRD_PARTY_LICENSES[@]%%|*}")")

as reported by the driver when checked (tools/icdprobe.c)
$(sed 's/^/  /' "${ROOT}/out/${PLATFORM}.probe.txt")
EOF

# Plain ownership, and no macOS metadata: bsdtar otherwise adds ._ AppleDouble entries for any
# extended attribute, which extract as stray files beside the driver everywhere else.
files=(vk_swiftshader_icd.json "${PLATFORM_LIBRARY}" LICENSE.txt THIRD_PARTY_LICENSES.txt MANIFEST.txt)
archive="${DIST}/${name}.tar.gz"
rm -f "${archive}"
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
	# --force-local: on Windows the archive path is D:/..., which GNU tar would otherwise read
	# as host "D" and try to reach over rsh.
	tar -C "${stage}" --owner=0 --group=0 --numeric-owner --force-local -czf "${archive}" "${files[@]}"
else
	COPYFILE_DISABLE=1 tar -C "${stage}" --uid 0 --gid 0 --no-xattrs --no-mac-metadata -czf "${archive}" "${files[@]}"
fi

hash="$(sha256 "${archive}")"
echo "${hash}  ${name}.tar.gz" > "${archive}.sha256"
echo "==> ${archive}"
echo "  sha256 ${hash}"
tar -tvzf "${archive}"
