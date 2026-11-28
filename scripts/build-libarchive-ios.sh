#!/usr/bin/env bash
set -euo pipefail

# Builds libarchive once as LibArchive.xcframework: a static library per SDK
# that the app links to read ZIP, RAR (4 and 5) and 7z archives. liblzma from
# XZ Utils is built first and merged into the same library, so the app links
# one file; zlib and bzip2 come from the iOS SDK (the module map links them).
#
# Only reading is of interest here. The command line tools, tests and every
# optional compression or crypto library other than liblzma, zlib and bzip2
# are switched off. On Apple platforms libarchive uses CommonCrypto by itself
# (ZIP AES and the digests), so OpenSSL is not needed.
#
# The framework's Headers/ holds archive.h, archive_entry.h and a module map,
# so Swift code can say `import LibArchive`.
#
# libarchive is BSD-2-Clause and liblzma (XZ Utils) is 0BSD.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

XZ_VERSION="5.8.4"
XZ_SHA256="4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b"
XZ_URL="https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.xz"

LIBARCHIVE_VERSION="3.8.11"
LIBARCHIVE_SHA256="a3dc0872b1b39da34dc18ef1b944f0f11ffd37425d70ae04be679279f1cf43d2"
LIBARCHIVE_URL="https://github.com/libarchive/libarchive/releases/download/v${LIBARCHIVE_VERSION}/libarchive-${LIBARCHIVE_VERSION}.tar.xz"

BUILD_ROOT="${PROJECT_DIR}/build/libarchive"
OUTPUT="${PROJECT_DIR}/build/LibArchive.xcframework"
# The app's minimum iOS version.
DEPLOYMENT_TARGET="16.0"

if [[ -e "${OUTPUT}" ]]; then
    echo "${OUTPUT} already exists; remove the generated build directory before rebuilding." >&2
    exit 1
fi

mkdir -p "${BUILD_ROOT}"

# fetch_source <url> <sha256> <tarball>
# Downloads the tarball (with retries) unless a copy with the right checksum is
# already there, and checks the checksum.
fetch_source() {
    local url="$1"
    local sha256="$2"
    local tarball="$3"
    local attempt downloaded=0
    if [[ ! -f "${tarball}" ]] || ! echo "${sha256}  ${tarball}" | shasum -a 256 -c - >/dev/null 2>&1; then
        rm -f "${tarball}"
        for attempt in 1 2 3 4; do
            if curl -fL --retry 3 -o "${tarball}.part" "${url}"; then
                downloaded=1
                break
            fi
            echo "Download failed (attempt ${attempt}); retrying." >&2
            sleep $((attempt * 5))
        done
        if [[ "${downloaded}" != 1 ]]; then
            echo "Could not download ${url}" >&2
            exit 1
        fi
        mv "${tarball}.part" "${tarball}"
    fi
    echo "${sha256}  ${tarball}" | shasum -a 256 -c -
}

XZ_TARBALL="${BUILD_ROOT}/xz-${XZ_VERSION}.tar.xz"
LIBARCHIVE_TARBALL="${BUILD_ROOT}/libarchive-${LIBARCHIVE_VERSION}.tar.xz"
fetch_source "${XZ_URL}" "${XZ_SHA256}" "${XZ_TARBALL}"
fetch_source "${LIBARCHIVE_URL}" "${LIBARCHIVE_SHA256}" "${LIBARCHIVE_TARBALL}"

XZ_SOURCE="${BUILD_ROOT}/xz-source"
LIBARCHIVE_SOURCE="${BUILD_ROOT}/libarchive-source"
rm -rf "${XZ_SOURCE}" "${LIBARCHIVE_SOURCE}"
mkdir -p "${XZ_SOURCE}" "${LIBARCHIVE_SOURCE}"
tar -xf "${XZ_TARBALL}" -C "${XZ_SOURCE}" --strip-components 1
tar -xf "${LIBARCHIVE_TARBALL}" -C "${LIBARCHIVE_SOURCE}" --strip-components 1

JOBS="$(sysctl -n hw.ncpu)"

# build_arch <slice> <sdk> <arch>
# Builds liblzma and then libarchive for one architecture and leaves one merged
# static library at ${BUILD_ROOT}/<slice>/<arch>/libarchive-merged.a, with the
# public headers in ${BUILD_ROOT}/<slice>/<arch>/install/include. Each
# architecture gets its own CMake run, so that every feature check (CRC
# instructions, for example) is answered for that architecture alone.
build_arch() {
    local slice="$1"
    local sdk="$2"
    local arch="$3"
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
    local root="${BUILD_ROOT}/${slice}/${arch}"
    local xz_install="${root}/xz-install"
    local install_dir="${root}/install"
    rm -rf "${root}"
    mkdir -p "${root}"

    # The same platform flags go to both CMake runs.
    local platform_flags=(
        -DCMAKE_SYSTEM_NAME=iOS
        -DCMAKE_OSX_SYSROOT="${sdk}"
        -DCMAKE_OSX_ARCHITECTURES="${arch}"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DBUILD_SHARED_LIBS=OFF
    )

    echo "Building liblzma ${XZ_VERSION} for ${slice} (${arch})"
    cmake -S "${XZ_SOURCE}" -B "${root}/xz-build" \
        "${platform_flags[@]}" \
        -DCMAKE_INSTALL_PREFIX="${xz_install}" \
        -DBUILD_TESTING=OFF \
        -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF \
        -DXZ_TOOL_SCRIPTS=OFF -DXZ_DOC=OFF -DXZ_DOXYGEN=OFF -DXZ_NLS=OFF
    cmake --build "${root}/xz-build" -j"${JOBS}"
    cmake --install "${root}/xz-build"
    test -f "${xz_install}/lib/liblzma.a"

    echo "Building libarchive ${LIBARCHIVE_VERSION} for ${slice} (${arch})"
    cmake -S "${LIBARCHIVE_SOURCE}" -B "${root}/libarchive-build" \
        "${platform_flags[@]}" \
        -DCMAKE_INSTALL_PREFIX="${install_dir}" \
        -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF -DENABLE_TEST=OFF \
        -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_CNG=OFF \
        -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_BSDXML=OFF \
        -DENABLE_ZSTD=OFF -DENABLE_LZ4=OFF -DENABLE_LIBB2=OFF -DENABLE_LZO=OFF \
        -DENABLE_PCREPOSIX=OFF -DENABLE_PCRE2POSIX=OFF -DENABLE_LIBGCC=OFF \
        -DENABLE_ACL=OFF -DENABLE_XATTR=OFF -DENABLE_ICONV=OFF \
        -DENABLE_LZMA=ON \
        -DLIBLZMA_INCLUDE_DIR="${xz_install}/include" \
        -DLIBLZMA_LIBRARY="${xz_install}/lib/liblzma.a" \
        -DENABLE_ZLIB=ON \
        -DZLIB_INCLUDE_DIR="${sdk_path}/usr/include" \
        -DZLIB_LIBRARY="${sdk_path}/usr/lib/libz.tbd" \
        -DENABLE_BZip2=ON \
        -DBZIP2_INCLUDE_DIR="${sdk_path}/usr/include" \
        -DBZIP2_LIBRARIES="${sdk_path}/usr/lib/libbz2.tbd"
    cmake --build "${root}/libarchive-build" -j"${JOBS}"
    cmake --install "${root}/libarchive-build"
    test -f "${install_dir}/lib/libarchive.a"

    # One static library with liblzma inside.
    libtool -static -o "${root}/libarchive-merged.a" \
        "${install_dir}/lib/libarchive.a" "${xz_install}/lib/liblzma.a"
}

# check_library <library>
# Makes sure the merged library holds what the app needs: the readers, the
# passphrase call, the UTF-8 name accessor and the liblzma decoder.
check_library() {
    local library="$1"
    local symbol
    for symbol in archive_read_new archive_read_support_format_zip archive_read_support_format_rar \
        archive_read_support_format_rar5 archive_read_support_format_7zip archive_read_open_filenames \
        archive_read_add_passphrase archive_entry_pathname archive_entry_pathname_utf8 \
        lzma_stream_decoder lzma_raw_decoder; do
        if ! nm -gU "${library}" 2>/dev/null | grep " _${symbol}$" >/dev/null; then
            echo "${library} does not define ${symbol}." >&2
            exit 1
        fi
    done
    lipo -info "${library}"
    ls -l "${library}"
}

# The module map the app imports. zlib and bzip2 are system libraries.
write_module_map() {
    local headers="$1"
    cat > "${headers}/module.modulemap" <<'EOF'
module LibArchive [system] {
    header "archive.h"
    header "archive_entry.h"
    link "z"
    link "bz2"
    export *
}
EOF
}

build_arch ios-arm64 iphoneos arm64
build_arch ios-arm64_x86_64-simulator iphonesimulator arm64
build_arch ios-arm64_x86_64-simulator iphonesimulator x86_64

DEVICE_LIBRARY="${BUILD_ROOT}/ios-arm64/arm64/libarchive-merged.a"
SIMULATOR_LIBRARY="${BUILD_ROOT}/ios-arm64_x86_64-simulator/libarchive-merged.a"
lipo -create \
    "${BUILD_ROOT}/ios-arm64_x86_64-simulator/arm64/libarchive-merged.a" \
    "${BUILD_ROOT}/ios-arm64_x86_64-simulator/x86_64/libarchive-merged.a" \
    -output "${SIMULATOR_LIBRARY}"
check_library "${DEVICE_LIBRARY}"
check_library "${SIMULATOR_LIBRARY}"

# The headers are the same for every architecture; take them from the device
# build and keep only the two the module map names.
HEADERS="${BUILD_ROOT}/Headers"
rm -rf "${HEADERS}"
mkdir -p "${HEADERS}"
cp "${BUILD_ROOT}/ios-arm64/arm64/install/include/archive.h" "${HEADERS}/"
cp "${BUILD_ROOT}/ios-arm64/arm64/install/include/archive_entry.h" "${HEADERS}/"
write_module_map "${HEADERS}"

xcodebuild -create-xcframework \
    -library "${DEVICE_LIBRARY}" -headers "${HEADERS}" \
    -library "${SIMULATOR_LIBRARY}" -headers "${HEADERS}" \
    -output "${OUTPUT}"

test -f "${OUTPUT}/Info.plist"
echo "Created ${OUTPUT}"
