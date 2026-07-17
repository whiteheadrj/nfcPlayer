#!/usr/bin/env bash
# Cross-compile the NFC player for the Raspberry Pi. Run on ANY machine with Go
# (macOS, Linux, x86, arm — doesn't matter); produces static binaries in dist/
# that need no Go toolchain, cgo, or shared libraries on the Pi.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p dist
echo "==> arm64 (64-bit Raspberry Pi OS)..."
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o dist/nfcplayer-linux-arm64 .
echo "==> armv7 (32-bit Raspberry Pi OS)..."
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" -o dist/nfcplayer-linux-armv7 .

echo
echo "Built:"
ls -lh dist
echo
echo "Copy this go/ directory (with dist/) to the Pi and run: bash install.sh"
