#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
cd WireGuardBridge
make clean
make xcframework
cd ..
rm -rf WireGuardTURN.xcframework
cp -R WireGuardBridge/build/WireGuardTURN.xcframework ./WireGuardTURN.xcframework
xattr -cr WireGuardTURN.xcframework || true
echo "OK: WireGuardTURN.xcframework rebuilt and replaced"
