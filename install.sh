#!/bin/bash
# Installs the latest Burn release into ~/Applications.
#   curl -fsSL https://raw.githubusercontent.com/JRaunak/Burn/master/install.sh | bash
# curl doesn't set the quarantine flag, so Gatekeeper doesn't block the unsigned app.
set -euo pipefail

url="https://github.com/JRaunak/Burn/releases/latest/download/Burn.tar.gz"
dest="$HOME/Applications"

if [ "$(uname -m)" != arm64 ]; then
    echo "Burn releases are Apple Silicon only. Build from source with ./build.sh install." >&2
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $url"
curl -fsSL "$url" -o "$tmp/Burn.tar.gz"
tar -xzf "$tmp/Burn.tar.gz" -C "$tmp"
[ -d "$tmp/Burn.app" ] || { echo "Burn.app not found in the download" >&2; exit 1; }

mkdir -p "$dest"
pkill -x Burn 2>/dev/null || true
while pgrep -x Burn >/dev/null; do sleep 0.1; done
rm -rf "$dest/Burn.app"
mv "$tmp/Burn.app" "$dest/"
open "$dest/Burn.app"
echo "Installed $dest/Burn.app"
