#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="URL to Profile Router"
DEST="/Applications/$APP.app"

CONF_DST="$HOME/.config/url-router.conf"
CONF_SRC="rules.conf"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

OUT="build/$APP.app"
rm -rf build
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
swiftc -target "$(uname -m)-apple-macosx13.0" -O -o "$OUT/Contents/MacOS/Router" Core.swift main.swift -framework AppKit
cp Info.plist "$OUT/Contents/Info.plist"
cp rules.conf "$OUT/Contents/Resources/rules.conf"
cp AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$OUT"
codesign --verify --strict "$OUT"
SOURCE="$OUT"
STAGING=$(mktemp -d "/Applications/.url-router.XXXXXX")
NEW="$STAGING/$APP.app"
OLD="$STAGING/previous.app"
cleanup() {
  if [ -e "$OLD" ] && [ ! -e "$DEST" ]; then mv "$OLD" "$DEST"; fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cp -R "$SOURCE" "$NEW"
codesign --verify --strict "$NEW"

if [ -e "$DEST" ]; then
  ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)
  [ "$ID" = "com.vaibhav.urlrouter" ] || { echo "refusing to replace $DEST: bundle id is $ID" >&2; rm -rf "$NEW"; exit 1; }
  pkill -f "^$DEST/Contents/MacOS/Router" || true
  mv "$DEST" "$OLD"
fi
if ! mv "$NEW" "$DEST"; then
  [ ! -e "$OLD" ] || mv "$OLD" "$DEST"
  exit 1
fi
rm -rf "$OLD"
mkdir -p "$HOME/.config"
if [ ! -e "$CONF_DST" ] && [ -e "$CONF_SRC" ]; then
  cp "$CONF_SRC" "$CONF_DST"
  echo "added default config to $CONF_DST"
fi
"$LSREG" -f "$DEST"
open "$DEST" || echo "Installed, but could not open $DEST" >&2
echo "installed $DEST"
