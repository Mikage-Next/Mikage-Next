#!/usr/bin/env bash
set -euo pipefail

# Builds the pinned siglus_rs fork (SiglusEngine, Rust) as
# SiglusRuntime.xcframework: one dynamic framework per SDK holding the
# siglus_scene_vm cdylib. It needs a Rust toolchain with the iOS targets
# (rustup target add aarch64-apple-ios aarch64-apple-ios-sim). It does not use
# SDL; FFmpeg's H.264 decoder (the shared FFmpeg.framework) decodes the UCI
# images some repacks put in .g00 files (Engine/SiglusRuntime/H264Decoder.c).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${PROJECT_DIR}/Engine/SiglusRuntime/Source"
HEADER="${SOURCE_DIR}/platform/ios/SiglusLauncher/Headers/siglus.h"
BUILD_ROOT="${PROJECT_DIR}/build/siglus"
OUTPUT="${PROJECT_DIR}/build/SiglusRuntime.xcframework"
# Matches the other engine runtimes.
DEPLOYMENT_TARGET="13.0"
CRATE="siglus_scene_vm"
FRAMEWORK_NAME="SiglusRuntime"

if [[ -e "${OUTPUT}" ]]; then
    echo "${OUTPUT} already exists; remove the generated build directory before rebuilding." >&2
    exit 1
fi

if [[ ! -f "${SOURCE_DIR}/Cargo.toml" || ! -f "${HEADER}" ]]; then
    echo "siglus_rs source submodule is missing. Run: git submodule update --init Engine/SiglusRuntime/Source" >&2
    exit 1
fi

command -v cargo >/dev/null 2>&1 || { echo "cargo not found; install Rust with rustup." >&2; exit 1; }

# The shared FFmpeg.xcframework (scripts/build-ffmpeg-ios.sh) that the app
# embeds once for every engine.
FFMPEG_XCFRAMEWORK="${PROJECT_DIR}/build/FFmpeg.xcframework"
H264_DECODER="${PROJECT_DIR}/Engine/SiglusRuntime/H264Decoder.c"
if [[ ! -f "${FFMPEG_XCFRAMEWORK}/ios-arm64/FFmpeg.framework/FFmpeg" || ! -f "${FFMPEG_XCFRAMEWORK}/ios-arm64-simulator/FFmpeg.framework/FFmpeg" ]]; then
    echo "Shared FFmpeg is missing. Run: bash scripts/build-ffmpeg-ios.sh" >&2
    exit 1
fi

export IPHONEOS_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}"
export CARGO_TARGET_DIR="${BUILD_ROOT}/target"

build_slice() {
    local target="$1"
    local slice="$2"
    local sdk="$3"
    local ffmpeg_framework="$4"
    local clang_target="$5"
    echo "Building ${CRATE} for ${target}"
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"

    local decoder="${BUILD_ROOT}/${slice}/H264Decoder.o"
    mkdir -p "${BUILD_ROOT}/${slice}"
    xcrun --sdk "${sdk}" clang -c -O2 -Wall -Werror \
        -target "${clang_target}" -isysroot "${sdk_path}" \
        -I "$(dirname "${HEADER}")" -I "${ffmpeg_framework}/Headers" \
        "${H264_DECODER}" -o "${decoder}"

    local link_args=()
    for arg in "${decoder}" -F "$(dirname "${ffmpeg_framework}")" -framework FFmpeg; do
        link_args+=(-C "link-arg=${arg}")
    done

    # Only the dynamic library: its exports are the C API, and the staticlib
    # and the engine's desktop binaries are not needed here.
    SDKROOT="${sdk_path}" \
        cargo rustc --manifest-path "${SOURCE_DIR}/Cargo.toml" \
            -p "${CRATE}" --lib --release --locked \
            --target "${target}" --crate-type cdylib \
            -- "${link_args[@]}"

    local dylib="${CARGO_TARGET_DIR}/${target}/release/lib${CRATE}.dylib"
    if [[ ! -f "${dylib}" ]]; then
        echo "cargo did not produce ${dylib}." >&2
        exit 1
    fi

    local framework="${BUILD_ROOT}/${slice}/${FRAMEWORK_NAME}.framework"
    rm -rf "${framework}"
    mkdir -p "${framework}/Headers" "${framework}/Modules"
    cp "${dylib}" "${framework}/${FRAMEWORK_NAME}"
    install_name_tool -id "@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" "${framework}/${FRAMEWORK_NAME}"
    cp "${HEADER}" "${framework}/Headers/siglus.h"
    cat > "${framework}/Headers/${FRAMEWORK_NAME}.h" <<'EOF'
#include "siglus.h"
EOF
    cat > "${framework}/Modules/module.modulemap" <<EOF
framework module ${FRAMEWORK_NAME} {
    umbrella header "${FRAMEWORK_NAME}.h"
    export *
}
EOF
    local platform="iPhoneOS"
    [[ "${sdk}" == "iphonesimulator" ]] && platform="iPhoneSimulator"
    cat > "${framework}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key><string>moe.cheney233.mikage.SiglusRuntime</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>${platform}</string></array>
    <key>MinimumOSVersion</key><string>${DEPLOYMENT_TARGET}</string>
</dict>
</plist>
EOF

    local binary="${framework}/${FRAMEWORK_NAME}"
    for symbol in siglus_ios_create siglus_ios_touch siglus_mikage_step siglus_mikage_register_font siglus_mikage_set_resource_names siglus_mikage_register_fallback_font siglus_mikage_set_log_callback siglus_mikage_register_font_face siglus_mikage_set_h264_decoder; do
        if ! nm -gU "${binary}" | grep " _${symbol}$" >/dev/null; then
            echo "${binary} does not export ${symbol}." >&2
            exit 1
        fi
    done
    # FFmpeg comes from the shared framework, not a copy of its own.
    if ! otool -L "${binary}" | grep "@rpath/FFmpeg.framework/FFmpeg" >/dev/null; then
        echo "${binary} does not link the shared FFmpeg.framework." >&2
        exit 1
    fi
    if nm -U "${binary}" | grep -E " _avcodec_(open2|send_packet)$" >/dev/null; then
        echo "${binary} still contains its own FFmpeg." >&2
        exit 1
    fi
}

build_slice aarch64-apple-ios ios-arm64 iphoneos \
    "${FFMPEG_XCFRAMEWORK}/ios-arm64/FFmpeg.framework" "arm64-apple-ios${DEPLOYMENT_TARGET}"
build_slice aarch64-apple-ios-sim ios-arm64-simulator iphonesimulator \
    "${FFMPEG_XCFRAMEWORK}/ios-arm64-simulator/FFmpeg.framework" "arm64-apple-ios${DEPLOYMENT_TARGET}-simulator"

xcodebuild -create-xcframework \
    -framework "${BUILD_ROOT}/ios-arm64/${FRAMEWORK_NAME}.framework" \
    -framework "${BUILD_ROOT}/ios-arm64-simulator/${FRAMEWORK_NAME}.framework" \
    -output "${OUTPUT}"

test -f "${OUTPUT}/Info.plist"
echo "Created ${OUTPUT}"
