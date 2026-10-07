#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-remote-discovery-pipe-regression.sh <Build/Products/Release>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-remote-pipes.XXXXXX)
awk 'FNR==NR {
    if($0 ~ /try process.run\(\)/) print "            RemotePipeFixture.replaceLaunch(process)";
    print;
    if($0 ~ /try process.run\(\)/) print "            RemotePipeFixture.watch(process)";
    next
} {print}' Apps/macOS/Skynet/MacSessionDiscovery.swift \
    Apps/macOS/Tests/RemoteDiscoveryPipeRegression.swift |
    xcrun swiftc - Apps/macOS/Skynet/ProcessDiagnosticsReader.swift -swift-version 5 -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" -I "$build_products" \
        -module-cache-path "$fixture_dir/ModuleCache" "$build_products/SkynetCore.o" \
        -o "$fixture_dir/RemoteDiscoveryPipeRegression"
print "Fixture executable: $fixture_dir/RemoteDiscoveryPipeRegression"
"$fixture_dir/RemoteDiscoveryPipeRegression"
