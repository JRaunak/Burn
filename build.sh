#!/bin/bash
# Usage: ./build.sh [install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
bin="$(swift build -c release --show-bin-path)/Burn"

app=build/Burn.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Burn"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/pricing.json "$app/Contents/Resources/pricing.json"
codesign --force --sign - "$app"
echo "built $app"

if [ "${1:-}" = install ]; then
    mkdir -p "$HOME/Applications"
    pkill -x Burn 2>/dev/null || true
    rm -rf "$HOME/Applications/Burn.app"
    cp -R "$app" "$HOME/Applications/"
    open "$HOME/Applications/Burn.app"
    echo "installed to ~/Applications/Burn.app"
fi
