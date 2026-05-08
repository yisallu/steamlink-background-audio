#!/bin/bash
# Compile BackgroundAudio.dylib on macOS.
# Requirements: Xcode command-line tools installed (`xcode-select --install`).
# The dylib is built for arm64 iOS (device), deployment target 11.0.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="${HERE}/BackgroundAudio.dylib"

xcrun --sdk iphoneos clang \
    -arch arm64 \
    -isysroot "${SDK}" \
    -miphoneos-version-min=11.0 \
    -fobjc-arc \
    -dynamiclib \
    -install_name "@rpath/BackgroundAudio.dylib" \
    -framework Foundation \
    -framework UIKit \
    -framework AVFoundation \
    -framework MediaPlayer \
    -framework AudioToolbox \
    -framework CoreAudio \
    -o "${OUT}" \
    "${HERE}/BackgroundAudio.m"

echo "built: ${OUT}"
file "${OUT}"
