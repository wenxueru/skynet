#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-scheduled-submission-regression.sh <Build/Products/Release>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-scheduled-submission.XXXXXX)
awk 'FNR==NR {
    if(/^    struct QueuedPrompt:/) section="types";
    if(/^    struct LiveTool:/) section="";
    if(/^    var canStopSelectedSession:/) section="stopVisibility";
    if(/^    var pendingPermissionRequest:/) section="";
    if(/^    var shouldQueueComposerSubmission:/ || /^    func enqueueDraft\(/) section="members";
    if(/^    func saveCustomProvider\(/) section="";
    if(/^private struct AppPermissionResponder:/) section="responder";
    if(section=="types") types=types $0 "\n";
    if(section=="members") members=members $0 "\n";
    if(section=="stopVisibility") visibility=visibility $0 "\n";
    if(section=="responder") {
        responder=responder $0 "\n";
        if(/^}/) section="";
    }
    next
}
/    \/\/ PRODUCTION_TYPES/ {printf "%s",types;next}
/    \/\/ PRODUCTION_MEMBERS/ {printf "%s",members;next}
/    \/\/ PRODUCTION_STOP_VISIBILITY/ {printf "%s",visibility;next}
/\/\/ PRODUCTION_RESPONDER/ {printf "%s",responder;next}
{print}' Apps/macOS/Skynet/AppModel.swift Apps/macOS/Tests/ScheduledSubmissionRegression.swift |
awk 'FNR==NR {
    if(/^    private func submit\(/) section=1;
    if(/^    private func restoreComposerDraft\(/) section=0;
    if(section) submit=submit $0 "\n";
    next
}
/    \/\/ PRODUCTION_SUBMIT/ {printf "%s",submit;next}
{print}' Apps/macOS/Skynet/SessionComposerView.swift - |
awk 'FNR==NR {
    if(/^private actor TerminationGate/) copying=1;
    if(/^\/\/ PRODUCTION_RESPONDER/) copying=0;
    if(copying) helpers=helpers $0 "\n";
    next
}
/\/\/ TERMINATION_HELPERS/ {printf "%s",helpers;next}
{print}' Apps/macOS/Tests/TurnCancellationRegression.swift - |
awk 'FNR==NR {source=source $0 "\n";next} FNR==1 {printf "%s",source} {print}' Apps/macOS/Skynet/SessionTurnExecutor.swift - |
    xcrun swiftc - Packages/SkynetCore/Sources/SkynetCoreDoubles/ScriptedExecutionBackend.swift \
        -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
        -I "$build_products" -module-cache-path "$fixture_dir/ModuleCache" \
        "$build_products/SkynetCore.o" -o "$fixture_dir/ScheduledSubmissionRegression"
print "Fixture executable: $fixture_dir/ScheduledSubmissionRegression"
"$fixture_dir/ScheduledSubmissionRegression"
