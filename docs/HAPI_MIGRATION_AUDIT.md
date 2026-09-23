# Hapi → Skynet macOS migration audit

Source of truth: `/Users/wenxueru/Documents/hapi-deleted-2026-09-22`.
Scope agreed with the user: finish the macOS desktop experience first. Hapi Hub,
iOS/Android clients, pairing, and mobile push are outside this phase. A feature
is complete only when its UI, persistence, provider behavior, and tests work;
an entry point alone is not completion.

| Area | Status | Remaining acceptance work |
| --- | --- | --- |
| Machine/project/session sidebar, search, expansion | Implemented | UI regression test. |
| Recent-date grouping and machine filter | Implemented | UI regression test. |
| Project pin, rename, remove, open in VS Code | Implemented | Verify local and Remote-SSH launches on configured machines. |
| Project session delete | Implemented | Deletes provider-owned conversations; project files remain. Verify real Codex/Claude sessions in an isolated account. |
| Session pin (project/global), manual unread, copy ID | Implemented in code | UI regression test. |
| Cross-session composer references | Partial | `@` autocomplete inserts a session reference; on send, Skynet supplies up to 20 recent cached user/assistant messages (6,000 characters) as bounded context. Hapi's live `inspect_peer`/`ping_peer` tools and rich mention chips are not present. |
| Session export (JSON/Markdown) | Partial | Current export includes transcript and image metadata, not self-contained image bytes or Scratchlist. Test with large history. |
| Codex native archive/unarchive/delete | Implemented | End-to-end provider verification against installed app-server. |
| Claude native delete | Implemented | End-to-end provider verification against isolated local and SSH sessions. Native archive is not exposed by Claude Code CLI. |
| Transcript text, Markdown, images, reasoning, tools | Partial | Local histories import structured content. SSH sidebar discovery remains a lightweight text preview, but selecting a remote session now fetches its original transcript (up to 100 MB) and runs the same structured Codex/Claude parser; a real remote Claude session displayed reasoning and grouped tool calls. Compare multimodal sessions visually; complete specialized tool presentation and progress/status. |
| Consecutive tool-call grouping/expansion | Partial | Core grouping and basic intent/error summary are implemented; remote full-history hydration is on demand. Hapi's timing, focused detail, and local lazy older-history pagination remain. |
| Composer image paste and send | Implemented in code | End-to-end Codex app-server/Claude verification with real images, including remote backend. |
| Provider model, effort, permissions, fast/auto modes | Partial | Verify behavior against installed Codex/Claude versions and active sessions; add UI regression tests. |
| Native provider title synchronization | Partial | Codex `thread/setName` is implemented; Claude Code has no verified native title operation. |
| Conversation fork/rewind | Partial | Current-state Codex and Claude forks are implemented; Codex historical fork/rewind still need native turn-boundary mapping and confirmation. Claude historical fork/rewind are unsupported by its current CLI. |
| Mark unread from activity, notification/attention state | Partial | Existing sessions now auto-mark unread when discovery finds a new assistant reply outside the selected session. System notifications and Hapi's full inbox-like attention state remain. |
| External CLI live status/attach | Deferred by user | Discovery imports history but cannot control an externally running CLI. Hapi-style attach requires a managed CLI launch and a persistent local bridge; the user explicitly deferred that service. |
| Queue/scheduled messages and Scratchlist | Partial | Scratchlist saves text/image drafts per session, supports editing/reordering, and restores them to the composer. Active-turn messages persist in a per-session FIFO queue. Scheduled text messages can be set up to 7 days ahead, are persisted, and dispatch while Skynet is running. Delivery is not guaranteed while the app is closed, and an uncertain send is held for manual review rather than automatically replayed. Hapi's always-on Hub scheduling and richer queue send-now flow remain. |
| Hapi Files browser and integrated terminal | Partial | Integrated local/SSH PTY terminal runs in a separate sheet; local Shell was verified in the installed app. The read-only local/SSH file browser supports Changes/Directories, search, sorting, path copying/reference, text/image preview, and bounded Git diff. Hapi's Markdown preview, syntax highlighting, staged diff, global file search, and richer metadata remain. Verify SSH and long-running terminal behavior. |
| Usage/context pages and session outline | Partial | User-message outline with search/jump and a usage dashboard (7/30 days or all, daily/agent/model) are implemented. The selected-session context section now shows latest reported input against the model's reported window when both values are available. Local and SSH Claude/Codex history usage is imported, but Codex cumulative totals are assigned to last activity, not exact request dates; provider history with no reported usage cannot be counted. |
| Voice input and interactive question/tool cards | Not migrated or partial | Native microphone flow and provider-specific interaction tests needed. |
| Rich composer, drag/drop, attachment ordering, send scheduling | Partial | Image paste/send and image-file drop into the composer work; attachment order can be changed from each thumbnail's menu. Text/image drafts are now parked per session and restored after navigation or restart. Hapi's rich text segments, drag positioning, drag sorting, and scheduled messages remain. |
| Message actions and sharing | Partial | Copy text/ID, quote into composer, and macOS text sharing work. Hapi's share-turn dialog, share route, and attachment-aware actions remain. |
| Specialized tool cards and generated media | Partial | Plans, questions, edits/patches, and commands have tailored detail views. MultiEdit, Codex change dictionaries, and patches/diffs have structured details and long tool output is collapsed on demand. Hapi's generated-media, duration, and complete provider-specific permission interaction remain. |
| Machine and display preferences | Partial | SSH machine discovery/toggle and appearance work; Hapi's separate machine, chat, display, storage, and voice controls need a setting-by-setting comparison. |
| Session files and agent terminal | Partial | Agent terminal starts a separate Codex/Claude CLI with its native resume token; it does not take over an already-running CLI process. Read-only local/SSH session file tree and viewer are present. External-process attach is deferred. |

## Deletion contract

`Delete session` and `Delete all sessions in project` first delete provider-owned
Codex/Claude conversation data, then remove the Skynet record and transcript.
On provider failure, the Skynet record remains. `Remove project` deliberately
removes only Skynet's project and cached sessions; it does not delete project
files or original provider conversations. New provider sessions can recreate a
project on discovery.

## Release gate for desktop parity

1. Every applicable row above is implemented or explicitly identified as a
   provider limitation, not silently omitted.
2. Core and macOS builds pass; destructive operations are tested against
   isolated provider data before touching user sessions.
3. Verify long Claude and Codex transcripts, images, tool groups, permission
   prompts, remote machines, and theme changes in the installed app.
4. Back up, replace, and restart `/Applications/Skynet.app` after each batch.
