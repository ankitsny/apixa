#!/bin/bash
# Builds Apixa.app next to this script. Needs Xcode or Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Apixa.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Apixa "$APP/Contents/MacOS/Apixa"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null

echo ""
echo "✅ Built: $(pwd)/$APP"
echo "   Run:   open \"$APP\""
echo "   Install: mv \"$APP\" /Applications/"
