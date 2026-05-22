#!/usr/bin/env bash
#
# Determines CONFIG_RUSTC_VERSION and CONFIG_RUSTC_LLVM_VERSION from a Rust
# source tarball.
#
# Usage:
#   get-rust-kernel-config-values.sh <rust-version>
#   get-rust-kernel-config-values.sh --sdk-commit <commit-id>

set -euo pipefail

TOOLSDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

bail() {
    >&2 echo "Error: $*"
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 <rust-version>
       $0 --sdk-commit <commit-id>

Determines CONFIG_RUSTC_VERSION and CONFIG_RUSTC_LLVM_VERSION for a given
Rust release by downloading and inspecting the source tarball.

When --sdk-commit is used, the Rust version and tarball SHA are read from
the bottlerocket-sdk hashes/rust file at that commit.

Examples:
    $0 1.95.0
    $0 --sdk-commit develop
    UPSTREAM_SOURCE_FALLBACK=true $0 --sdk-commit abcd1234

Output:
    CONFIG_RUSTC_VERSION=109500
    CONFIG_RUSTC_LLVM_VERSION=220102
EOF
}

# See scripts/rust-version.sh in the kernel tree.
encode_rustc_version() {
    local version="$1"
    local major minor patch
    read -r major minor patch <<< "${version//./ }"
    echo $(( major * 100000 + minor * 100 + patch ))
}

# See scripts/cc-version.sh in the kernel tree.
encode_llvm_version() {
    local version="$1"
    local major minor patch
    read -r major minor patch <<< "${version//./ }"
    echo $(( major * 10000 + minor * 100 + patch ))
}

sdk_commit=""
rust_version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --sdk-commit)
            [[ $# -ge 2 ]] || bail "--sdk-commit requires a commit ID or ref"
            sdk_commit="$2"
            shift 2
            ;;
        *)
            rust_version="$1"
            shift
            ;;
    esac
done

if [[ -z "${sdk_commit}" ]] && [[ -z "${rust_version}" ]]; then
    usage
    exit 1
fi

tmpdir=$(mktemp -d)
cleanup() {
    if [[ $? -eq 0 ]]; then
        rm -rf "${tmpdir}"
    else
        >&2 echo "Temp directory preserved at: ${tmpdir}"
    fi
}
trap cleanup EXIT

if [[ -n "${sdk_commit}" ]]; then
    >&2 echo "Fetching hashes/rust from bottlerocket-sdk at ${sdk_commit} ..."
    hashes_file="${tmpdir}/hashes-rust"
    curl -s -f -o "${hashes_file}" \
        "https://raw.githubusercontent.com/bottlerocket-os/bottlerocket-sdk/${sdk_commit}/hashes/rust" \
        || bail "Could not fetch hashes/rust from bottlerocket-sdk at '${sdk_commit}'"

    # Extract only the source tarball lines for sdk-fetch.
    src_hashes="${tmpdir}/hashes-rust-src"
    grep -E '^(# https?://.*rustc-.*-src\.tar\.xz|SHA512 \(rustc-.*-src\.tar\.xz\))' "${hashes_file}" > "${src_hashes}"

    # Parse the version from the tarball name.
    sha_line=$(grep -m1 '^SHA512' "${src_hashes}")
    tarball="${sha_line#SHA512 (}"
    tarball="${tarball%%) =*}"
    rust_version="${tarball#rustc-}"
    rust_version="${rust_version%-src.tar.xz}"
    [[ -n "${rust_version}" ]] || bail "Could not parse Rust version from hashes/rust"
    >&2 echo "Rust version: ${rust_version}"

    >&2 echo "Downloading rustc source tarball via sdk-fetch ..."
    pushd "${tmpdir}" >/dev/null
    "${TOOLSDIR}/sdk-fetch" "${src_hashes}"
    popd >/dev/null
else
    if ! [[ "${rust_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        bail "Invalid version format '${rust_version}'. Expected X.Y.Z (e.g. 1.95.0)"
    fi

    tarball="rustc-${rust_version}-src.tar.xz"
    url="https://static.rust-lang.org/dist/${tarball}"

    >&2 echo "Downloading ${url} ..."
    curl -s -C - -fSL -o "${tmpdir}/${tarball}" "${url}"
    curl -s -C - -fSL -o "${tmpdir}/${tarball}.asc" "${url}.asc"

    >&2 echo "Verifying signature ..."
    curl -s https://keybase.io/rust/pgp_keys.asc | gpg --import 2>/dev/null
    gpg --verify "${tmpdir}/${tarball}.asc" "${tmpdir}/${tarball}" \
        || bail "GPG signature verification failed for ${tarball}"
fi

>&2 echo "Extracting LLVM version info ..."
tar -xf "${tmpdir}/${tarball}" -C "${tmpdir}" \
    "rustc-${rust_version}-src/src/llvm-project/cmake/Modules/LLVMVersion.cmake"

version_file="${tmpdir}/rustc-${rust_version}-src/src/llvm-project/cmake/Modules/LLVMVersion.cmake"
if [[ ! -f "${version_file}" ]]; then
    bail "Could not find LLVMVersion.cmake in tarball"
fi

llvm_major=$(grep 'set(LLVM_VERSION_MAJOR' "${version_file}" | grep -oE '[0-9]+')
llvm_minor=$(grep 'set(LLVM_VERSION_MINOR' "${version_file}" | grep -oE '[0-9]+')
llvm_patch=$(grep 'set(LLVM_VERSION_PATCH' "${version_file}" | grep -oE '[0-9]+')

if [[ -z "${llvm_major}" ]] || [[ -z "${llvm_minor}" ]] || [[ -z "${llvm_patch}" ]]; then
    bail "Could not parse LLVM version from LLVMVersion.cmake"
fi

rustc_version_encoded=$(encode_rustc_version "${rust_version}")
llvm_version_encoded=$(encode_llvm_version "${llvm_major}.${llvm_minor}.${llvm_patch}")

echo "CONFIG_RUSTC_VERSION=${rustc_version_encoded}"
echo "CONFIG_RUSTC_LLVM_VERSION=${llvm_version_encoded}"
