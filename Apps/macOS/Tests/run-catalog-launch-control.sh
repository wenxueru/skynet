#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-catalog-launch-control.sh <Build/Products/Release> [--compile-only|--parent-root]}
shift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-catalog-control.XXXXXX)
xcrun swiftc Apps/macOS/Tests/CatalogLaunchControl.swift \
    -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    -I "$build_products" -module-cache-path "$fixture_dir/ModuleCache" \
    "$build_products/SkynetCore.o" -o "$fixture_dir/CatalogLaunchControl"
print "Fixture executable: $fixture_dir/CatalogLaunchControl"
if [[ ${1:-} != --compile-only ]]; then
    "$fixture_dir/CatalogLaunchControl" "$@"
fi
