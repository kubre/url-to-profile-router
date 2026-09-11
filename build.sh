#!/bin/sh
set -e
cd "$(dirname "$0")"
APP="URL to Profile Router"
rm -rf build
mkdir -p "build/$APP.app/Contents/MacOS" "build/$APP.app/Contents/Resources"
swiftc -O -o "build/$APP.app/Contents/MacOS/Router" main.swift -framework AppKit
cp Info.plist "build/$APP.app/Contents/Info.plist"
cp rules.json "build/$APP.app/Contents/Resources/rules.json"
# icon: drawn by icon.swift, converted to .icns (repo stays source-only)
/usr/bin/swift icon.swift "build/icon_1024.png"
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "build/$APP.app/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "build/icon_1024.png"
mkdir -p ~/.config
[ -f ~/.config/url-router.json ] || cp rules.json ~/.config/url-router.json
ls -lh "build/$APP.app/Contents/MacOS/Router"
echo "built build/$APP.app — run ./install.sh"
