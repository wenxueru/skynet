#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: run-local-process-broken-pipe-regression.sh <Release products>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-broken-pipe.XXXXXX)
# Keep the private production descriptor accessible only in this compilation.
awk 'FNR==1 && NR==1 {print "import SkynetCore"} {print}' \
    Packages/SkynetCore/Sources/SkynetCore/Execution/LocalProcessBackend.swift \
    Apps/macOS/Tests/LocalProcessBrokenPipeRegression.swift |
    xcrun swiftc - -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
        -I "$build_products" -module-cache-path "$fixture_dir/ModuleCache" \
        "$build_products/SkynetCore.o" -o "$fixture_dir/LocalProcessBrokenPipeRegression"
print "Fixture executable: $fixture_dir/LocalProcessBrokenPipeRegression"
"$fixture_dir/LocalProcessBrokenPipeRegression"
