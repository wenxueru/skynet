#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-queue-persistence-regression.sh <Build/Products/Release>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-queue-persistence.XXXXXX)
awk 'FNR==NR {
    if(/^    struct QueuedPrompt:/) types=1;
    if(/^    struct LiveTool:/) types=0;
    if(types) declarations=declarations $0 "\n";
    if(/^    func enqueueDraft\(/) members=1;
    if(/^    private func deliverMatureScheduledMessage\(/) members=0;
    if(members) methods=methods $0 "\n";
    next
}
/    \/\/ PRODUCTION_TYPES/ { printf "%s", declarations; next }
/    \/\/ PRODUCTION_MEMBERS/ { printf "%s", methods; next }
{print}' Apps/macOS/Skynet/AppModel.swift Apps/macOS/Tests/QueuePersistenceRegression.swift |
    xcrun swiftc - -swift-version 5 -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" -I "$build_products" \
        -module-cache-path "$fixture_dir/ModuleCache" "$build_products/SkynetCore.o" \
        -o "$fixture_dir/QueuePersistenceRegression"
print "Fixture executable: $fixture_dir/QueuePersistenceRegression"
"$fixture_dir/QueuePersistenceRegression"
