#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="URL to Profile Router"
OUT="build/$APP.app"
rm -rf build
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
swiftc -O -o "$OUT/Contents/MacOS/Router" Core.swift main.swift -framework AppKit
cp Info.plist "$OUT/Contents/Info.plist"
cp rules.conf "$OUT/Contents/Resources/rules.conf"
/usr/bin/swift icon.swift build/icon.png
mkdir -p build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$OUT/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset build/icon.png
ls -lh "$OUT/Contents/MacOS/Router"
