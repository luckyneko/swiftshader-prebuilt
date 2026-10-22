#!/usr/bin/env bash
# Fetch one upstream SwiftShader commit and prove it is that commit before anything is built.
#
# SwiftShader publishes no releases and no tags — only commits — so a commit ID is the only pin
# there is. It is also a strong one: git derives the ID from the content, so a tree that checks
# out as <commit> IS that tree, whichever server delivered it. There is no signature to verify,
# and googlesource's generated archives are not byte-stable, so there is no tarball worth hashing.
#
# Patches in patches/*.patch are applied in name order and listed in the manifest. There are none
# unless one has been deliberately carried; see the README.
#
# The .git directory is removed once the commit is proven. SwiftShader's CMake reaches for the
# network whenever it sees one — it downloads a Gerrit commit hook into it, and runs
# `git submodule update` for any submodule an option needs — so without it the build stays
# offline, and a submodule the options were not meant to need fails loudly instead of being
# fetched quietly.
#
# Usage: scripts/fetch-source.sh <commit> [<revision>]
#
# <revision> (r2, r3, ...) re-releases the same commit when the build itself changed; it only
# extends the release tag.

set -euo pipefail

COMMIT="${1:?usage: fetch-source.sh <commit> [<revision>]}"
REVISION="${2:-}"
# D:/a/... rather than /d/a/... under Git Bash: cmake, python and the compilers are native tools.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && { pwd -W 2>/dev/null || pwd; })"
SRC="${ROOT}/src"
TREE="${SRC}/swiftshader"
UPSTREAM="https://swiftshader.googlesource.com/SwiftShader"
# Fetch from a local clone instead (development only: the manifest still names UPSTREAM, and
# the commit is still verified).
REMOTE="${SWIFTSHADER_FETCH_FROM:-${UPSTREAM}}"

if [[ ! "${COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
	echo "commit must be a full 40-character SHA-1, not '${COMMIT}': an abbreviation is not a pin" >&2
	exit 1
fi
if [[ -n "${REVISION}" && ! "${REVISION}" =~ ^r[0-9]+$ ]]; then
	echo "revision must look like r2, not '${REVISION}'" >&2
	exit 1
fi

mkdir -p "${SRC}"
rm -rf "${TREE}"
git init -q "${TREE}"
cd "${TREE}"
# Line endings exactly as committed (Git for Windows defaults to CRLF, which would make patches
# apply differently per platform), and paths past MAX_PATH, which LLVM's tree has.
git config core.autocrlf false
git config core.longpaths true

echo "==> fetching ${COMMIT} from ${REMOTE}"
git fetch -q --depth 1 --no-tags "${REMOTE}" "${COMMIT}"
git -c advice.detachedHead=false checkout -q FETCH_HEAD

actual="$(git rev-parse HEAD)"
if [[ "${actual}" != "${COMMIT}" ]]; then
	echo "fetched ${actual}, not the pinned ${COMMIT}" >&2
	exit 1
fi
echo "  commit ok: ${actual}"

committed="$(git log -1 --format=%cI HEAD)"
# The release tag sorts by upstream date and still names the commit: 2026.10.14-cddb5c91.
tag="$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y.%m.%d HEAD)-${COMMIT:0:8}${REVISION:+-${REVISION}}"

patches=()
if compgen -G "${ROOT}/patches/*.patch" >/dev/null; then
	for p in "${ROOT}"/patches/*.patch; do
		echo "==> applying $(basename "${p}")"
		git apply --verbose "${p}"
		patches+=("$(basename "${p}")")
	done
fi

rm -rf .git

# Everything later steps need to know about the source, from one place.
cat > "${SRC}/SOURCE.env" <<EOF
SWIFTSHADER_UPSTREAM=${UPSTREAM}
SWIFTSHADER_COMMIT=${COMMIT}
SWIFTSHADER_COMMITTED=${committed}
SWIFTSHADER_TAG=${tag}
SWIFTSHADER_PATCHES="${patches[*]:-}"
EOF
echo "==> ${TREE} (release tag ${tag})"
