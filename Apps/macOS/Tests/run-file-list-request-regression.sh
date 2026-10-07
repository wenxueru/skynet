#!/bin/zsh
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-file-list-request.XXXXXX)
awk 'FILENAME==ARGV[1] {
    if(/^    private func loadEntries\(/) copying=1;
    if(/^    private func loadPreview\(/) copying=0;
    if(copying) {
        line=$0;
        sub(/private func loadEntries\(\)/,"func loadEntries() -> Task<Void, Never>",line);
        sub(/^        Task \{/,"        return Task {",line);
        method=method line "\n";
    }
    next
}
/    \/\/ PRODUCTION_LOAD_ENTRIES/ {printf "%s",method;next}
{print}' Apps/macOS/Skynet/SessionFilesView.swift Apps/macOS/Tests/FileListRequestRegression.swift |
    xcrun swiftc - -swift-version 5 -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" -module-cache-path "$fixture_dir/ModuleCache" \
        -o "$fixture_dir/FileListRequestRegression"
print "Fixture executable: $fixture_dir/FileListRequestRegression"
"$fixture_dir/FileListRequestRegression"
