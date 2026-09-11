#!/bin/sh
set -e
cd "$(dirname "$0")"
APP="URL to Profile Router"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
./build.sh
"$LSREG" -u /Applications/Router.app 2>/dev/null || true
"$LSREG" -u "build/Router.app" 2>/dev/null || true
rm -rf /Applications/Router.app "/Applications/$APP.app"
cp -R "build/$APP.app" "/Applications/$APP.app"
codesign --force --deep --sign - "/Applications/$APP.app"
"$LSREG" -f "/Applications/$APP.app"
echo "installed — fully quit System Settings (Cmd+Q), reopen it, pick $APP as default browser"
