#!/bin/zsh
set -euo pipefail
# Run from Skynet project root with the exact existing Release products.
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-file-browser-regression.sh <Build/Products/Release>}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-files-regression.XXXXXX)
awk 'FNR==NR {if(/^private struct FileEntry:/) browserSection=1;
    if(FNR<=3 || browserSection) print;next}{print}' \
    Apps/macOS/Skynet/SessionFilesView.swift \
    Apps/macOS/Tests/FileBrowserBoundaryRegression.swift |
    xcrun swiftc - Apps/macOS/Skynet/ProcessDiagnosticsReader.swift -swift-version 5 -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" -I "$build_products" \
        -module-cache-path "$fixture_dir/ModuleCache" "$build_products/SkynetCore.o" \
        -o "$fixture_dir/FileBrowserBoundaryRegression"
print "Fixture executable: $fixture_dir/FileBrowserBoundaryRegression"
"$fixture_dir/FileBrowserBoundaryRegression"
