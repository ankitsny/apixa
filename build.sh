#!/bin/bash
# Builds Apixa.app next to this script. Needs Xcode (or Command Line Tools) plus the Metal toolchain.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# Core Image kernels (Metal). Needs the Metal toolchain: xcodebuild -downloadComponent MetalToolchain
xcrun -sdk macosx metal -fcikernel -c Kernels/ApixaKernels.ci.metal -o .build/ApixaKernels.air
xcrun -sdk macosx metallib -cikernel .build/ApixaKernels.air -o .build/ApixaKernels.metallib
cp .build/ApixaKernels.metallib .build/release/   # for command-line runs of .build/release/Apixa

APP="Apixa.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Apixa "$APP/Contents/MacOS/Apixa"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/ApixaKernels.metallib "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP" >/dev/null

echo ""
echo "✅ Built: $(pwd)/$APP"
echo "   Run:   open \"$APP\""
echo "   Install: mv \"$APP\" /Applications/"
