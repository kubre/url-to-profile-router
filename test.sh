#!/bin/sh
set -eu
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' HUP INT TERM
swiftc -swift-version 5 -warnings-as-errors RouterCore.swift tests/CoreTests.swift -o "$TMP/CoreTests"
"$TMP/CoreTests"
