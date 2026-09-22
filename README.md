# Skynet

Skynet is a native SwiftUI client for running coding-agent sessions on macOS
and controlling them from iPhone or iPad.

## Targets

- **SkynetMac** — native macOS app. Runs Codex, Claude Code, and user-configured
  Claude-Code-compatible executables as local child processes.
- **Skynet** — native iOS/iPadOS app. Its UI, pairing, relay seams, reconnect,
  queue, transcript, notification, and Live Activity layers are implemented;
  production networking is supplied through the `SkynetRelay` protocol.
- **SkynetCore** — shared, dependency-free Swift package for providers,
  model/effort catalogs, permission policy, process/relay backends,
  transcripts, notifications, attachments, and persistence.

## Generate and build

```sh
xcodegen generate --spec project.yml

DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
  xcodebuild -project Skynet.xcodeproj -scheme SkynetMac build

DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
  xcodebuild -project Skynet.xcodeproj -scheme Skynet \
  -destination 'generic/platform=iOS Simulator' build

swift test --package-path Packages/SkynetCore
```

The Xcode project is generated from `project.yml`; edit the specification,
not `project.pbxproj`, when changing targets or build settings.

## Provider configuration

Codex and Claude Code are built in. In the macOS app, open Settings to add a
named Claude-Code-compatible executable and optional default arguments. No
wrapper brand is hard-coded in the source.
