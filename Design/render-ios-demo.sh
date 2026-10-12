#!/bin/zsh
set -euo pipefail
# Run from the repository root with full Xcode and an available simulator UDID.
# Only the separately identified sample-data app is installed or terminated.
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
device=${1:?Usage: render-ios-demo.sh <simulator-UDID>}
demo_dir=$(mktemp -d /private/tmp/skynet-ios-demo.XXXXXX)
bundle_id=com.skynetresearch.readme-ios-demo
launched=0
xcodegen generate --spec Design/ios-demo.yml --project "$demo_dir"
xcodebuild -project "$demo_dir/SkynetIOSDemo.xcodeproj" -scheme SkynetIOSDemo \
    -configuration Debug -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$demo_dir/build" build
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$demo_dir/build/Build/Products/Debug-iphonesimulator/SkynetIOSDemo.app"
cleanup() {
    if (( launched )); then
        xcrun simctl terminate "$device" "$bundle_id" >/dev/null 2>&1 || true
    fi
    xcrun simctl status_bar "$device" clear >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl status_bar "$device" override --time '9:41' --batteryState charged --batteryLevel 100 \
    --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4
for screen in library session queue; do
    if (( launched )); then
        xcrun simctl terminate "$device" "$bundle_id"
    fi
    xcrun simctl launch "$device" "$bundle_id" "$screen"
    launched=1
    sleep 3
    xcrun simctl io "$device" screenshot "$demo_dir/$screen.png"
done
mkdir -p docs/assets
xcrun swiftc -parse-as-library -module-cache-path "$demo_dir/ModuleCache" \
    Design/DemoImage.swift Design/encode-ios-demo.swift -o "$demo_dir/encode-ios-demo"
"$demo_dir/encode-ios-demo" "$demo_dir" "$PWD/docs/assets"
print "iOS demo assets: $PWD/docs/assets"
