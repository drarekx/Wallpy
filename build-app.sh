#!/bin/zsh
# Builds Wallpy.app (release, universal) into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Wallpy.app
VERSION=${VERSION:-1.0.0}
BUILD=${BUILD:-1}
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Wallpy

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wallpy"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Wallpy</string>
    <key>CFBundleIdentifier</key><string>com.egluu.wallpy</string>
    <key>CFBundleName</key><string>Wallpy</string>
    <key>CFBundleDisplayName</key><string>Wallpy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
(cd build && rm -f Wallpy.zip && ditto -c -k --keepParent Wallpy.app Wallpy.zip)
echo "Built $APP ($VERSION) and build/Wallpy.zip"
