#!/bin/zsh
set -euo pipefail
build_products=${1:?Pass the exact current Build/Products/Release directory}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-terminal-sheet.XXXXXX)
fixture_bundle="$fixture_dir/TerminalRegression.app/Contents"
mkdir -p "$fixture_bundle/MacOS" "$fixture_bundle/Helpers" "$fixture_bundle/Resources"
cp Apps/macOS/Tests/TerminalRegressionInfo.plist "$fixture_bundle/Info.plist"
cp "$build_products/Skynet.app/Contents/Helpers/SkynetPTYLauncher" "$fixture_bundle/Helpers/"
for asset in terminal.html xterm.js addon-fit.js xterm.css; do
    cp "$build_products/Skynet.app/Contents/Resources/$asset" "$fixture_bundle/Resources/"
done
# Keep the real SwiftUI terminal view/controller; omit unrelated Side Chat.
awk 'FNR==NR {if(/^struct IntegratedTerminalView:/) terminalSection=1;
    if(FNR<=4 || terminalSection) print;next}{print}' \
    Apps/macOS/Skynet/IntegratedTerminalView.swift \
    Apps/macOS/Tests/TerminalSheetResizeRegression.swift |
    xcrun swiftc - -swift-version 5 -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" \
        -I "$build_products" -module-cache-path "$fixture_dir/ModuleCache" \
        "$build_products/SkynetCore.o" \
        -o "$fixture_bundle/MacOS/TerminalRegression"
print "Fixture bundle: $fixture_dir/TerminalRegression.app"
"$fixture_bundle/MacOS/TerminalRegression"
