#!/usr/bin/env bash
# Build SwiftShader's Vulkan ICD for one platform and collect the two files a consumer stages —
# the library and its ICD manifest — into out/<platform>/.
#
# The CMake line is composed from exactly two parts — the fixed common set below and the
# platform's [conf](../platforms/) — and nothing else may add flags. That is what makes the
# configuration recorded in the manifest the whole configuration.
#
# SwiftShader's build also copies the library under the loader's own name (libvulkan.dylib,
# libvulkan.so.1, vulkan-1.dll), for applications that skip the loader. That copy is
# deliberately not collected: shipped beside the ICD it would shadow the real Vulkan loader for
# anything whose library search reaches that directory.
#
# Usage: PLATFORM=<platform> scripts/build.sh

set -euo pipefail

# D:/a/... rather than /d/a/... under Git Bash: cmake, python and the compilers are native tools.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && { pwd -W 2>/dev/null || pwd; })"
PLATFORM="${PLATFORM:?set PLATFORM to one of: $(cd "${ROOT}/platforms" && ls | sed 's/\.conf$//' | tr '\n' ' ')}"
# shellcheck source=/dev/null
source "${ROOT}/platforms/${PLATFORM}.conf"

SRC="${ROOT}/src/swiftshader"
BUILD="${ROOT}/build/${PLATFORM}"
OUT="${ROOT}/out/${PLATFORM}"

COMMON_ARGS=(
	-GNinja
	-DCMAKE_BUILD_TYPE=Release
	-DSWIFTSHADER_BUILD_TESTS=OFF
	-DSWIFTSHADER_BUILD_BENCHMARKS=OFF
	# Upstream builds warning-free only with the compilers its CI pins; on any other version a new
	# diagnostic would fail the build without saying anything about the driver.
	-DSWIFTSHADER_WARNINGS_AS_ERRORS=OFF
)
args=("${COMMON_ARGS[@]}" "${PLATFORM_CMAKE_ARGS[@]}")

echo "==> configuring ${PLATFORM}"
cmake -S "${SRC}" -B "${BUILD}" "${args[@]}"

echo "==> building vk_swiftshader"
cmake --build "${BUILD}" --target vk_swiftshader

produced="${BUILD}/${PLATFORM_SYSTEM}"
rm -rf "${OUT}"
mkdir -p "${OUT}"
cp "${produced}/vk_swiftshader_icd.json" "${produced}/${PLATFORM_LIBRARY}" "${OUT}/"

# The toolchain and the exact arguments, for the manifest. Read back from what CMake resolved,
# not from what was asked for.
compiler="$(sed -n \
	-e 's/^set(CMAKE_CXX_COMPILER_ID "\(.*\)")$/\1/p' \
	-e 's/^set(CMAKE_CXX_COMPILER_VERSION "\(.*\)")$/\1/p' \
	"${BUILD}"/CMakeFiles/*/CMakeCXXCompiler.cmake | tr '\n' ' ')"
{
	echo "cmake            $(cmake --version | head -1 | awk '{print $3}')"
	echo "compiler         ${compiler% }"
	echo "target           vk_swiftshader"
	echo "arguments"
	printf '  %s\n' "${args[@]}"
} > "${ROOT}/out/${PLATFORM}.build.txt"

echo "==> ${OUT}"
ls -l "${OUT}"
