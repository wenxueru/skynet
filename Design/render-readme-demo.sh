#!/bin/zsh
set -euo pipefail
# Run from the repository root. Render actual views with isolated sample data.
# This never launches Skynet.app, its CLI providers, or its real session store.
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
demo_dir=$(mktemp -d /private/tmp/skynet-readme-demo.XXXXXX)
bundle="$demo_dir/SkynetReadmeDemo.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources" docs/assets

# Compile repository assets, not resources from a possibly outdated installed App.
xcrun actool Apps/macOS/Skynet/Assets.xcassets --compile "$bundle/Resources" \
    --platform macosx --minimum-deployment-target 14.0

xcrun swift build --package-path Packages/SkynetCore --scratch-path "$demo_dir/core"
core_bin=$(xcrun swift build --package-path Packages/SkynetCore --scratch-path "$demo_dir/core" --show-bin-path)

# Replace only model initialization in the temporary compilation unit.
# Production sources are untouched. No store, discovery, timer or SSH targets.
awk '
FILENAME==ARGV[1] && /^    init\(\) \{/ {
    print "    init() {";
    print "        disabledMachineIDs = []; deletedDiscoveryKeys = []";
    print "        store = nil; transcript = SessionTranscriptController(store: nil)";
    print "    }";
    skipping=1; next
}
FILENAME==ARGV[1] && /^    var selectedProject:/ {skipping=0}
!skipping {print}
' Apps/macOS/Skynet/AppModel.swift Design/ReadmeDemo.swift > "$demo_dir/DemoModel.swift"
sources=(Apps/macOS/Skynet/*.swift)
sources=(${sources:#*/AppModel.swift})
sources=(${sources:#*/SkynetMacApp.swift})
xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    -I "$core_bin/Modules" -module-cache-path "$demo_dir/ModuleCache" \
    "${sources[@]}" "$demo_dir/DemoModel.swift" "$core_bin"/SkynetCore.build/*.o \
    -o "$bundle/MacOS/SkynetReadmeDemo"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.skynetresearch.readme-demo' "$bundle/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string SkynetReadmeDemo' "$bundle/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$bundle/Info.plist"
"$bundle/MacOS/SkynetReadmeDemo" "$PWD/docs/assets"
print "Demo assets: $PWD/docs/assets"
