# Hapi → Skynet feature audit (macOS)

This is an inventory of user-facing behavior, not a claim that the two apps share a data model. The comparison uses Hapi's `SessionListView`, `AgentHistoryActions`, chat, files, settings, and pairing screens against Skynet's current macOS UI and shared core. Recheck this list when changing the sidebar or composer.

| Feature | Skynet status | Notes |
| --- | --- | --- |
| Machine → project → session sidebar; search; expand/collapse | Implemented | Native sidebar in `ContentView`. |
| Recent time grouping (bell) | Implemented | Toggle in the sidebar; project grouping remains the default. |
| Quick machine filter | Implemented | Sidebar filter menu; distinct from the persistent show/hide controls in SSH settings. |
| Local/remote machine markers, project path, pin, rename | Implemented | Sidebar and project context menu. |
| Open project in VS Code | Implemented | Local app launch or Remote-SSH URL, matching Hapi's routing. Remote VS Code extension/configuration remains an external prerequisite. |
| New session in the clicked project | Implemented | Available from project and single-session context menus. |
| Delete all sessions in a project | Implemented, different storage semantics | Confirmation removes Skynet records and cached transcripts only. It does not remove original Codex/Claude history or project files. The empty Skynet project is also removed. |
| Multi-select archive/delete, clear selection | Partial | Codex archive/unarchive now calls app-server `thread/archive` / `thread/unarchive` before changing Skynet state. Claude Code CLI exposes no equivalent native archive operation; its Archive action is disabled. Older Skynet-only archives can still be restored locally. Delete still operates on Skynet records only. |
| Remove project | Implemented | Removes the project and all its Skynet sessions/cache, **not** the filesystem folder or original provider history. |
| Per-machine visibility | Implemented | SSH settings can hide discovered machines. |
| Session title edit, transcript, reasoning/tools, timestamps, image display, auto-scroll | Implemented or partial | See UI and transcript presentation. Rendering and tool-detail fidelity are not guaranteed identical to Hapi/ChatGPT. |
| Codex/Claude permission, model/effort controls | Implemented or partial | Controls are provider-specific; actual availability depends on installed provider version. |
| Image attachment | Partial | UI and common attachment model exist; Codex's end-to-end image support is not complete. |
| Provider-history archive/delete/rename | Partial | Codex provider archive and unarchive are implemented. Claude Code CLI archive is unavailable through an official CLI operation; provider-history delete and rename are not migrated. Menu/confirmation text must not imply original history deletion. |
| Externally running session status and live attach | **Not migrated** | Discovery imports history; an external CLI process is not a Skynet-owned run. Stop/delete safeguards cover Skynet-owned active sessions only. |
| Hapi hub sessions, paired phone relay, QR pairing, push/Live Activity | **Not migrated to the macOS app** | These depend on Hapi's hub/protocol. Skynet's iOS relay interfaces are not a production-compatible Hapi server. |
| Hapi Files browser, Scratchlist, Usage pages | **Not migrated** | Independent product surfaces; not equivalent to Skynet's project/session sidebar. |
| Voice input, queued messages, richer interactive tool/question UI | **Not migrated or partial** | Do not advertise parity without end-to-end verification. |

## Deletion contract

`Remove project` calls Skynet's record deletion for every session in the project, then removes the project entry. `Delete all sessions in project` uses the same session deletion path, which removes the now-empty project automatically. Both suppress re-import of the deleted discovered sessions, but leave source files and provider conversations intact. A newly created provider session in that directory can create a new project again.

## Verification still needed

- Exercise local and remote VS Code launches on machines with the app/Remote-SSH extension installed.
- UI-test multi-selection, context menus, machine filtering, and empty-project cleanup.
- Decide explicitly whether destructive provider-history actions belong in Skynet; do not silently change current deletion semantics.
- Check parity for the remaining chat, Files, Scratchlist, and mobile/hub surfaces before claiming full Hapi migration.
