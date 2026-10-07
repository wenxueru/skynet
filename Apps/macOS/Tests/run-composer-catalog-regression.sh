#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-composer-catalog-regression.sh <Build/Products/Release>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-composer-catalog.XXXXXX)
# Only actual catalog helpers; never invoke catalog load/global file traversal.
cat Apps/macOS/Skynet/ComposerCatalog.swift Apps/macOS/Tests/ComposerCatalogRegression.swift |
    xcrun swiftc - -swift-version 5 -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" -I "$build_products" \
        -module-cache-path "$fixture_dir/ModuleCache" "$build_products/SkynetCore.o" \
        -o "$fixture_dir/ComposerCatalogRegression"
print "Fixture executable: $fixture_dir/ComposerCatalogRegression"
"$fixture_dir/ComposerCatalogRegression"
