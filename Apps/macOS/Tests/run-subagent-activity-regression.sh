#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-subagent-activity-regression.sh <Build/Products/Release>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-subagent-activity.XXXXXX)
# Extract the production reducer into a minimal host, without AppModel.init
# (which otherwise opens persistent stores and launches discovery).
awk 'FNR==NR {
    if(/^    struct LiveTool:/ || /^    private func apply\(/) section=1;
    if(section) {
        if(/^    private func save\(/) {section=0;next}
        members=members $0 "\n";
        if(/^    }/ && $0 !~ /else/) section=0;
    }
    next
}
FNR==1 {print "import Foundation\nimport SkynetCore"}
/    \/\/ PRODUCTION_MEMBERS/ {printf "%s",members;next}
{print}' Apps/macOS/Skynet/AppModel.swift Apps/macOS/Tests/SubagentActivityRegression.swift |
    xcrun swiftc - -swift-version 5 -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" -I "$build_products" \
        -module-cache-path "$fixture_dir/ModuleCache" "$build_products/SkynetCore.o" \
        -o "$fixture_dir/SubagentActivityRegression"
print "Fixture executable: $fixture_dir/SubagentActivityRegression"
"$fixture_dir/SubagentActivityRegression"
