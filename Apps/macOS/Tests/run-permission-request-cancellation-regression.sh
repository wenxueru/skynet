#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-permission-request-cancellation-regression.sh <Build/Products/Release>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-permission-cancellation.XXXXXX)
awk 'FILENAME==ARGV[1] {
    if(/^private struct AppPermissionResponder:/) responderCopying=1;
    if(responderCopying) {
        responder=responder $0 "\n";
        if(/^}/) responderCopying=0;
        next;
    }
    if(/^    var permissionDecisionAction:/ || /^    func answerPermission\(/ || /^    func cancel\(/ || /^    private func requestPermission\(/) copying=1;
    if(/^    func attachImage\(/ || /^    func saveCustomProvider\(/ || /^    private var transcriptHooks:/) copying=0;
    if(copying) methods=methods $0 "\n";
    next
}
FILENAME==ARGV[2] {
    if(/^    private var permissionDialogPresented:/) bindingCopying=1;
    if(/^    private var permissionRequestDescription:/) bindingCopying=0;
    if(bindingCopying) {
        bindingLine=$0;
        sub(/private var permissionDialogPresented/,"var permissionDialogPresented",bindingLine);
        presentationBinding=presentationBinding bindingLine "\n";
    }
    if(/answer: model\./) {
        decisionBinding=$0;
        sub(/^.*answer: model\./,"",decisionBinding);
        sub(/,$/,"",decisionBinding);
    }
    next
}
/    \/\/ PRODUCTION_PERMISSION_METHODS/ {printf "%s",methods;next}
/\/\/ PRODUCTION_RESPONDER/ {printf "%s",responder;next}
/    \/\/ PRODUCTION_PERMISSION_PRESENTATION_BINDING/ {printf "%s",presentationBinding;next}
/    \/\/ PRODUCTION_PERMISSION_DECISION_BINDING/ {
    if(decisionBinding=="") {print "#error(\"Missing real permission decision binding\")";next}
    printf "            let capturedDecision = staleDecision.%s\n",decisionBinding;next
}
{print}' Apps/macOS/Skynet/AppModel.swift Apps/macOS/Skynet/SessionDetailView.swift Apps/macOS/Tests/PermissionRequestCancellationRegression.swift |
    xcrun swiftc - Packages/SkynetCore/Sources/SkynetCoreDoubles/ScriptedExecutionBackend.swift \
        -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
        -I "$build_products" -module-cache-path "$fixture_dir/ModuleCache" \
        "$build_products/SkynetCore.o" -o "$fixture_dir/PermissionRequestCancellationRegression"
print "Fixture executable: $fixture_dir/PermissionRequestCancellationRegression"
"$fixture_dir/PermissionRequestCancellationRegression"
