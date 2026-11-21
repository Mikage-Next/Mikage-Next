#!/usr/bin/env bash
set -euo pipefail

# Builds FFmpeg once as FFmpeg.xcframework: one dynamic framework per SDK that
# the app embeds and every engine that decodes with FFmpeg links (KiriKiri,
# ONScripter, openArtemis, Ren'Py and Siglus). Before this, each of them
# linked its own static copy of every FFmpeg decoder, about 10 MB apiece.
#
# Only the decoders, demuxers and parsers in Engine/FFmpeg/components.sh are
# built. The framework's Headers/ holds the usual libavcodec/, libavformat/,
# libavutil/, libswresample/ and libswscale/ include trees, so engines keep
# writing #include <libavcodec/avcodec.h> with -I <framework>/Headers.
#
# FFmpeg is LGPL-2.1-or-later in this configuration (no --enable-gpl).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FFMPEG_VERSION="7.1.2"
FFMPEG_SHA256="089bc60fb59d6aecc5d994ff530fd0dcb3ee39aa55867849a2bbc4e555f9c304"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
PATCH_DIR="${PROJECT_DIR}/Engine/FFmpeg/patches"
BUILD_ROOT="${PROJECT_DIR}/build/ffmpeg"
OUTPUT="${PROJECT_DIR}/build/FFmpeg.xcframework"
# Matches the engine runtimes that link it.
DEPLOYMENT_TARGET="13.0"
FRAMEWORK_NAME="FFmpeg"

if [[ -e "${OUTPUT}" ]]; then
    echo "${OUTPUT} already exists; remove the generated build directory before rebuilding." >&2
    exit 1
fi

# shellcheck source=../Engine/FFmpeg/components.sh
source "${PROJECT_DIR}/Engine/FFmpeg/components.sh"

mkdir -p "${BUILD_ROOT}"
TARBALL="${BUILD_ROOT}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
if [[ ! -f "${TARBALL}" ]] || ! echo "${FFMPEG_SHA256}  ${TARBALL}" | shasum -a 256 -c - >/dev/null 2>&1; then
    rm -f "${TARBALL}"
    for attempt in 1 2 3 4; do
        curl -fL --retry 3 -o "${TARBALL}.part" "${FFMPEG_URL}" && break
        echo "Download failed (attempt ${attempt}); retrying." >&2
        sleep $((attempt * 5))
    done
    mv "${TARBALL}.part" "${TARBALL}"
fi
echo "${FFMPEG_SHA256}  ${TARBALL}" | shasum -a 256 -c -

SOURCE="${BUILD_ROOT}/source"
rm -rf "${SOURCE}"
mkdir -p "${SOURCE}"
tar -xf "${TARBALL}" -C "${SOURCE}" --strip-components 1
for patch in "${PATCH_DIR}"/*.patch; do
    echo "Applying ${patch##*/}"
    patch -p1 --forward --quiet -d "${SOURCE}" < "${patch}"
done

hwaccel_flags=(--enable-videotoolbox)
for name in "${FFMPEG_HWACCELS[@]}"; do hwaccel_flags+=("--enable-hwaccel=${name}"); done

build_slice() {
    local slice="$1"
    local sdk="$2"
    local clang_target="$3"
    local platform="$4"
    local sdk_path cc
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
    cc="$(xcrun --sdk "${sdk}" -f clang)"
    local build_dir="${BUILD_ROOT}/${slice}/build"
    local install_dir="${BUILD_ROOT}/${slice}/install"
    rm -rf "${build_dir}" "${install_dir}"
    mkdir -p "${build_dir}"

    echo "Configuring FFmpeg ${FFMPEG_VERSION} for ${clang_target}"
    (
        cd "${build_dir}"
        "${SOURCE}/configure" \
            --prefix="${install_dir}" \
            --enable-cross-compile --target-os=darwin --arch=aarch64 \
            --cc="${cc}" --sysroot="${sdk_path}" \
            --extra-cflags="-target ${clang_target} -isysroot ${sdk_path}" \
            --extra-ldflags="-target ${clang_target} -isysroot ${sdk_path}" \
            --enable-static --disable-shared --enable-pic \
            --disable-programs --disable-doc --disable-debug \
            --disable-autodetect --disable-everything \
            --disable-network --disable-avdevice --disable-avfilter \
            --enable-avcodec --enable-avformat --enable-swresample --enable-swscale \
            --enable-zlib \
            "${hwaccel_flags[@]}" \
            "${FFMPEG_COMPONENT_FLAGS[@]}" > configure.log || { tail -n 40 ffbuild/config.log; exit 1; }
        # What the build holds, for the log.
        sed -n '/^Enabled decoders:/,/^License/p' configure.log
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )

    # One dynamic library from the five static ones. -all_load keeps every
    # object (the decoder tables reach the rest anyway); only FFmpeg's public
    # av*/sw* API is exported, which also hides its internal ff_ symbols.
    # A few helpers are compiled into more than one of the libraries (the EXR
    # decoder's half2float is also in libswscale); enabling such a component
    # makes this link fail with a duplicate symbol.
    local framework="${BUILD_ROOT}/${slice}/${FRAMEWORK_NAME}.framework"
    rm -rf "${framework}"
    mkdir -p "${framework}/Headers"
    local exports="${BUILD_ROOT}/${slice}/exports.txt"
    printf '%s\n' '_av*' '_sw*' > "${exports}"
    # System libraries and frameworks FFmpeg needs, from its pkg-config files
    # (a static build lists them on the Libs: lines).
    local private_libs
    private_libs="$(sed -n 's/^Libs\(\.private\)\{0,1\}: //p' "${install_dir}"/lib/pkgconfig/*.pc | tr ' ' '\n' \
        | grep -vE '^$|^-L|^-l(avcodec|avformat|avutil|swresample|swscale)$' | tr '\n' ' ')"
    echo "Linking ${FRAMEWORK_NAME} with: ${private_libs}"
    # shellcheck disable=SC2086
    "${cc}" -dynamiclib -target "${clang_target}" -isysroot "${sdk_path}" \
        -install_name "@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" \
        -compatibility_version 1 -current_version "${FFMPEG_VERSION}" \
        -Wl,-all_load \
        "${install_dir}/lib/libavformat.a" "${install_dir}/lib/libavcodec.a" \
        "${install_dir}/lib/libswscale.a" "${install_dir}/lib/libswresample.a" \
        "${install_dir}/lib/libavutil.a" \
        -Wl,-exported_symbols_list,"${exports}" -Wl,-dead_strip \
        ${private_libs} \
        -o "${framework}/${FRAMEWORK_NAME}"
    strip -x "${framework}/${FRAMEWORK_NAME}"
    cp -R "${install_dir}/include/." "${framework}/Headers/"
    cat > "${framework}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key><string>moe.cheney233.mikage.FFmpeg</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${FFMPEG_VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>${platform}</string></array>
    <key>MinimumOSVersion</key><string>${DEPLOYMENT_TARGET}</string>
</dict>
</plist>
EOF

    local binary="${framework}/${FRAMEWORK_NAME}"
    for symbol in avcodec_find_decoder avcodec_send_packet avformat_open_input avio_alloc_context \
        av_frame_alloc swr_alloc_set_opts2 sws_getContext sws_scale; do
        if ! nm -gU "${binary}" | grep " _${symbol}$" >/dev/null; then
            echo "${binary} does not export ${symbol}." >&2
            exit 1
        fi
    done
    if nm -gU "${binary}" | grep -E " _ff_" >/dev/null; then
        echo "${binary} exports FFmpeg internals (_ff_)." >&2
        exit 1
    fi
    ls -l "${binary}"
}

build_slice ios-arm64 iphoneos "arm64-apple-ios${DEPLOYMENT_TARGET}" iPhoneOS
build_slice ios-arm64-simulator iphonesimulator "arm64-apple-ios${DEPLOYMENT_TARGET}-simulator" iPhoneSimulator

xcodebuild -create-xcframework \
    -framework "${BUILD_ROOT}/ios-arm64/${FRAMEWORK_NAME}.framework" \
    -framework "${BUILD_ROOT}/ios-arm64-simulator/${FRAMEWORK_NAME}.framework" \
    -output "${OUTPUT}"

test -f "${OUTPUT}/Info.plist"
echo "Created ${OUTPUT}"
