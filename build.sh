#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
build_dir="$(pwd)/build"
app="$build_dir/ClubLog Hunter.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

xcrun swiftc Native.swift -module-cache-path "$build_dir/swift-module-cache" \
    -o "$app/Contents/MacOS/DXLovec"
cp Info.plist "$app/Contents/Info.plist"
cp radio.py lovec.py assets/Hunter.icns "$app/Contents/Resources/"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

printf 'Built %s\n' "$app"
