# Architecture

The process boundary is intentional:

1. `SkynetCore.AgentSession` converts a turn into a provider-specific command
   and folds JSONL output into stable events and transcript messages.
2. macOS uses `LocalProcessBackend` (and can later select `SSHBackend`) because
   it is allowed to spawn coding-agent CLIs.
3. iOS never spawns a CLI. It talks to a paired Mac through the `SkynetRelay`
   seam and keeps queued prompts until connectivity returns.
4. Provider protocol and execution location remain independent. Codex and
   Claude Code have separate adapters; custom wrappers are persisted data that
   opt into the Claude Code-compatible protocol.

The current iOS application ships the complete native presentation and relay
contracts. A deployment must inject a concrete authenticated relay transport
in `AppEnvironment.live()`; the default intentionally stays unpaired rather
than pretending a network connection exists.
