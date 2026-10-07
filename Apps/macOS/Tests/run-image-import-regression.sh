#!/bin/zsh
set -euo pipefail
build_products=${1:?Usage: zsh Apps/macOS/Tests/run-image-import-regression.sh <Build/Products/Release> [--baseline-index] [--prepare|--cleanup] [--webp-fixture <16x12 WebP>]}
shift
image_source_mode=worktree
if [[ ${1:-} == --baseline-index ]]; then
    image_source_mode=index
    shift
fi
function image_import_source() {
    if [[ $image_source_mode == index ]]; then
        git show :Apps/macOS/Skynet/AppModel.swift
    else
        /bin/cat Apps/macOS/Skynet/AppModel.swift
    fi
}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fixture_dir=$(mktemp -d /private/tmp/skynet-image-import.XXXXXX)
# Compile actual import methods, with only pending state substituted by a
# disposable harness. Keep any file-private import helper in the same unit.
awk 'FNR==NR {
    if(/^import /) print;
    if(/^    func attachImage\(url:/) {print "@MainActor final class ImageImportHarness { var pendingAttachments: [ImageAttachment] = []; var errorMessage: String?"; methods=1}
    if(/^    func imageData\(/) {print "}"; methods=0}
    if(methods) print;
    if(/^private enum ComposerImageImport/) helper=1;
    if(helper) print;
    next
}{print}' <(image_import_source) Apps/macOS/Tests/ImageImportRegression.swift |
    xcrun swiftc - -swift-version 5 -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" -I "$build_products" \
        -module-cache-path "$fixture_dir/ModuleCache" "$build_products/SkynetCore.o" \
        -o "$fixture_dir/ImageImportRegression"
print "Fixture executable: $fixture_dir/ImageImportRegression"
"$fixture_dir/ImageImportRegression" "$@"
