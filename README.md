# Skynet

Native SwiftUI client for coding-agent sessions on macOS, with an iOS/iPadOS
client and relay contracts. Production relay transport is not configured by default.

## Targets

- `SkynetMac`: macOS client; local/SSH execution of Codex, Claude Code and
  configured Claude-Code-compatible executables.
- `Skynet`: iOS/iPadOS client; never launches coding-agent CLIs itself.
- `SkynetCore`: shared provider, execution, transcript and persistence logic.

## Generate and build

```sh
# This workstation; elsewhere use your full Xcode Developer directory.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --spec project.yml
xcodebuild -scheme SkynetMac -destination 'platform=macOS' build
swift test --package-path Packages/SkynetCore
```

`Skynet` is the iOS scheme, not the macOS scheme. For target/build-setting changes,
edit `project.yml` and regenerate. A Command Line Tools `xcode-select` result does
not mean full Xcode is absent. Verified app updates replace `/Applications/Skynet.app`
directly, without old-version backups.

## Provider configuration

Codex and Claude Code are built in. Add compatible executables and default
arguments in macOS Settings.

## Documentation

- [Architecture](docs/architecture.md): ownership and dependency boundaries.
- [Migration scope](docs/hapi_migration_audit.md): retained/deferred features.

Agent memory, QA status and historical diagnostics stay local and are excluded
from Git. They are not required to build the project.
