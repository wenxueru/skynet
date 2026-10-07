#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-turn-cancellation-regression.sh <Build/Products/Release>}
shift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-turn-cancellation.XXXXXX)
awk 'FNR==NR {
    if(/^    struct QueuedPrompt:/ || /^    func send\(/) section=1;
    if(/^private struct AppPermissionResponder:/) section=2;
    if(/^    private func sendQueuedPrompt\(/) section=3;
    if(section==3) {
        if(/^    private func deliverMatureScheduledMessage\(/) {section=0;next}
        line=$0;
        sub(/private func sendQueuedPrompt/,"func productionSendQueuedPrompt",line);
        members=members line "\n";
        next;
    }
    if(section==1) {
        if(/^    func saveCustomProvider\(/) {section=0;next}
        members=members $0 "\n";
        if(/^    }/ && members !~ /func send\(/) section=0;
    } else if(section==2) {
        responder=responder $0 "\n";
        if(/^}/) section=0;
    }
    next
}
FNR==1 {print "import Foundation\nimport SkynetCore"}
/    \/\/ PRODUCTION_MEMBERS/ {printf "%s",members;next}
/\/\/ PRODUCTION_RESPONDER/ {printf "%s",responder;next}
{print}' Apps/macOS/Skynet/AppModel.swift Apps/macOS/Tests/TurnCancellationRegression.swift |
awk 'FNR==NR {source=source $0 "\n";next} FNR==1 {printf "%s",source} {print}' Apps/macOS/Skynet/SessionTurnExecutor.swift - |
    xcrun swiftc - Packages/SkynetCore/Sources/SkynetCoreDoubles/ScriptedExecutionBackend.swift \
        -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
        -I "$build_products" -module-cache-path "$fixture_dir/ModuleCache" \
        "$build_products/SkynetCore.o" -o "$fixture_dir/TurnCancellationRegression"
print "Fixture executable: $fixture_dir/TurnCancellationRegression"
"$fixture_dir/TurnCancellationRegression" "$@"
