#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-mobile-host-regression.sh <Build/Products/Debug>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-mobile-host.XXXXXX)
xcrun swiftc Apps/macOS/Skynet/MobileHostController.swift \
    Apps/macOS/Skynet/MobileDispatchLedger.swift Apps/macOS/Skynet/MobileSessionProjection.swift \
    Apps/macOS/Tests/MobileHostRegression.swift \
    -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    -I "$build_products" -module-cache-path "$fixture_dir/ModuleCache" \
    "$build_products/SkynetCore.o" "$build_products/SkynetMobile.o" \
    -o "$fixture_dir/MobileHostRegression"
print "Fixture executable: $fixture_dir/MobileHostRegression"
"$fixture_dir/MobileHostRegression" "$fixture_dir"
