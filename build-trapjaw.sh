#!/bin/bash
#
# build-trapjaw.sh — Cross-compile libtrapjaw.a and trapjaw.metallib for iOS.
#
# Usage:
#   ./build-trapjaw.sh [device|simulator|all]
#
# Outputs:
#   lib/iphoneos/libtrapjaw.a         — ARM64 static library (device)
#   lib/iphonesimulator/libtrapjaw.a  — x86_64+ARM64 static library (simulator)
#   lib/trapjaw.metallib              — Compiled Metal shader library (iOS)
#
# Prerequisites:
#   - Xcode with iOS SDK installed
#   - CMake 3.20+

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBMODULE_DIR="$SCRIPT_DIR/trapjaw"
OUTPUT_DIR="$SCRIPT_DIR/lib"
DEPLOYMENT_TARGET="18.0"

TARGET="${1:-all}"

# ── Validate environment ─────────────────────────────────────────────────

if ! command -v cmake &>/dev/null; then
    echo "Error: cmake not found. Install via 'brew install cmake'."
    exit 1
fi

if ! command -v xcrun &>/dev/null; then
    echo "Error: xcrun not found. Install Xcode command line tools."
    exit 1
fi

if [ ! -d "$SUBMODULE_DIR/include/trapjaw" ]; then
    echo "Error: trapjaw submodule not initialized. Run 'git submodule update --init'."
    exit 1
fi

# ── Metal shader compilation (iOS) ───────────────────────────────────────

compile_metal_shaders() {
    echo "==> Compiling Metal shaders for iOS..."

    local SHADER_DIR="$SUBMODULE_DIR/shaders"
    local METAL_BUILD_DIR="$OUTPUT_DIR/metal-build"
    mkdir -p "$METAL_BUILD_DIR"

    local AIR_FILES=()
    for shader in "$SHADER_DIR"/*.metal; do
        local name
        name="$(basename "$shader" .metal)"
        local air_file="$METAL_BUILD_DIR/$name.air"

        echo "    Compiling: $name.metal"
        xcrun -sdk iphoneos metal \
            -target air64-apple-ios${DEPLOYMENT_TARGET} \
            -c "$shader" \
            -I "$SHADER_DIR" \
            -o "$air_file"

        AIR_FILES+=("$air_file")
    done

    echo "    Linking metallib..."
    xcrun -sdk iphoneos metallib "${AIR_FILES[@]}" -o "$OUTPUT_DIR/trapjaw.metallib"

    # Clean intermediate files
    rm -rf "$METAL_BUILD_DIR"

    echo "==> Metal shaders compiled: $OUTPUT_DIR/trapjaw.metallib"
}

# ── CMake cross-compile ──────────────────────────────────────────────────

build_for_platform() {
    local PLATFORM="$1"   # iphoneos or iphonesimulator
    local ARCHS="$2"
    local BUILD_DIR="$SCRIPT_DIR/trapjaw-build/$PLATFORM"
    local LIB_OUTPUT="$OUTPUT_DIR/$PLATFORM"

    echo "==> Building libtrapjaw.a for $PLATFORM ($ARCHS)..."

    mkdir -p "$BUILD_DIR" "$LIB_OUTPUT"

    local SDK_PATH
    SDK_PATH="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"

    cmake -S "$SUBMODULE_DIR" -B "$BUILD_DIR" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-fembed-bitcode" \
        -G "Unix Makefiles" \
        2>&1 | sed 's/^/    /'

    # Build only the static library target (skip CLI, tests, fixtures)
    cmake --build "$BUILD_DIR" --target trapjaw -j "$(sysctl -n hw.ncpu)" \
        2>&1 | sed 's/^/    /'

    cp "$BUILD_DIR/libtrapjaw.a" "$LIB_OUTPUT/libtrapjaw.a"

    echo "==> Built: $LIB_OUTPUT/libtrapjaw.a"
}

# ── Main ─────────────────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"

compile_metal_shaders

case "$TARGET" in
    device)
        build_for_platform "iphoneos" "arm64"
        ;;
    simulator)
        build_for_platform "iphonesimulator" "arm64;x86_64"
        ;;
    all)
        build_for_platform "iphoneos" "arm64"
        build_for_platform "iphonesimulator" "arm64;x86_64"
        ;;
    *)
        echo "Usage: $0 [device|simulator|all]"
        exit 1
        ;;
esac

# Clean CMake build directories
rm -rf "$SCRIPT_DIR/trapjaw-build"

echo ""
echo "==> Build complete. Outputs:"
echo "    $OUTPUT_DIR/trapjaw.metallib"
ls -la "$OUTPUT_DIR"/*/libtrapjaw.a 2>/dev/null | awk '{print "    " $NF " (" $5 " bytes)"}'
