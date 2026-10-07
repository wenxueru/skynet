#!/bin/zsh
set -euo pipefail
# SwiftUI sheet buttons are virtual AX controls. Use --interactive and CUA on
# this own, no-session app to click each printed READY target, then require the
# terminal PASS/exit0. Default/offscreen mode is for old NSAlert baselines only.
build_products=${1:?Usage: run-permission-dialog-presentation-regression.sh <Release products>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-permission-dialog.XXXXXX)
fixture_executable="$fixture_dir/PermissionDialogPresentationRegression"
if [[ ${2:-} == --interactive ]]; then
    fixture_bundle="$fixture_dir/SkynetPermissionDialogQA.app"
    mkdir -p "$fixture_bundle/Contents/MacOS"
    cp Apps/macOS/Tests/PermissionDialogRegressionInfo.plist "$fixture_bundle/Contents/Info.plist"
    fixture_executable="$fixture_bundle/Contents/MacOS/PermissionDialogPresentationRegression"
fi
awk 'FILENAME==ARGV[1] {
    if(/^    private var permissionDialogPresented:/) bindingCopying=1;
    if(/^    private var permissionRequestDescription:/) bindingCopying=0;
    if(bindingCopying) {
        bindingLine=$0;
        sub(/private var permissionDialogPresented/,"var permissionDialogPresented",bindingLine);
        presentationBinding=presentationBinding bindingLine "\n";
    }
    if(/^        \.confirmationDialog\(/ || /^        \.sheet\(isPresented: permissionDialogPresented\)/) copying=1;
    if(/^        \.sheet\(item:/) copying=0;
    if(copying) presentation=presentation $0 "\n";
    if(/^private struct ToolPermissionSheet:/) sheetCopying=1;
    if(sheetCopying) sheet=sheet $0 "\n";
    next
}
FILENAME==ARGV[2] {
    if(/^    var permissionDecisionAction:/) decisionCopying=1;
    if(/^    func answerPermission\(/) decisionCopying=0;
    if(decisionCopying) decisionFactory=decisionFactory $0 "\n";
    next
}
/    \/\/ PRODUCTION_PERMISSION_PRESENTATION$/ {printf "%s",presentation;next}
/    \/\/ PRODUCTION_PERMISSION_PRESENTATION_BINDING$/ {printf "%s",presentationBinding;next}
/\/\/ PRODUCTION_PERMISSION_SHEET/ {printf "%s",sheet;next}
/    \/\/ PRODUCTION_PERMISSION_DECISION_FACTORY/ {printf "%s",decisionFactory;next}
{print}' Apps/macOS/Skynet/SessionDetailView.swift Apps/macOS/Skynet/AppModel.swift Apps/macOS/Tests/PermissionDialogPresentationRegression.swift |
    xcrun swiftc - -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
        -I "$build_products" -module-cache-path "$fixture_dir/ModuleCache" \
        "$build_products/SkynetCore.o" -o "$fixture_executable"
print "Fixture executable: $fixture_executable"
"$fixture_executable" ${2:-}
