#!/bin/zsh
set -euo pipefail
# Run from project root. Only independent fixtures, no installed app/session.
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-composer-regression.XXXXXX)
for fixture in ComposerInputRegression ComposerUndoRegression; do
    xcrun swiftc -swift-version 5 -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" \
        -module-cache-path "$fixture_dir/ModuleCache" \
        Apps/macOS/Skynet/ComposerTextView.swift "Apps/macOS/Tests/$fixture.swift" \
        -o "$fixture_dir/$fixture"
    print "Fixture executable: $fixture_dir/$fixture"
    "$fixture_dir/$fixture"
done
