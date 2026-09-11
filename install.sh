#!/bin/sh
set -e
cd "$(dirname "$0")"
./build.sh
rm -rf /Applications/Router.app
cp -R build/Router.app /Applications/Router.app
codesign --force --deep --sign - /Applications/Router.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Router.app
echo "installed — fully quit System Settings (Cmd+Q), reopen it, pick Router as default browser"
