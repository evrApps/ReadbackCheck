#!/bin/bash
# Copyright (C) 2026 Antonio Marogna — EVRApps
# SPDX-License-Identifier: GPL-3.0-only

# Build "Readback Check.app" for development, in ./build.
#
#   ./build_app.sh
#
# This app runs engine/verify_offload_app.py from this source tree with a
# system Python 3, so it only works on the Mac that built it. For an app that
# runs anywhere, use build_portable.sh. Universal (arm64 + x86_64), macOS 14+.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/Readback Check.app"
VERSION=1.0
BUILD=1

cd "$HERE"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ReadbackCheck"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/icon/AppIcon.icns" "$APP/Contents/Resources/"
cp "$BIN" "$APP/Contents/MacOS/ReadbackCheck"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ReadbackCheck</string>
    <key>CFBundleIdentifier</key><string>com.evrapps.readbackcheck</string>
    <key>CFBundleName</key><string>Readback Check</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null
echo "built: $APP"
lipo -info "$APP/Contents/MacOS/ReadbackCheck"
