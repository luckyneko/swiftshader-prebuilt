# swiftshader-prebuilt

Prebuilt [SwiftShader](https://swiftshader.googlesource.com/SwiftShader) Vulkan drivers for Linux,
macOS and Windows, each pinned to one upstream commit and **verified to load and work before
publication**.

SwiftShader is a CPU implementation of Vulkan 1.3. It is what makes a Vulkan device available where no
GPU driver works — CI runners, containers, sandboxed processes — or on the CPU by choice. Upstream
publishes no binaries: it has no releases and no tags, only commits. A project that wants to ship it
beside its own executables, as [archimedes](https://github.com/luckyneko/archimedes) does for its CPU
device, has to build it. This repository builds it once per platform for a pinned commit and
publishes archives that a build system can pin by hash.

## The point: a driver that loads anywhere, not just where it was built

A green build says very little about a driver. Every one of these builds cleanly, and then fails
only on someone else's machine:

| failure | why CI would not notice |
| --- | --- |
| the ICD manifest names its library by an absolute path, or by a bare filename | the loader **silently skips** a manifest it cannot use; the symptom is "no CPU device" |
| the dylib's minimum macOS is the build machine's | SwiftShader sets no deployment target: a build on macOS 26 came out `minos 26.0` |
| the `.so` needs a newer glibc than the user has | the runner always has its own glibc |
| the DLL imports `VCRUNTIME140.dll` | every runner has Visual Studio installed; a clean Windows does not |
| a third-party library is linked in without its licence | nothing reads licences at build time |

So [`scripts/check.sh`](scripts/check.sh) checks each of these against the built files, not against
the build flags, before anything is packaged:

| check | asserted of the built driver |
| --- | --- |
| ICD manifest | parses; `library_path` is relative **and** contains a separator (the loader resolves `./lib` against the manifest, but searches the system for a bare `lib`), and resolves to the library beside it |
| driver | [`tools/icdprobe.c`](tools/icdprobe.c) loads the library **through that manifest's path**, as the loader would, negotiates the loader–ICD interface, and requires a **CPU** device reporting **Vulkan ≥ 1.3** with **synchronization2** and **dynamicRendering**. It then creates a device with both enabled |
| self-contained | depends on nothing outside the OS: system frameworks and `/usr/lib` (macOS), `/lib` and `/usr/lib` with no rpath (Linux), System32 DLLs and no Visual C++ runtime (Windows) |
| thread cap | `SWIFTSHADER_THREAD_COUNT` of 1 and 3 start worker pools exactly two threads apart (see [Threads](#threads)) |
| OS floor | `minos 11.0` (macOS), newest `GLIBC_` symbol ≤ 2.35 (Linux) |
| licences | every `third_party/` directory on the driver's actual link step has its licence in [`licenses/third-party.conf`](licenses/third-party.conf) |
| signature | the macOS dylib's ad-hoc code signature is valid (arm64 will not load one that is not) |

The probe's report goes into the archive's manifest, so what the driver said about itself is
readable without loading anything.

## Artifacts

```
swiftshader-<tag>-<platform>.tar.gz
```

where `<tag>` is the upstream commit date and commit, e.g. `2026.10.14-cddb5c91`. Releases sort by
upstream date, and every name still says exactly what it was built from.

| platform | built on | runs on |
| --- | --- | --- |
| `linux-x64` | ubuntu-22.04, GCC 12 | glibc ≥ 2.35 |
| `macos-arm64` | macos-15, Apple clang | macOS ≥ 11 |
| `windows-x64` | windows-2022, MSVC, static CRT | Windows 10 and later |

Each archive holds, **at its root**:

| file | |
| --- | --- |
| `vk_swiftshader_icd.json` | the ICD manifest; its `library_path` is relative to itself |
| `libvk_swiftshader.so` / `libvk_swiftshader.dylib` / `vk_swiftshader.dll` | the driver |
| `LICENSE.txt` | SwiftShader's licence (Apache-2.0) |
| `THIRD_PARTY_LICENSES.txt` | the licences of LLVM, marl, SPIRV-Tools, SPIRV-Headers and astc-encoder, which are compiled in |
| `MANIFEST.txt` | upstream commit, patches, toolchain, exact CMake arguments, the library's SHA256, and the probe's report |

The files are at the root rather than under a top-level directory because the manifest and the library
only need to stay side by side: a consumer points the Vulkan loader at the extracted
`vk_swiftshader_icd.json` (`VK_ADD_DRIVER_FILES`, or `VK_ICD_FILENAMES` to make it the only driver)
or stages both files next to its executable.

SwiftShader's build also produces a copy of the driver under the **loader's** name
(`libvulkan.so.1`, `libvulkan.dylib`, `vulkan-1.dll`), for applications that skip the loader. That
copy is deliberately **not** shipped: beside the ICD it would shadow the real Vulkan loader for
anything whose library search reaches that directory.

Every release carries `SHA256SUMS`. Pin against it:

```cmake
FetchContent_Declare(SwiftShader
	URL      https://github.com/luckyneko/swiftshader-prebuilt/releases/download/<tag>/swiftshader-<tag>-<platform>.tar.gz
	URL_HASH SHA256=<from SHA256SUMS>
)
```

A published release is never replaced: the workflow refuses a tag that already exists, because
replacing an asset would break every consumer's pin at once. A rebuild of a commit that is already
published takes a revision suffix (`2026.10.14-cddb5c91-r2`).

### macOS: Gatekeeper and browser downloads

The dylib is ad-hoc signed (the Apple Silicon linker default) but **not notarized**, which needs a
paid Apple Developer identity. Downloading the archive **in a browser** sets
`com.apple.quarantine`, and macOS then refuses to load the driver. Clear the attribute after
extracting:

```sh
xattr -dr com.apple.quarantine <extracted-dir>
```

Downloads by tooling are unaffected: `curl`, `wget`, CMake's `file(DOWNLOAD)` and therefore
`FetchContent` do not set the attribute.

### Threads

SwiftShader runs shaders on its own worker pool, started with the first `VkDevice`: by default one
thread per logical CPU, up to 16. Upstream reads a different count only from `ThreadCount` in a
`SwiftShader.ini` in the process's **working directory**, which a library loading the driver cannot
rely on controlling, so a host with its own process-wide thread pool would oversubscribe the CPU.

These builds therefore carry one patch: **`SWIFTSHADER_THREAD_COUNT`**, set to 1–256 before the
first `VkDevice` is created, sizes the pool, overriding the ini file. Any other value is ignored with
a warning. The probe's `threads started by vkCreateDevice` line is the pool plus one further
SwiftShader thread, so the manifest shows both the default and the capped count.

## Provenance

[`scripts/fetch-source.sh`](scripts/fetch-source.sh) fetches the pinned commit from
`swiftshader.googlesource.com` and requires the checked-out `HEAD` to **be** that commit. A commit
ID is the only pin SwiftShader offers — no releases, no tags, no signatures — and it is a strong one:
git derives the ID from the content, so a tree that checks out as the commit is that tree, whichever
server delivered it. googlesource's generated archives are not byte-stable, so there is no tarball
worth hashing.

The `.git` directory is then removed. SwiftShader's CMake reaches for the network whenever it sees
one — it downloads a Gerrit commit hook, and runs `git submodule update` for any submodule an
option needs — so without it the build stays offline, and a submodule nobody meant to need fails
loudly instead of being fetched quietly.

One patch is applied, [`patches/0001-thread-count-from-environment.patch`](patches/0001-thread-count-from-environment.patch)
(see [Threads](#threads)). Patches live in `patches/`, are applied in name order, are named with
their SHA256 in every manifest, and mark the code they change as modified, as Apache-2.0 §4(b)
asks. Everything else is upstream exactly as committed.

## Building

```sh
scripts/fetch-source.sh cddb5c91b23ff70a1f607ea31610aa0d7f4b5ad5
PLATFORM=macos-arm64 scripts/build.sh
scripts/check.sh macos-arm64
scripts/package.sh macos-arm64
```

Requires CMake 3.22–3.31 (CMake 4 refuses the vendored marl, which still declares
`cmake_minimum_required(VERSION 3.0)`), Ninja, Python 3 and a C++17 compiler. On Windows, run the
scripts from Git Bash inside an x64 Visual Studio developer environment.

The CMake line is composed from exactly two parts — a fixed common set in `build.sh` and the
platform's [conf](platforms/) — and nothing else may add flags, so the arguments recorded in the
manifest are the whole configuration.

Releases are **manual dispatch only** (`.github/workflows/release.yml`), with `publish` off by
default: a release is something consumers pin, so it should be a decision someone makes, not
something a push triggers.

## Using these binaries

You are redistributing SwiftShader if you ship them. It is Apache-2.0, and so are most of the
components compiled into it (LLVM's with the LLVM exception; SPIRV-Headers is MIT-style). Keep
`LICENSE.txt` and `THIRD_PARTY_LICENSES.txt` with the driver.

The build scripts in this repository are MIT-licensed. SwiftShader itself is not, and its own
licence terms govern the binaries.
