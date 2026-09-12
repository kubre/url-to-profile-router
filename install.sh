#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="URL to Profile Router"
DEST="/Applications/$APP.app"
NEW="/Applications/.$APP.new.app"
OLD="/Applications/.$APP.old.app"
CONF_DST="$HOME/.config/url-router.conf"
CONF_SRC="$(cd "$(dirname "$0")" && pwd)/rules.conf"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

./build.sh
rm -rf "$NEW" "$OLD"
cp -R "build/$APP.app" "$NEW"
codesign --force --sign - "$NEW"
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
if ! open "$DEST"; then
  if open -b com.vaibhav.urlrouter; then
    echo "installed $DEST"
    exit 0
  fi
  echo "installed $DEST"
  echo "Could not auto-open the app (LaunchServices returned -600)."
  echo "Please run:"
  echo "  open -b com.vaibhav.urlrouter"
  echo "or"
  echo "  \"$DEST/Contents/MacOS/Router\" --set-default"
  exit 0
fi
echo "installed $DEST"
