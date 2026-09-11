#!/bin/sh
set -eu
cd "$(dirname "$0")"
[ "$(uname -s)" = Darwin ] || { echo 'Building the app requires macOS and Xcode Command Line Tools. Core tests: ./test.sh' >&2; exit 1; }
APP='URL to Profile Router'
ARCH=${ARCH:-$(uname -m)}
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported ARCH=$ARCH; use arm64 or x86_64." >&2; exit 1 ;; esac
SWIFTC=$(xcrun --find swiftc)
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
mkdir -p build
STAGE=$(mktemp -d "$PWD/build/.router-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 1' HUP INT TERM
BUNDLE="$STAGE/$APP.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
"$SWIFTC" -swift-version 5 -Osize -whole-module-optimization -target "$ARCH-apple-macosx$MIN_OS" \
    -Xlinker -dead_strip -o "$BUNDLE/Contents/MacOS/Router" RouterCore.swift main.swift -framework AppKit -framework CoreServices
strip -x "$BUNDLE/Contents/MacOS/Router"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp rules.conf "$BUNDLE/Contents/Resources/rules.conf"
/usr/bin/swift icon.swift "$STAGE/icon_1024.png"
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$STAGE/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$STAGE/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
plutil -lint "$BUNDLE/Contents/Info.plist"
codesign --force --sign - "$BUNDLE"
codesign --verify --strict "$BUNDLE"
# Only replace build output after compilation, resources and signing succeed.
rm -rf "build/$APP.app"
mv "$BUNDLE" "build/$APP.app"
BUNDLE="build/$APP.app"
{
    echo "Architecture: $ARCH; minimum macOS: $MIN_OS"
    "$SWIFTC" --version
    printf 'Executable bytes: '; stat -f %z "$BUNDLE/Contents/MacOS/Router"
    printf 'Icon bytes: '; stat -f %z "$BUNDLE/Contents/Resources/AppIcon.icns"
    printf 'App payload bytes (sum of regular files): '
    find "$BUNDLE" -type f -exec stat -f %z {} + | awk '{total += $1} END {printf "%.0f\n", total}'
} | tee build/size-report.txt
printf '\nBuilt %s. Install with ./install.sh\n' "$BUNDLE"
