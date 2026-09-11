#!/bin/sh
set -e
cd "$(dirname "$0")"
APP="URL to Profile Router"
rm -rf build
mkdir -p "build/$APP.app/Contents/MacOS" "build/$APP.app/Contents/Resources"
swiftc -O -o "build/$APP.app/Contents/MacOS/Router" main.swift -framework AppKit
cp Info.plist "build/$APP.app/Contents/Info.plist"
cp rules.json "build/$APP.app/Contents/Resources/rules.json"
mkdir -p ~/.config
[ -f ~/.config/url-router.json ] || cp rules.json ~/.config/url-router.json
ls -lh "build/$APP.app/Contents/MacOS/Router"
echo "built build/$APP.app — run ./install.sh"
