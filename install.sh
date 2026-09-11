#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="URL to Profile Router"
DEST="/Applications/$APP.app"
NEW="/Applications/.$APP.new.app"
OLD="/Applications/.$APP.old.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

./build.sh
rm -rf "$NEW" "$OLD"
cp -R "build/$APP.app" "$NEW"
codesign --force --sign - "$NEW"
codesign --verify --strict "$NEW"

if [ -e "$DEST" ]; then
  ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)
  [ "$ID" = "com.vaibhav.urlrouter" ] || { echo "refusing to replace $DEST: bundle id is $ID" >&2; rm -rf "$NEW"; exit 1; }
  mv "$DEST" "$OLD"
fi
if ! mv "$NEW" "$DEST"; then
  [ ! -e "$OLD" ] || mv "$OLD" "$DEST"
  exit 1
fi
rm -rf "$OLD"
"$LSREG" -f "$DEST"
echo "installed $DEST"
