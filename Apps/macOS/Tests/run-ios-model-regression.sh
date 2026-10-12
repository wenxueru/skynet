#!/bin/zsh
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
repo_root=$(cd "${0:A:h}/../../.." && pwd)
fixture_dir=$(mktemp -d /private/tmp/skynet-ios-models.XXXXXX)
mkdir -p "$fixture_dir/Sources/Skynet" "$fixture_dir/Tests/SkynetTests"
cp "$repo_root/Apps/macOS/Tests/iOSModelHarness/Package.swift" "$fixture_dir/Package.swift"

# Compile actual app models; OS services are only exercised through existing
# recording/no-op seams. No Keychain pairing, provider invocation or real session writes.
sources=(
    App/AppActivityState.swift
    App/AppRouter.swift
    App/SessionIndex.swift
    Core/Support/ReconnectPolicy.swift
    Core/Transport/UnconfiguredTransport.swift
    Features/Composer/ComposerStateProviding.swift
    Features/Composer/ComposerViewModel.swift
    Features/Composer/QueuedPromptsModel.swift
    Features/Connectivity/ConnectionMonitor.swift
    Features/Library/LibraryViewModel.swift
    Features/Pairing/PairingViewModel.swift
    Features/Session/SessionViewModel.swift
    Features/SessionList/SessionListViewModel.swift
    Features/Notifications/AppNotificationScheduling.swift
    Features/Notifications/LiveActivitySupport.swift
    Features/Notifications/TurnNotificationCoordinator.swift
    Features/Search/TranscriptSearch.swift
    PreviewSupport/PreviewData.swift
    PreviewSupport/ScriptedRelay.swift
    PreviewSupport/ScriptedPairingService.swift
    Support/Log.swift
    Support/Formatters.swift
)
for source in $sources; do
    cp "$repo_root/Apps/iOS/Skynet/$source" "$fixture_dir/Sources/Skynet/"
done

tests=(
    ComposerViewModelTests.swift
    ConnectionMonitorTests.swift
    LibraryViewModelTests.swift
    PairingCodeTests.swift
    PairingViewModelTests.swift
    QueuedPromptsModelTests.swift
    SessionListViewModelTests.swift
    SessionViewModelTests.swift
    TranscriptSearchTests.swift
    Support/TestSupport.swift
)
for test in $tests; do
    cp "$repo_root/Apps/iOS/Tests/$test" "$fixture_dir/Tests/SkynetTests/"
done

export SKYNET_CORE_PACKAGE="$repo_root/Packages/SkynetCore"
print "Isolated iOS model harness: $fixture_dir"
xcrun swift test --package-path "$fixture_dir" --scratch-path "$fixture_dir/build" "$@"
