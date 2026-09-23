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

private enum RemoteSessionDiscovery {
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
                let detail = String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw SkynetError.executionFailed(
                    reason: detail.isEmpty ? "SSH discovery failed for \(host)." : detail
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
                    messages: messages
                )
            }
        }.value
    }

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

def emit(provider,sid,cwd,name,created,updated,model,messages):
    print(json.dumps({'provider':provider,'id':sid,'cwd':cwd,'title':title(name),'createdAt':created,'updatedAt':updated,'model':model,'messages':messages[-500:]},ensure_ascii=False))

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
    sid=cwd=created=None; updated=model=None; messages=[]; child=False
    try:
        for line in open(path,errors='ignore'):
            try: item=json.loads(line)
            except: continue
            stamp=item.get('timestamp'); updated=stamp or updated
            payload=item.get('payload') or {}
            if item.get('type')=='session_meta':
                sid=payload.get('id') or payload.get('session_id'); cwd=payload.get('cwd'); created=payload.get('timestamp') or stamp
                child=bool(payload.get('parent_thread_id') or (payload.get('source') or {}).get('subagent'))
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
            emit('codex',sid,cwd,name,created,updated,model,messages)
    except: pass

paths=glob.glob(os.path.join(home,'.claude','projects','*','*.jsonl'))
for path in sorted(paths,key=lambda p:os.path.getmtime(p),reverse=True)[:200]:
    sid=cwd=name=created=updated=model=None; messages=[]
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
            content=message.get('content'); texts=[]
            if isinstance(content,str): texts=[content]
            elif isinstance(content,list): texts=[b.get('text','') for b in content if isinstance(b,dict) and b.get('type')=='text']
            text='\n'.join(t for t in texts if t)
            if role=='user': text=clean_user_text(text)
            if text: messages.append({'role':role,'text':text,'timestamp':stamp})
        if sid:
            name=name or next((m['text'] for m in messages if m['role']=='user'),'Imported session')
            emit('claude-code',sid,cwd,name,created,updated,model,messages)
    except: pass
"""#
}
