#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-session-coordination-regression.sh <Build/Products/Release>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-coordination.XXXXXX)
# Extract production value types only; real controllers are compiled unchanged.
awk 'FNR==NR {
    if(/^struct DiscoveredMachine:/ || /^struct SessionTranscriptPage /) copying=1;
    if(copying) { types=types $0 "\n"; if(/^}/) copying=0; }
    next
}
FNR==1 {print types}
{print}' Apps/macOS/Skynet/MacSessionDiscovery.swift Apps/macOS/Tests/SessionCoordinationRegression.swift |
awk 'FILENAME!="-" {source=source $0 "\n";next} FNR==1 {printf "%s",source} {print}' \
    Apps/macOS/Skynet/SessionTranscriptController.swift Apps/macOS/Skynet/NetworkConnectivityMonitor.swift - |
    xcrun swiftc - \
        Packages/SkynetCore/Sources/SkynetCoreDoubles/ScriptedExecutionBackend.swift \
        -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
        -I "$build_products" -module-cache-path "$fixture_dir/ModuleCache" \
        "$build_products/SkynetCore.o" -o "$fixture_dir/SessionCoordinationRegression"
print "Fixture executable: $fixture_dir/SessionCoordinationRegression"
"$fixture_dir/SessionCoordinationRegression"
