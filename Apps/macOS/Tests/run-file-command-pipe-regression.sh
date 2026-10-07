#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-file-command-pipe-regression.sh <Build/Products/Release>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-file-command-pipes.XXXXXX)
awk 'FNR==NR {
    if(/^private struct FileEntry:/) browserSection=1;
    if(FNR<=3 || browserSection) {
        sub(/private func run\(/, "func run("); print;
        if($0 ~ /try process.run\(\)/) print "        ProcessWatchdog.watch(process)";
    }
    next
} {print}' Apps/macOS/Skynet/SessionFilesView.swift \
    Apps/macOS/Tests/FileCommandPipeRegression.swift |
    xcrun swiftc - Apps/macOS/Skynet/ProcessDiagnosticsReader.swift -swift-version 5 -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" -I "$build_products" \
        -module-cache-path "$fixture_dir/ModuleCache" "$build_products/SkynetCore.o" \
        -o "$fixture_dir/FileCommandPipeRegression"
print "Fixture executable: $fixture_dir/FileCommandPipeRegression"
"$fixture_dir/FileCommandPipeRegression"
