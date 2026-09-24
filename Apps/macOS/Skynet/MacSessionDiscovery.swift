import Foundation
import SkynetCore

struct DiscoveredMachine: Identifiable, Hashable, Sendable {
    let id: BackendID
    let name: String
    let sshAlias: String?

    static let local = DiscoveredMachine(
        id: BackendID("local"),
        name: "This Mac",
        sshAlias: nil
    )
}

struct MachineSessionSnapshot: Sendable {
    let machine: DiscoveredMachine
    let sessions: [DiscoveredSession]
    let error: String?
}

enum MacSessionDiscovery {
    /// Reconstructs the machine list from locally cached records and SSH
    /// configuration without contacting any remote host.
    static func cachedMachines(
        projects: [Project],
        sessions: [SessionRecord],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [DiscoveredMachine] {
        var machines = SSHConfigLoader.hosts(homeDirectory: homeDirectory).map { host in
            DiscoveredMachine(id: host.id, name: host.displayName, sshAlias: host.alias)
        }
        var seenMachineIDs = Set(machines.map(\.id))
        let cachedBackendIDs = Set(projects.compactMap { $0.metadata["backendID"] }
            + sessions.compactMap { $0.backendID?.rawValue })
        for rawID in cachedBackendIDs where rawID.hasPrefix("ssh:") {
            let id = BackendID(rawID)
            guard seenMachineIDs.insert(id).inserted else { continue }
            let alias = String(rawID.dropFirst("ssh:".count))
            machines.append(DiscoveredMachine(id: id, name: alias, sshAlias: alias))
        }

        return [.local] + machines.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func discover(excluding disabledMachineIDs: Set<BackendID> = []) async -> [MachineSessionSnapshot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let localSessions: [DiscoveredSession]
        if disabledMachineIDs.contains(DiscoveredMachine.local.id) {
            localSessions = []
        } else {
            localSessions = await Task.detached {
                SessionHistoryDiscovery.discover(homeDirectory: home)
            }.value
        }
        let hosts = SSHConfigLoader.hosts(homeDirectory: home)

        var snapshots = [
            MachineSessionSnapshot(
                machine: .local,
                sessions: localSessions,
                error: nil
            )
        ]
        await withTaskGroup(of: MachineSessionSnapshot.self) { group in
            for host in hosts {
                group.addTask {
                    let machine = DiscoveredMachine(
                        id: host.id,
                        name: host.displayName,
                        sshAlias: host.alias
                    )
                    guard !disabledMachineIDs.contains(machine.id) else {
                        return MachineSessionSnapshot(machine: machine, sessions: [], error: nil)
                    }
                    do {
                        return MachineSessionSnapshot(
                            machine: machine,
                            sessions: try await RemoteSessionDiscovery.discover(host: host.alias),
                            error: nil
                        )
                    } catch {
                        return MachineSessionSnapshot(
                            machine: machine,
                            sessions: [],
                            error: error.localizedDescription
                        )
                    }
                }
            }
            for await snapshot in group {
                snapshots.append(snapshot)
            }
        }
        return snapshots.sorted {
            if $0.machine.id == DiscoveredMachine.local.id { return true }
            if $1.machine.id == DiscoveredMachine.local.id { return false }
            return $0.machine.name.localizedStandardCompare($1.machine.name) == .orderedAscending
        }
    }
}

private enum SSHConfigLoader {
    static func hosts(homeDirectory: URL) -> [SSHHostDescriptor] {
        let config = homeDirectory.appendingPathComponent(".ssh/config")
        var visited: Set<URL> = []
        var ordered: [SSHHostDescriptor] = []
        var seen: Set<String> = []
        load(config, homeDirectory: homeDirectory, visited: &visited) { text in
            for host in SSHConfigParser.hosts(in: text) where seen.insert(host.alias).inserted {
                ordered.append(host)
            }
        }
        return ordered
    }

    private static func load(
        _ url: URL,
        homeDirectory: URL,
        visited: inout Set<URL>,
        consume: (String) -> Void
    ) {
        let standardized = url.standardizedFileURL
        guard visited.insert(standardized).inserted,
              let text = try? String(contentsOf: standardized, encoding: .utf8) else { return }
        consume(text)

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard fields.first?.lowercased() == "include" else { continue }
            for pattern in fields.dropFirst() {
                for included in matchingFiles(
                    pattern,
                    relativeTo: standardized.deletingLastPathComponent(),
                    homeDirectory: homeDirectory
                ) {
                    load(included, homeDirectory: homeDirectory, visited: &visited, consume: consume)
                }
            }
        }
    }

    private static func matchingFiles(
        _ pattern: String,
        relativeTo base: URL,
        homeDirectory: URL
    ) -> [URL] {
        let expanded: String
        if pattern == "~" || pattern.hasPrefix("~/") {
            expanded = homeDirectory.path + pattern.dropFirst()
        } else if pattern.hasPrefix("/") {
            expanded = pattern
        } else {
            expanded = base.appendingPathComponent(pattern).path
        }
        guard expanded.contains("*") || expanded.contains("?") else {
            return [URL(fileURLWithPath: expanded)]
        }

        let url = URL(fileURLWithPath: expanded)
        let directory = url.deletingLastPathComponent()
        let expression = NSRegularExpression.escapedPattern(for: url.lastPathComponent)
            .replacingOccurrences(of: #"\*"#, with: ".*")
            .replacingOccurrences(of: #"\?"#, with: ".")
        guard let regex = try? NSRegularExpression(pattern: "^\(expression)$"),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else { return [] }
        return files.filter {
            let name = $0.lastPathComponent
            return regex.firstMatch(
                in: name,
                range: NSRange(name.startIndex..., in: name)
            ) != nil
        }.sorted { $0.path < $1.path }
    }
}

enum RemoteSessionDiscovery {
    private struct WireSession: Decodable {
        struct WireMessage: Decodable {
            let role: String
            let text: String
            let timestamp: String?
        }

        let provider: String
        let id: String
        let title: String
        let cwd: String?
        let model: String?
        let createdAt: String?
        let updatedAt: String?
        let messages: [WireMessage]
        let totalUsage: TokenUsage?
    }

    static func discover(host: String) async throws -> [DiscoveredSession] {
        try await Task.detached {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-oBatchMode=yes",
                "-oConnectTimeout=3",
                "-oConnectionAttempts=1",
                "-oStrictHostKeyChecking=yes",
            ] + SSHBackend.connectionReuseOptions + [
                "--",
                host,
                "python3 -c \(SSHBackend.shellQuote(remoteScript))",
            ]
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SkynetError.executionFailed(
                    reason: SSHBackend.failureReason(
                        operation: "Remote session discovery on \(host)",
                        exitCode: process.terminationStatus,
                        stderr: String(decoding: errorData, as: UTF8.self)
                    )
                )
            }
            let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
            return lines.compactMap { line in
                guard let wire = try? JSONDecoder().decode(WireSession.self, from: Data(line.utf8)),
                      let providerID = providerID(wire.provider) else { return nil }
                let messages = wire.messages.compactMap { item -> Message? in
                    guard !item.text.isEmpty else { return nil }
                    return Message(
                        origin: item.role == "user" ? .user : .agent,
                        content: [.text(item.text)],
                        createdAt: date(item.timestamp) ?? Date(),
                        modelID: item.role == "assistant" ? wire.model.map { ModelID($0) } : nil,
                        providerID: providerID
                    )
                }
                let fallbackDate = Date()
                return DiscoveredSession(
                    providerID: providerID,
                    providerSessionID: wire.id,
                    title: wire.title,
                    workingDirectory: wire.cwd,
                    modelID: wire.model.map { ModelID($0) },
                    createdAt: date(wire.createdAt) ?? messages.first?.createdAt ?? fallbackDate,
                    updatedAt: date(wire.updatedAt) ?? messages.last?.createdAt ?? fallbackDate,
                    messages: messages,
                    totalUsage: wire.totalUsage ?? TokenUsage()
                )
            }
        }.value
    }

    static func transcriptPage(
        for record: SessionRecord,
        before cursor: Int64? = nil
    ) async throws -> SessionTranscriptPage? {
        guard let backendID = record.backendID?.rawValue,
              backendID.hasPrefix("ssh:"),
              let token = record.providerResumeToken else { return nil }
        let host = String(backendID.dropFirst("ssh:".count))
        let provider = record.providerID.rawValue
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-oBatchMode=yes", "-oConnectTimeout=5", "-oStrictHostKeyChecking=yes",
            ] + SSHBackend.connectionReuseOptions + [
                "--", host,
                "python3 -c \(SSHBackend.shellQuote(fullTranscriptScript)) "
                    + "\(SSHBackend.shellQuote(provider)) \(SSHBackend.shellQuote(token)) "
                    + "\(cursor.map { String($0) } ?? "latest")",
            ]
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SkynetError.executionFailed(
                    reason: SSHBackend.failureReason(
                        operation: "Remote transcript loading",
                        exitCode: process.terminationStatus,
                        stderr: String(decoding: errorData, as: UTF8.self)
                    )
                )
            }
            return try SessionTranscriptPageParser.parse(
                output,
                for: record,
                temporaryFilePrefix: "skynet-remote-page",
                invalidPageMessage: "Remote transcript page was invalid."
            )
        }.value
    }

    private static let fullTranscriptScript = #"""
import glob,json,os,sys
provider,sid,cursor=sys.argv[1:4]
home=os.path.expanduser('~')

def previous_line_start(source, offset):
    upper=offset
    while upper>0:
        lower=max(0,upper-65536)
        source.seek(lower)
        chunk=source.read(upper-lower)
        newline=chunk.rfind(b'\n')
        if newline>=0: return lower+newline+1
        upper=lower
    return 0

if provider=='codex':
    paths=[p for p in glob.glob(os.path.join(home,'.codex','sessions','**','*.jsonl'),recursive=True)
           if sid in os.path.basename(p)]
elif provider=='claude-code':
    paths=glob.glob(os.path.join(home,'.claude','projects','*',sid+'.jsonl'))
else:
    paths=[]
if not paths:
    sys.exit(2)
path=max(paths,key=os.path.getmtime)
size=os.path.getsize(path); page_size=\#(JSONDiskStore.messagePageSize)
end=size if cursor=='latest' else min(size,int(cursor))
start=max(0,end-page_size)
requested_start=start
with open(path,'rb') as source:
    if start:
        source.seek(start-1)
        if source.read(1)!=b'\n':
            source.readline()
            start=source.tell()
            if start>=end:
                start=previous_line_start(source,requested_start)
        else: source.seek(start)
    source.seek(0)
    meta=None
    while True:
        line=source.readline()
        if not line: break
        try:
            item=json.loads(line)
            if item.get('type')=='session_meta': meta=line; break
        except: pass
    sys.stdout.buffer.write((json.dumps({'cursor':start})+'\n').encode())
    if start and meta: sys.stdout.buffer.write(meta)
    source.seek(start)
    sys.stdout.buffer.write(source.read(max(0,end-start)))
"""#

    private static func providerID(_ value: String) -> ProviderID? {
        switch value {
        case "codex": return .codex
        case "claude-code": return .claudeCode
        default: return nil
        }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalDateFormatter.date(from: value) ?? dateFormatter.date(from: value)
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let dateFormatter = ISO8601DateFormatter()

    private static let remoteScript = #"""
import glob,json,os,re
from datetime import datetime,timezone

def iso(ts):
    if not ts: return None
    return ts

def title(text):
    text=' '.join((text or 'Imported session').split())
    return text if len(text)<=80 else text[:79]+'…'

def clean_user_text(text):
    tags='local-command-caveat|command-name|command-message|command-args|local-command-stdout|system-reminder|task-notification'
    return re.sub(r'<('+tags+r')\b[^>]*>.*?</\1>', '', text or '', flags=re.S).strip()

def codex_usage(value):
    cached = value.get('cached_input_tokens', 0) or 0
    written = value.get('cache_write_input_tokens', 0) or 0
    input_count = value.get('input_tokens', 0) or 0
    return {
        'inputTokens': max(0, input_count - cached - written),
        'cacheReadTokens': cached,
        'cacheWriteTokens': written,
        'outputTokens': value.get('output_tokens', 0) or 0,
    }

def claude_usage(value):
    return {
        'inputTokens': value.get('input_tokens', 0) or 0,
        'cacheReadTokens': value.get('cache_read_input_tokens', 0) or 0,
        'cacheWriteTokens': value.get('cache_creation_input_tokens', 0) or 0,
        'outputTokens': value.get('output_tokens', 0) or 0,
    }

def add_usage(values):
    keys = ('inputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'outputTokens')
    totals = dict.fromkeys(keys, 0)
    for item in values:
        for key in keys:
            totals[key] += item.get(key, 0)
    return totals

def emit(provider,sid,cwd,name,created,updated,model,messages,usage):
    print(json.dumps({
        'provider': provider,
        'id': sid,
        'cwd': cwd,
        'title': title(name),
        'createdAt': created,
        'updatedAt': updated,
        'model': model,
        'messages': messages[-500:],
        'totalUsage': usage,
    }, ensure_ascii=False))

home=os.path.expanduser('~')
titles={}
try:
    for line in open(os.path.join(home,'.codex','session_index.jsonl'),errors='ignore'):
        try:
            item=json.loads(line); name=item.get('thread_name')
            if name: titles[item.get('id')]=name
        except: pass
except: pass

paths=glob.glob(os.path.join(home,'.codex','sessions','**','*.jsonl'),recursive=True)
for path in sorted(paths,key=lambda p:os.path.getmtime(p),reverse=True)[:200]:
    sid=cwd=created=None; updated=model=None; messages=[]; child=False; usage=None
    try:
        for line in open(path,errors='ignore'):
            try: item=json.loads(line)
            except: continue
            stamp=item.get('timestamp'); updated=stamp or updated
            payload=item.get('payload') or {}
            if item.get('type')=='session_meta':
                sid=payload.get('id') or payload.get('session_id'); cwd=payload.get('cwd'); created=payload.get('timestamp') or stamp
                source=payload.get('source')
                subagent=source.get('subagent') if isinstance(source,dict) else None
                child=bool(payload.get('parent_thread_id') or subagent)
            elif item.get('type')=='turn_context':
                model=payload.get('model') or model
            elif item.get('type')=='event_msg' and payload.get('type')=='token_count':
                total=(payload.get('info') or {}).get('total_token_usage')
                if isinstance(total,dict):
                    usage=codex_usage(total)
            elif item.get('type')=='response_item' and payload.get('type')=='message' and payload.get('role') in ('user','assistant'):
                role=payload['role']; accepted=('input_text','text') if role=='user' else ('output_text','text')
                content=payload.get('content',[]); kinds=((payload.get('internal_chat_message_metadata_passthrough') or {}).get('content_item_kinds') or [])
                if role=='user' and len(content)==len(kinds):
                    texts=[b.get('text','') for b,k in zip(content,kinds) if k=='user.text' and isinstance(b,dict) and b.get('type') in accepted]
                else:
                    texts=[b.get('text','') for b in content if isinstance(b,dict) and b.get('type') in accepted]
                text='\n'.join(t for t in texts if t)
                if text: messages.append({'role':role,'text':text,'timestamp':stamp})
        if sid and not child:
            name=titles.get(sid) or next((m['text'] for m in messages if m['role']=='user'),'Imported session')
            emit('codex',sid,cwd,name,created,updated,model,messages,usage)
    except: pass

paths=glob.glob(os.path.join(home,'.claude','projects','*','*.jsonl'))
for path in sorted(paths,key=lambda p:os.path.getmtime(p),reverse=True)[:200]:
    sid=cwd=name=created=updated=model=None; messages=[]; usage_by_id={}
    try:
        for line in open(path,errors='ignore'):
            try: item=json.loads(line)
            except: continue
            if item.get('isSidechain'): continue
            sid=sid or item.get('sessionId'); cwd=cwd or item.get('cwd')
            if item.get('type')=='ai-title': name=item.get('aiTitle') or name
            if item.get('type') not in ('user','assistant'): continue
            message=item.get('message') or {}; role=message.get('role') or item.get('type'); stamp=item.get('timestamp')
            created=created or stamp; updated=stamp or updated; model=message.get('model') or model
            if role=='assistant' and isinstance(message.get('usage'),dict):
                key=message.get('id') or str(len(usage_by_id))
                usage_by_id[key]=claude_usage(message['usage'])
            content=message.get('content'); texts=[]
            if isinstance(content,str): texts=[content]
            elif isinstance(content,list): texts=[b.get('text','') for b in content if isinstance(b,dict) and b.get('type')=='text']
            text='\n'.join(t for t in texts if t)
            if role=='user': text=clean_user_text(text)
            if text: messages.append({'role':role,'text':text,'timestamp':stamp})
        if sid:
            name=name or next((m['text'] for m in messages if m['role']=='user'),'Imported session')
            usage=add_usage(usage_by_id.values()) if usage_by_id else None
            emit('claude-code',sid,cwd,name,created,updated,model,messages,usage)
    except: pass
"""#
}

struct SessionTranscriptPage {
    let session: DiscoveredSession
    let olderCursor: Int64?
}

private enum SessionTranscriptPageParser {
    private struct Envelope: Decodable {
        let cursor: Int64
    }

    static func parse(
        _ output: Data,
        for record: SessionRecord,
        temporaryFilePrefix: String,
        invalidPageMessage: String
    ) throws -> SessionTranscriptPage? {
        guard let newline = output.firstIndex(of: 0x0A),
              let envelope = try? JSONDecoder().decode(
                Envelope.self,
                from: Data(output[..<newline])
              ) else {
            throw SkynetError.executionFailed(reason: invalidPageMessage)
        }

        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryFilePrefix)-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcriptURL) }
        try Data(output[(newline + 1)...]).write(to: transcriptURL, options: .atomic)

        let session: DiscoveredSession?
        switch record.providerID {
        case .codex:
            session = SessionHistoryDiscovery.parseCodexTranscript(
                at: transcriptURL, indexedTitle: record.title
            )
        case .claudeCode:
            session = SessionHistoryDiscovery.parseClaudeTranscript(at: transcriptURL)
        default:
            session = nil
        }
        guard let session else { return nil }
        return SessionTranscriptPage(
            session: session,
            olderCursor: envelope.cursor > 0 ? envelope.cursor : nil
        )
    }
}

enum SessionTranscriptDiscovery {
    static func transcriptPage(
        for record: SessionRecord,
        before cursor: Int64? = nil
    ) async throws -> SessionTranscriptPage? {
        guard let backendID = record.backendID?.rawValue else { return nil }
        if backendID == DiscoveredMachine.local.id.rawValue {
            return try await LocalSessionTranscriptDiscovery.transcriptPage(
                for: record, before: cursor
            )
        }
        if backendID.hasPrefix("ssh:") {
            return try await RemoteSessionDiscovery.transcriptPage(for: record, before: cursor)
        }
        return nil
    }
}

private enum LocalSessionTranscriptDiscovery {
    private static let pageSize = JSONDiskStore.messagePageSize
    private static let maxMetadataLineSize = 1024 * 1024

    static func transcriptPage(
        for record: SessionRecord,
        before cursor: Int64? = nil
    ) async throws -> SessionTranscriptPage? {
        guard let token = record.providerResumeToken,
              (record.providerID == .codex || record.providerID == .claudeCode) else { return nil }
        return try await Task.detached(priority: .userInitiated) {
            guard let sourceURL = transcriptURL(providerID: record.providerID, token: token) else {
                return nil
            }
            let output = try readPage(at: sourceURL, before: cursor)
            return try SessionTranscriptPageParser.parse(
                output,
                for: record,
                temporaryFilePrefix: "skynet-local-page",
                invalidPageMessage: "Local transcript page was invalid."
            )
        }.value
    }

    private static func transcriptURL(providerID: ProviderID, token: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root: URL
        switch providerID {
        case .codex:
            root = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        case .claudeCode:
            root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        default:
            return nil
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, modifiedAt: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let matches = providerID == .codex
                ? url.lastPathComponent.contains(token)
                : url.deletingPathExtension().lastPathComponent == token
            guard matches,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else { continue }
            if let current = newest, modifiedAt <= current.modifiedAt { continue }
            newest = (url, modifiedAt)
        }
        return newest?.url
    }

    private static func readPage(at url: URL, before cursor: Int64?) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let end = min(UInt64(max(0, cursor ?? Int64(fileSize))), fileSize)
        var start = end > UInt64(pageSize) ? end - UInt64(pageSize) : 0
        let requestedStart = start
        if start > 0 {
            handle.seek(toFileOffset: start - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) {
                start = try nextLineStart(in: handle, from: start, before: end)
                if start >= end {
                    start = try previousLineStart(in: handle, before: requestedStart)
                }
            }
        }

        var output = Data("{\"cursor\":\(start)}\n".utf8)
        if start > 0 {
            handle.seek(toFileOffset: 0)
            output.append(try readFirstLine(from: handle))
        }
        handle.seek(toFileOffset: start)
        output.append(try handle.read(upToCount: Int(end - start)) ?? Data())
        return output
    }

    private static func nextLineStart(
        in handle: FileHandle,
        from offset: UInt64,
        before end: UInt64
    ) throws -> UInt64 {
        var position = offset
        while position < end {
            handle.seek(toFileOffset: position)
            let chunk = try handle.read(upToCount: Int(min(64 * 1024, end - position))) ?? Data()
            guard !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                return position + UInt64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
            }
            position += UInt64(chunk.count)
        }
        return end
    }

    private static func previousLineStart(in handle: FileHandle, before offset: UInt64) throws -> UInt64 {
        var upperBound = offset
        while upperBound > 0 {
            let lowerBound = upperBound > 64 * 1024 ? upperBound - 64 * 1024 : 0
            handle.seek(toFileOffset: lowerBound)
            let chunk = try handle.read(upToCount: Int(upperBound - lowerBound)) ?? Data()
            if let newline = chunk.lastIndex(of: 0x0A) {
                return lowerBound + UInt64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
            }
            upperBound = lowerBound
        }
        return 0
    }

    private static func readFirstLine(from handle: FileHandle) throws -> Data {
        var line = Data()
        while line.count < maxMetadataLineSize {
            let chunk = try handle.read(upToCount: 16 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[..<newline])
                line.append(0x0A)
                return line
            }
            line.append(chunk)
        }
        return line
    }
}
