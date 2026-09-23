import Foundation

/// A provider-owned conversation found outside Skynet's own store.
public struct DiscoveredSession: Sendable {
    public var providerID: ProviderID
    public var providerSessionID: String
    public var title: String
    public var workingDirectory: String?
    public var modelID: ModelID?
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [Message]
    public var totalUsage: TokenUsage

    public init(
        providerID: ProviderID,
        providerSessionID: String,
        title: String,
        workingDirectory: String?,
        modelID: ModelID?,
        createdAt: Date,
        updatedAt: Date,
        messages: [Message],
        totalUsage: TokenUsage = TokenUsage()
    ) {
        self.providerID = providerID
        self.providerSessionID = providerSessionID
        self.title = title
        self.workingDirectory = workingDirectory
        self.modelID = modelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.totalUsage = totalUsage
    }
}

/// Reads the on-disk histories maintained by the Codex and Claude Code CLIs.
public enum SessionHistoryDiscovery {
    public static func discover(
        homeDirectory: URL,
        limitPerProvider: Int = 200
    ) -> [DiscoveredSession] {
        let codex = discoverCodex(
            root: homeDirectory.appendingPathComponent(".codex"),
            limit: limitPerProvider
        )
        let claude = discoverClaude(
            root: homeDirectory.appendingPathComponent(".claude/projects"),
            limit: limitPerProvider
        )
        return (codex + claude).sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func parseCodexTranscript(
        at url: URL,
        indexedTitle: String? = nil
    ) -> DiscoveredSession? {
        guard let lines = readJSONLines(at: url), !lines.isEmpty else { return nil }

        var providerSessionID: String?
        var workingDirectory: String?
        var createdAt: Date?
        var updatedAt: Date?
        var messages: [Message] = []
        var isChildSession = false
        var totalUsage = TokenUsage()
        var modelID: ModelID?

        for frame in lines {
            let timestamp = date(frame["timestamp"]?.stringValue)
            if let timestamp {
                updatedAt = max(updatedAt ?? timestamp, timestamp)
            }

            switch frame["type"]?.stringValue {
            case "session_meta":
                guard let payload = frame["payload"] else { continue }
                providerSessionID = payload["id"]?.stringValue
                    ?? payload["session_id"]?.stringValue
                workingDirectory = payload["cwd"]?.stringValue
                createdAt = date(payload["timestamp"]?.stringValue) ?? timestamp
                isChildSession = payload["parent_thread_id"]?.stringValue != nil
                    || payload["source"]?["subagent"] != nil

            case "turn_context":
                if let model = frame["payload"]?["model"]?.stringValue {
                    modelID = ModelID(model)
                }

            case "event_msg":
                guard let payload = frame["payload"],
                      payload["type"]?.stringValue == "token_count",
                      let cumulative = payload["info"]?["total_token_usage"] else { continue }
                totalUsage = codexUsage(cumulative)

            case "response_item":
                guard let payload = frame["payload"] else { continue }
                let role = payload["role"]?.stringValue
                let content: [ContentBlock]
                let origin: Message.Origin
                switch payload["type"]?.stringValue {
                case "message" where role == "user" || role == "assistant":
                    content = codexMessageContent(payload, role: role!)
                    origin = role == "user" ? .user : .agent
                case "function_call", "custom_tool_call":
                    guard let id = payload["call_id"]?.stringValue,
                          let name = payload["name"]?.stringValue else { continue }
                    let raw = payload["arguments"]?.stringValue
                        ?? payload["input"]?.stringValue ?? ""
                    let input = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)))
                        ?? ["command": .string(raw)]
                    content = [.toolCall(ToolCall(id: ToolCallID(id), name: name, input: input))]
                    origin = .agent
                case "function_call_output", "custom_tool_call_output":
                    guard let id = payload["call_id"]?.stringValue else { continue }
                    let output = textContent(
                        payload["output"], acceptedTypes: ["input_text", "output_text", "text"]
                    )
                    content = [.toolResult(
                        toolCallID: ToolCallID(id), content: output,
                        isError: payload["is_error"]?.boolValue ?? false
                    )]
                    origin = .toolResult
                default:
                    continue
                }
                guard !content.isEmpty else { continue }
                messages.append(
                    Message(
                        origin: origin,
                        content: content,
                        createdAt: timestamp ?? updatedAt ?? Date(),
                        modelID: origin == .agent ? modelID : nil,
                        providerID: .codex
                    )
                )

            default:
                continue
            }
        }

        guard !isChildSession, let providerSessionID else { return nil }
        let fileDate = modificationDate(of: url) ?? Date()
        let firstUserText = messages.first(where: { $0.origin == .user })?.plainText
        return DiscoveredSession(
            providerID: .codex,
            providerSessionID: providerSessionID,
            title: preferredTitle(indexedTitle, fallback: firstUserText),
            workingDirectory: workingDirectory,
            modelID: modelID,
            createdAt: createdAt ?? messages.first?.createdAt ?? fileDate,
            updatedAt: updatedAt ?? messages.last?.createdAt ?? fileDate,
            messages: messages,
            totalUsage: totalUsage
        )
    }

    public static func parseClaudeTranscript(at url: URL) -> DiscoveredSession? {
        guard let lines = readJSONLines(at: url), !lines.isEmpty else { return nil }

        var providerSessionID: String?
        var workingDirectory: String?
        var title: String?
        var modelID: ModelID?
        var createdAt: Date?
        var updatedAt: Date?
        var messages: [Message] = []
        var usageMessageIndexes: [String: Int] = [:]

        for frame in lines {
            if frame["isSidechain"]?.boolValue == true { continue }
            providerSessionID = providerSessionID ?? frame["sessionId"]?.stringValue
            workingDirectory = workingDirectory ?? frame["cwd"]?.stringValue
            if frame["type"]?.stringValue == "ai-title" {
                title = frame["aiTitle"]?.stringValue
                continue
            }

            guard let type = frame["type"]?.stringValue,
                  type == "user" || type == "assistant",
                  let message = frame["message"] else { continue }
            let timestamp = date(frame["timestamp"]?.stringValue) ?? Date()
            createdAt = min(createdAt ?? timestamp, timestamp)
            updatedAt = max(updatedAt ?? timestamp, timestamp)

            if type == "assistant", let model = message["model"]?.stringValue {
                modelID = ModelID(model)
            }
            let content = claudeContent(message["content"], sanitizeUserText: type == "user")
            guard !content.isEmpty else { continue }
            let usage = type == "assistant" ? claudeUsage(message["usage"]) : nil
            let messageID = message["id"]?.stringValue
            var usageForMessage = usage
            if let messageID, let usage, let index = usageMessageIndexes[messageID] {
                messages[index].usage = usage
                usageForMessage = nil
            } else if let messageID, usage != nil {
                usageMessageIndexes[messageID] = messages.count
            }
            let containsToolResult = content.contains {
                if case .toolResult = $0 { return true }
                return false
            }
            messages.append(
                Message(
                    origin: containsToolResult ? .toolResult : (type == "user" ? .user : .agent),
                    content: content,
                    createdAt: timestamp,
                    modelID: type == "assistant" ? modelID : nil,
                    providerID: .claudeCode,
                    usage: usageForMessage
                )
            )
        }

        guard let providerSessionID else { return nil }
        let totalUsage = messages.compactMap(\.usage).reduce(TokenUsage(), +)
        let fileDate = modificationDate(of: url) ?? Date()
        let firstUserText = messages.first(where: { $0.origin == .user })?.plainText
        return DiscoveredSession(
            providerID: .claudeCode,
            providerSessionID: providerSessionID,
            title: preferredTitle(title, fallback: firstUserText),
            workingDirectory: workingDirectory,
            modelID: modelID,
            createdAt: createdAt ?? messages.first?.createdAt ?? fileDate,
            updatedAt: updatedAt ?? messages.last?.createdAt ?? fileDate,
            messages: messages,
            totalUsage: totalUsage
        )
    }

    private static func claudeUsage(_ value: JSONValue?) -> TokenUsage? {
        guard let value else { return nil }
        let usage = TokenUsage(
            inputTokens: value["input_tokens"]?.intValue,
            cacheReadTokens: value["cache_read_input_tokens"]?.intValue,
            cacheWriteTokens: value["cache_creation_input_tokens"]?.intValue,
            outputTokens: value["output_tokens"]?.intValue
        )
        return usage.totalTokens == nil ? nil : usage
    }

    private static func codexUsage(_ value: JSONValue) -> TokenUsage {
        // Codex's input_tokens includes cached reads; TokenUsage stores disjoint parts.
        let cached = value["cached_input_tokens"]?.intValue ?? 0
        let written = value["cache_write_input_tokens"]?.intValue ?? 0
        let input = value["input_tokens"]?.intValue
        return TokenUsage(
            inputTokens: input.map { max(0, $0 - cached - written) },
            cacheReadTokens: cached,
            cacheWriteTokens: written,
            outputTokens: value["output_tokens"]?.intValue,
            reasoningTokens: value["reasoning_output_tokens"]?.intValue
        )
    }

    private static func discoverCodex(root: URL, limit: Int) -> [DiscoveredSession] {
        let titles = codexTitles(at: root.appendingPathComponent("session_index.jsonl"))
        let sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
        return newestJSONLFiles(in: sessionRoot, recursive: true, limit: limit).compactMap {
            let id = codexSessionID(from: $0)
            return parseCodexTranscript(at: $0, indexedTitle: id.flatMap { titles[$0] })
        }
    }

    private static func discoverClaude(root: URL, limit: Int) -> [DiscoveredSession] {
        let manager = FileManager.default
        guard let projectDirectories = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        let files = projectDirectories.flatMap { directory -> [URL] in
            (try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
            ))?.filter { $0.pathExtension == "jsonl" } ?? []
        }
        return newest(files, limit: limit).compactMap(parseClaudeTranscript)
    }

    private static func codexTitles(at url: URL) -> [String: String] {
        guard let lines = readJSONLines(at: url) else { return [:] }
        var titles: [String: String] = [:]
        for line in lines {
            guard let id = line["id"]?.stringValue,
                  let title = line["thread_name"]?.stringValue,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            titles[id] = title
        }
        return titles
    }

    private static func codexSessionID(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let range = stem.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
            options: .regularExpression
        ) else { return nil }
        return String(stem[range])
    }

    private static func claudeContent(
        _ value: JSONValue?,
        sanitizeUserText: Bool
    ) -> [ContentBlock] {
        if let text = value?.stringValue {
            let rendered = sanitizeUserText ? sanitizedClaudeUserText(text) : text
            return rendered.isEmpty ? [] : [.text(rendered)]
        }
        return value?.arrayValue?.compactMap { block in
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.stringValue else { return nil }
                let rendered = sanitizeUserText ? sanitizedClaudeUserText(text) : text
                return rendered.isEmpty ? nil : .text(rendered)
            case "thinking":
                guard let text = block["thinking"]?.stringValue else { return nil }
                return .thinking(text: text, signature: block["signature"]?.stringValue)
            case "image":
                guard let source = block["source"],
                      source["type"]?.stringValue == "base64",
                      let mediaType = source["media_type"]?.stringValue,
                      mediaType.hasPrefix("image/"),
                      let encoded = source["data"]?.stringValue,
                      let data = Data(base64Encoded: encoded) else { return nil }
                return .image(ImageAttachment(data: data, mediaType: mediaType))
            case "tool_use":
                guard let id = block["id"]?.stringValue,
                      let name = block["name"]?.stringValue else { return nil }
                return .toolCall(
                    ToolCall(id: ToolCallID(id), name: name, input: block["input"] ?? .null)
                )
            case "tool_result":
                guard let id = block["tool_use_id"]?.stringValue else { return nil }
                let text = block["content"]?.stringValue
                    ?? textContent(block["content"], acceptedTypes: ["text"])
                return .toolResult(
                    toolCallID: ToolCallID(id),
                    content: text,
                    isError: block["is_error"]?.boolValue ?? false
                )
            default:
                return nil
            }
        } ?? []
    }

    private static func sanitizedClaudeUserText(_ text: String) -> String {
        let tags = [
            "local-command-caveat",
            "command-name",
            "command-message",
            "command-args",
            "local-command-stdout",
            "system-reminder",
            "task-notification",
        ].joined(separator: "|")
        let pattern = #"<(\#(tags))\b[^>]*>[\s\S]*?</\1>"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func textContent(
        _ value: JSONValue?,
        acceptedTypes: Set<String>
    ) -> String {
        if let text = value?.stringValue { return text }
        return value?.arrayValue?.compactMap { block in
            guard let type = block["type"]?.stringValue,
                  acceptedTypes.contains(type) else { return nil }
            return block["text"]?.stringValue
        }.joined(separator: "\n") ?? ""
    }

    private static func codexMessageContent(_ payload: JSONValue, role: String) -> [ContentBlock] {
        let acceptedTypes: Set<String> = role == "user"
            ? ["input_text", "text"]
            : ["output_text", "text"]
        guard let content = payload["content"]?.arrayValue else { return [] }
        let contentKinds = payload["internal_chat_message_metadata_passthrough"]?
            .objectValue?["content_item_kinds"]?.arrayValue
        let hasKinds = role == "user" && contentKinds?.count == content.count
        var textParts: [String] = []
        var images: [ContentBlock] = []

        for (index, block) in content.enumerated() {
            let kind = hasKinds ? contentKinds?[index].stringValue : nil
            switch block["type"]?.stringValue {
            case let type? where acceptedTypes.contains(type):
                guard role != "user" || kind == nil || kind == "user.text",
                      let text = block["text"]?.stringValue else { continue }
                textParts.append(text)
            case "input_image" where role == "user" && (kind == nil || kind == "user.image"):
                if let imageURL = block["image_url"]?.stringValue,
                   let attachment = imageAttachment(dataURL: imageURL) {
                    images.append(.image(attachment))
                }
            default:
                continue
            }
        }
        if !images.isEmpty {
            textParts.removeAll { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed == "</image>"
                    || trimmed.hasPrefix("<image name=") && trimmed.hasSuffix(">")
            }
        }
        let text = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? [] : [.text(text)]) + images
    }

    private static func imageAttachment(dataURL: String) -> ImageAttachment? {
        guard dataURL.hasPrefix("data:image/"),
              let marker = dataURL.range(of: ";base64,"),
              let data = Data(base64Encoded: String(dataURL[marker.upperBound...])) else { return nil }
        let mediaType = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<marker.lowerBound])
        return ImageAttachment(data: data, mediaType: mediaType)
    }

    private static func preferredTitle(_ candidate: String?, fallback: String?) -> String {
        let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = value?.isEmpty == false ? value! : fallback ?? "Imported session"
        let singleLine = source.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return singleLine.count <= 80 ? singleLine : String(singleLine.prefix(79)) + "…"
    }

    private static func readJSONLines(at url: URL) -> [JSONValue]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(JSONValue.self, from: Data($0))
        }
    }

    private static func newestJSONLFiles(
        in root: URL,
        recursive: Bool,
        limit: Int
    ) -> [URL] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files: [URL]
        if recursive {
            let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
            files = (enumerator?.allObjects as? [URL])?.filter { $0.pathExtension == "jsonl" } ?? []
        } else {
            files = (try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: keys
            ))?.filter { $0.pathExtension == "jsonl" } ?? []
        }
        return newest(files, limit: limit)
    }

    private static func newest(_ files: [URL], limit: Int) -> [URL] {
        files.sorted {
            (modificationDate(of: $0) ?? .distantPast) > (modificationDate(of: $1) ?? .distantPast)
        }.prefix(max(0, limit)).map { $0 }
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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
}
