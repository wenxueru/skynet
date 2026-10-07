import Foundation
import SkynetCore

/// Read-only check of one explicitly selected QA prompt. Stdin contains only
/// its provider metadata/response/completion frames; argv names its exact cache.
/// Never enumerates accounts, sends turns or writes the real cache.
@main
enum TranscriptImageCorrelationRegression {
    static func main() {
        do { try verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func verify() throws {
        guard CommandLine.arguments.count == 3 else { throw failure("Expected exact cache path and prompt marker") }
        let marker = CommandLine.arguments[2]
        let cacheData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let cached = try cacheData.split(separator: 0x0A).map { try StoreEnvelope.decode(Message.self, from: Data($0)) }
        let requests = cached.filter { $0.origin == .user && $0.plainText.hasPrefix(marker) }
        guard requests.count == 2,
              let original = requests.first(where: { message in
                  message.content.contains { if case .image(let image) = $0 { return image.mediaType == "image/gif" }; return false }
              }), let copy = requests.first(where: { $0.id != original.id }) else {
            throw failure("Expected precisely the observed original GIF and normalized copy")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("skynet-correlation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let providerFile = temporary.appendingPathComponent("selected.jsonl")
        try FileHandle.standardInput.readDataToEndOfFile().write(to: providerFile)
        guard let provider = SessionHistoryDiscovery.parseCodexTranscript(at: providerFile),
              provider.messages.count == 1, let correlated = provider.messages.first,
              correlated.id == original.id, correlated.providerMessageID == copy.id else {
            throw failure("Selected provider frames did not retain the exact native/client ID pair")
        }
        let merged = TranscriptMessageMerger.merge(cached, provider.messages)
        let visible = merged.filter { $0.origin == .user && $0.plainText.hasPrefix(marker) }
        let unaffected = cached.filter { !($0.origin == .user && $0.plainText.hasPrefix(marker)) }
        guard visible.count == 1, visible[0].id == original.id,
              visible[0].content == original.content, visible[0].createdAt == original.createdAt,
              merged.count == cached.count - 1,
              unaffected.allSatisfy({ merged.contains($0) }),
              TranscriptMessageMerger.messagesNotIn(provider.messages, comparedTo: cached).isEmpty else {
            throw failure("Actual QA merge did not preserve one original request and every unrelated cache entry")
        }
        print("PASS: selected native \(copy.id) correlates to client \(original.id)")
        print("PASS: actual QA cache \(cached.count) -> \(merged.count), one prompt with original GIF/time retained")
        print("PASS: selected provider reload contributes no duplicate; real files unchanged")
    }

    private static func failure(_ description: String) -> NSError {
        NSError(domain: "TranscriptCorrelationFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
