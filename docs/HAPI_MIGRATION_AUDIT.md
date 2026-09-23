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
| Session pin (project/global), manual unread, copy ID | Implemented in code | UI regression test. Hapi's resolvable cross-session reference/mention is separate. |
| Session export (JSON/Markdown) | Partial | Current export includes transcript and image metadata, not self-contained image bytes or Scratchlist. Test with large history. |
| Codex native archive/unarchive/delete | Implemented | End-to-end provider verification against installed app-server. |
| Claude native delete | Implemented | End-to-end provider verification against isolated local and SSH sessions. Native archive is not exposed by Claude Code CLI. |
| Transcript text, Markdown, images, reasoning, tools | Partial | Local histories import structured content, but SSH discovery still emits text-only messages. Compare long and multimodal sessions visually; add Hapi's specialized tool presentation and progress/status. |
| Consecutive tool-call grouping/expansion | Partial | Core grouping and basic intent/error summary are implemented; Hapi's timing, focused detail, and lazy older-history hydration are not. |
| Composer image paste and send | Implemented in code | End-to-end Codex app-server/Claude verification with real images, including remote backend. |
| Provider model, effort, permissions, fast/auto modes | Partial | Verify behavior against installed Codex/Claude versions and active sessions; add UI regression tests. |
| Native provider title synchronization | Partial | Codex `thread/setName` is implemented; Claude Code has no verified native title operation. |
| Conversation fork/rewind | Partial | Current-state Codex and Claude forks are implemented; Codex historical fork/rewind still need native turn-boundary mapping and confirmation. Claude historical fork/rewind are unsupported by its current CLI. |
| Mark unread from activity, notification/attention state | Partial | Explicit unread exists; Hapi's activity-derived attention and inbox-like behavior do not. |
| External CLI live status/attach | Not migrated | Discovery imports history but cannot control an externally running CLI. |
| Queue/scheduled messages and Scratchlist | Not migrated | Requires durable scheduling and draft/attachment semantics. |
| Hapi Files browser and integrated terminal | Not migrated | Need local/SSH filesystem and process boundary design. |
| Usage/context pages and session outline | Partial | User-message outline with search/jump and a usage dashboard (7/30 days or all, daily/agent/model) are implemented. Local and SSH Claude/Codex history usage is imported, but Codex cumulative totals are assigned to last activity, not exact request dates. Context-window dashboard remains; provider history with no reported usage cannot be counted. |
| Voice input and interactive question/tool cards | Not migrated or partial | Native microphone flow and provider-specific interaction tests needed. |
| Rich composer, drag/drop, attachment ordering, send scheduling | Partial | Image paste/send exists; Hapi's rich text segments, drag/drop targeting, sortable attachments, queued messages, scheduled messages, and composer parking do not. |
| Message actions and sharing | Partial | Plain-text message copy works; Hapi's richer action menu, share-turn dialog, and share route are missing. |
| Specialized tool cards and generated media | Not migrated | Hapi's diff/patch, edit/write, plan/checklist, interactive question, permission, generated-media, and duration views are not equivalent to the current generic tool group. |
| Machine and display preferences | Partial | SSH machine discovery/toggle and appearance work; Hapi's separate machine, chat, display, storage, and voice controls need a setting-by-setting comparison. |
| Session files and agent terminal | Not migrated | Hapi has dedicated file tree, file viewer, integrated terminal, and agent-terminal views; Skynet has only project handoff to external editors. |

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
