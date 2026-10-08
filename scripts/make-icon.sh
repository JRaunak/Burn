#!/bin/bash
# Regenerates Resources/Burn.icns and Resources/Burn.icon/Assets from FlameGlyph.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
swiftc -O scripts/icon/main.swift Sources/Burn/FlameGlyph.swift -o "$tmp/icon"
"$tmp/icon" .
iconutil -c icns Resources/Burn.iconset -o Resources/Burn.icns
rm -rf Resources/Burn.iconset
