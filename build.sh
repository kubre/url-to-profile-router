#!/bin/sh
set -e
cd "$(dirname "$0")"
rm -rf build
mkdir -p build/Router.app/Contents/MacOS build/Router.app/Contents/Resources
swiftc -O -o build/Router.app/Contents/MacOS/Router main.swift -framework AppKit
cp Info.plist build/Router.app/Contents/Info.plist
cp rules.json build/Router.app/Contents/Resources/rules.json
mkdir -p ~/.config
[ -f ~/.config/url-router.json ] || cp rules.json ~/.config/url-router.json
ls -lh build/Router.app/Contents/MacOS/Router
echo "built build/Router.app — copy to /Applications, then set as default browser"
