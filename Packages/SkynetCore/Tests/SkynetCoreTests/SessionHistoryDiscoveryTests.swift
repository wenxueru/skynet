import Foundation
import SkynetCore
import Testing
#if canImport(ImageIO)
import ImageIO
#endif

@Suite("Session history discovery")
struct SessionHistoryDiscoveryTests {
    #if canImport(ImageIO)
    @Test(arguments: ["image/png", "image/jpeg", "image/webp"])
    func codexParserCorrelatesResizedImages(_ mediaType: String) throws {
        let original = try encodedImage(mediaType, width: 4096, height: 4)
        let prepared = try encodedImage(mediaType, width: 2048, height: 2)
        #expect(original != prepared)
        let clientID = UUID(), nativeID = UUID()
        let file = try resizedImageTranscript(original: original, prepared: prepared,
            originalType: mediaType, preparedType: mediaType, clientID: clientID, nativeID: nativeID)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let imported = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(imported.messages.map(\.id) == [MessageID(clientID)])
        #expect(imported.messages[0].providerMessageID == MessageID(nativeID))
        let cached = Message(id: MessageID(clientID), origin: .user,
            content: [.text("look"), .image(ImageAttachment(data: original, mediaType: mediaType))],
            createdAt: imported.messages[0].createdAt.addingTimeInterval(-600), providerID: .codex)
        #expect(imported.messages[0].plainText == cached.plainText)
        if case .image(let image) = imported.messages[0].content.last {
            #expect(image.payload == .inline(data: original, mediaType: mediaType))
        } else { Issue.record("Expected original image content") }
        let normalizedCopy = Message(id: MessageID(nativeID), origin: .user,
            content: [.text("look"), .image(ImageAttachment(data: prepared, mediaType: mediaType))],
            createdAt: imported.messages[0].createdAt, providerID: .codex)
        let merged = TranscriptMessageMerger.merge([cached, normalizedCopy], imported.messages)
        #expect(merged.count == 1)
        #expect(merged.first?.content == cached.content)
        #expect(merged.first?.createdAt == cached.createdAt)
        let reloaded = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(reloaded.messages.map(\.id) == imported.messages.map(\.id))
        #expect(reloaded.messages.map(\.providerMessageID) == imported.messages.map(\.providerMessageID))
        #expect(TranscriptMessageMerger.merge(merged, reloaded.messages).count == 1)
    }

    @Test(arguments: ["same dimensions", "upscale", "aspect", "invalid bytes",
                      "wrong media type", "different text", "wrong turn", "ambiguous responses", "missing client ID"])
    func codexResizedImageCorrelationRejectsInvalidPairs(_ mismatch: String) throws {
        let original = try encodedImage("image/png", width: 4096, height: 4)
        let width = mismatch == "same dimensions" ? 4096 : mismatch == "upscale" ? 8192 : 2048
        let height = mismatch == "same dimensions" ? 4 : mismatch == "upscale" ? 8 : mismatch == "aspect" ? 4 : 2
        let prepared = mismatch == "invalid bytes" ? Data([1, 2, 3])
            : try encodedImage("image/png", width: width, height: height, red: 1)
        let nativeID = UUID()
        let file = try resizedImageTranscript(original: original, prepared: prepared,
            originalType: "image/png", preparedType: mismatch == "wrong media type" ? "image/jpeg" : "image/png",
            clientID: mismatch == "missing client ID" ? nil : UUID(), nativeID: nativeID,
            completionText: mismatch == "different text" ? "other" : "look",
            completionTurn: mismatch == "wrong turn" ? "turn-2" : "turn-1",
            duplicateResponse: mismatch == "ambiguous responses")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let imported = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(imported.messages.allSatisfy { $0.id == MessageID(nativeID) && $0.providerMessageID == nil })
    }

    private func encodedImage(_ mediaType: String, width: Int, height: Int, red: CGFloat = 0) throws -> Data {
        if mediaType == "image/webp" {
            // Independent lossless Pillow-generated fixtures, decoded by ImageIO.
            let encoded = width == 4096
                ? "UklGRiQAAABXRUJQVlA4TBcAAAAv/88AAAfQqjY0tf9hABLC//9KRP9T/wA="
                : "UklGRiQAAABXRUJQVlA4TBcAAAAv/0cAAAfQqjY0tf8BICH8f69F9D/1AwA="
            return try #require(Data(base64Encoded: encoded))
        }
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: red, green: 0.3, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data,
            (mediaType == "image/jpeg" ? "public.jpeg" : "public.png") as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func resizedImageTranscript(original: Data, prepared: Data, originalType: String,
        preparedType: String, clientID: UUID?, nativeID: UUID, completionText: String = "look",
        completionTurn: String = "turn-1", duplicateResponse: Bool = false) throws -> URL {
        let response = """
        {"timestamp":"2026-10-03T12:01:56Z","type":"response_item","payload":{"id":"msg_\(nativeID.uuidString)","type":"message","role":"user","content":[{"type":"input_text","text":"look"},{"type":"input_image","image_url":"data:\(preparedType);base64,\(prepared.base64EncodedString())"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-1"}}}
        """
        return try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"resized-image"}}
        \(response)
        \(duplicateResponse ? response + "\n" : ""){"type":"event_msg","payload":{"type":"item_completed","turn_id":"\(completionTurn)","item":{"type":"UserMessage","client_id":"\(clientID?.uuidString ?? "invalid")","content":[{"type":"text","text":"\(completionText)"},{"type":"image","image_url":"data:\(originalType);base64,\(original.base64EncodedString())"}]}}}
        """)
    }
    #endif

    @Test func codexParserUsesClientCompletionForProviderNormalizedGIF() throws {
        let clientID = UUID(), nativeID = UUID()
        let original = Data("original animated GIF".utf8)
        let file = try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"normalized-image"}}
        {"timestamp":"2026-10-03T12:01:56Z","type":"response_item","payload":{"id":"msg_\(nativeID.uuidString)","type":"message","role":"user","content":[{"type":"input_text","text":"look"},{"type":"input_image","image_url":"data:image/png;base64,AQID"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-1"}}}
        {"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-1","item":{"type":"UserMessage","client_id":"\(clientID.uuidString)","content":[{"type":"text","text":"look"},{"type":"image","image_url":"data:image/gif;base64,\(original.base64EncodedString())"}]}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let imported = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(imported.messages.map(\.id) == [MessageID(clientID)])
        #expect(imported.messages[0].providerMessageID == MessageID(nativeID))
        let cached = Message(id: MessageID(clientID), origin: .user,
            content: [.text("look"), .image(ImageAttachment(data: original, mediaType: "image/gif"))],
            createdAt: imported.messages[0].createdAt.addingTimeInterval(-600), providerID: .codex)
        guard case .image(let image) = imported.messages[0].content.last else {
            Issue.record("Expected original image content"); return
        }
        #expect(image.mediaType == "image/gif")
        #expect(image.payload == .inline(data: original, mediaType: "image/gif"))
        #expect(TranscriptMessageMerger.merge([cached], imported.messages).count == 1)
    }

    @Test(arguments: ["different text", "missing image", "wrong turn", "ambiguous responses"])
    func codexGIFCorrelationStillRequiresMatchingTextShapeTurnAndUniqueResponse(_ mismatch: String) throws {
        let nativeID = UUID()
        let response = """
        {"type":"response_item","payload":{"id":"msg_\(nativeID.uuidString)","type":"message","role":"user","content":[{"type":"input_text","text":"look"},{"type":"input_image","image_url":"data:image/png;base64,AQID"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-1"}}}
        """
        let second = mismatch == "ambiguous responses" ? response + "\n" : ""
        let text = mismatch == "different text" ? "other" : "look"
        let image = mismatch == "missing image" ? "" : ",{\"type\":\"image\",\"image_url\":\"data:image/gif;base64,BAUG\"}"
        let turn = mismatch == "wrong turn" ? "turn-2" : "turn-1"
        let file = try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"normalized-image-guard"}}
        \(response)
        \(second){"type":"event_msg","payload":{"type":"item_completed","turn_id":"\(turn)","item":{"type":"UserMessage","client_id":"\(UUID().uuidString)","content":[{"type":"text","text":"\(text)"}\(image)]}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let imported = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(imported.messages.allSatisfy { $0.id == MessageID(nativeID) && $0.providerMessageID == nil })
    }
    @Test func codexParserCorrelatesSeparateClientIDAndPreservesRepeatedRequests() throws {
        let firstID = UUID()
        let secondID = UUID()
        let file = try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"client-correlation"}}
        {"timestamp":"2026-10-02T14:35:57Z","type":"response_item","payload":{"id":"msg_\(UUID().uuidString)","type":"message","role":"user","content":[{"type":"input_text","text":"continue"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-1","content_item_kinds":["user.text"]}}}
        {"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-1","item":{"type":"UserMessage","id":"\(UUID().uuidString)","client_id":"\(firstID.uuidString)","content":[{"type":"text","text":"continue"}]}}}
        {"timestamp":"2026-10-02T14:36:02Z","type":"response_item","payload":{"id":"msg_\(UUID().uuidString)","type":"message","role":"user","content":[{"type":"input_text","text":"continue"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-1","content_item_kinds":["user.text"]}}}
        {"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-1","item":{"type":"UserMessage","id":"\(UUID().uuidString)","client_id":"\(secondID.uuidString)","content":[{"type":"text","text":"continue"}]}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let imported = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(imported.messages.map(\.id) == [MessageID(firstID), MessageID(secondID)])
        let cached = [firstID, secondID].enumerated().map { index, id in
            Message(id: MessageID(id), origin: .user, content: [.text("continue")],
                    createdAt: imported.messages[index].createdAt.addingTimeInterval(-600))
        }
        #expect(TranscriptMessageMerger.merge(cached, imported.messages).map(\.id) == cached.map(\.id))
    }

    @Test func codexParserChecksTurnAndImageContentBeforeClientCorrelation() throws {
        let clientID = UUID()
        let nativeID = UUID()
        let file = try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"image-correlation"}}
        {"type":"response_item","payload":{"id":"msg_\(nativeID.uuidString)","type":"message","role":"user","content":[{"type":"input_text","text":"look"},{"type":"input_image","image_url":"data:image/png;base64,AQID"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-1","content_item_kinds":["user.text","user.image"]}}}
        {"type":"event_msg","payload":{"type":"item_completed","turn_id":"other-turn","item":{"type":"UserMessage","client_id":"\(UUID().uuidString)","content":[{"type":"text","text":"look"},{"type":"image","image_url":"data:image/png;base64,AQID"}]}}}
        {"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-1","item":{"type":"UserMessage","client_id":"\(clientID.uuidString)","content":[{"type":"text","text":"look"},{"type":"image","image_url":"data:image/png;base64,AQID"}]}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let imported = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(imported.messages.map(\.id) == [MessageID(clientID)])
        #expect(imported.messages[0].content.count == 2)
    }

    @Test func codexParserDoesNotGuessClientIDsAcrossIncompleteOrMismatchedRecords() throws {
        let nativeID = UUID()
        let file = try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"incomplete-correlation"}}
        {"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-1","item":{"type":"UserMessage","client_id":"\(UUID().uuidString)","content":[{"type":"text","text":"request"}]}}}
        {"type":"response_item","payload":{"id":"msg_\(nativeID.uuidString)","type":"message","role":"user","content":[{"type":"input_text","text":"request"},{"type":"input_image","image_url":"data:image/png;base64,AQID"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-1"}}}
        {"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-1","item":{"type":"UserMessage","client_id":"\(UUID().uuidString)","content":[{"type":"text","text":"request"},{"type":"image","image_url":"data:image/png;base64,BAUG"}]}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let imported = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(imported.messages.map(\.id) == [MessageID(nativeID)])
    }

    @Test func codexParserDoesNotGuessBetweenMultiplePendingResponseRecords() throws {
        let firstNativeID = UUID()
        let secondNativeID = UUID()
        let file = try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"ambiguous-correlation"}}
        {"type":"response_item","payload":{"id":"msg_\(firstNativeID.uuidString)","type":"message","role":"user","content":[{"type":"input_text","text":"continue"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-1"}}}
        {"type":"response_item","payload":{"id":"msg_\(secondNativeID.uuidString)","type":"message","role":"user","content":[{"type":"input_text","text":"continue"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-1"}}}
        {"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-1","item":{"type":"UserMessage","client_id":"\(UUID().uuidString)","content":[{"type":"text","text":"continue"}]}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let imported = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(imported.messages.map(\.id) == [MessageID(firstNativeID), MessageID(secondNativeID)])
    }

    @Test func codexParserRetainsClientAndNativeMessageIDsAcrossReloads() throws {
        let clientID = UUID()
        let nativeID = UUID()
        let file = try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"stable-id-session"}}
        {"timestamp":"2026-10-02T14:35:57Z","type":"response_item","payload":{"id":"\(clientID.uuidString)","type":"message","role":"user","content":[{"type":"input_text","text":"client request"}]}}
        {"timestamp":"2026-10-02T14:36:00Z","type":"response_item","payload":{"id":"msg_\(nativeID.uuidString)","type":"message","role":"assistant","content":[{"type":"output_text","text":"reply"}]}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let first = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        let reloaded = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(first.messages.map(\.id) == [MessageID(clientID), MessageID(nativeID)])
        #expect(reloaded.messages.map(\.id) == first.messages.map(\.id))
    }

    @Test func sshConfigReturnsOnlyLiteralHostsInOrder() {
        let config = """
        Host *
          ServerAliveInterval 30
        Host build-a build-b *.internal !blocked
          User runner
        host build-a
        """

        #expect(SSHConfigParser.hosts(in: config).map(\.alias) == ["build-a", "build-b"])
    }

    @Test func codexParserKeepsUserTextAndDropsInjectedContext() throws {
        let file = try temporaryFile(contents: """
        {"timestamp":"2026-09-22T01:00:00.000Z","type":"session_meta","payload":{"id":"01900000-0000-7000-8000-000000000001","timestamp":"2026-09-22T01:00:00.000Z","cwd":"/tmp/project","source":"cli"}}
        {"timestamp":"2026-09-22T01:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>hidden</environment_context>"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["environments.environment_context"]}}}
        {"timestamp":"2026-09-22T01:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the tests"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["user.text"]}}}
        {"timestamp":"2026-09-22T01:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(
            SessionHistoryDiscovery.parseCodexTranscript(at: file, indexedTitle: "Repair tests")
        )
        #expect(session.title == "Repair tests")
        #expect(session.workingDirectory == "/tmp/project")
        #expect(session.messages.map(\.plainText) == ["Fix the tests", "Done"])
    }

    @Test func codexParserSkipsSubagentRollouts() throws {
        let file = try temporaryFile(contents: """
        {"timestamp":"2026-09-22T01:00:00.000Z","type":"session_meta","payload":{"id":"01900000-0000-7000-8000-000000000002","cwd":"/tmp/project","source":{"subagent":{"other":"worker"}}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        #expect(SessionHistoryDiscovery.parseCodexTranscript(at: file) == nil)
    }

    @Test func codexParserRendersImagesWithoutMarkup() throws {
        let file = try temporaryFile(contents: #"""
        {"type":"session_meta","payload":{"id":"01900000-0000-7000-8000-000000000003","cwd":"/tmp/project"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Look at this"},{"type":"input_text","text":"<image name=[Image #1] path=\"/tmp/example.png\">"},{"type":"input_image","image_url":"data:image/png;base64,AQID"},{"type":"input_text","text":"</image>"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["user.text","user.text","user.image","user.text"]}}}
        """#)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        let message = try #require(session.messages.first)
        #expect(message.plainText == "Look at this")
        #expect(message.content.count == 2)
        if case .image(let image) = message.content[1],
           case .inline(let data, let mediaType) = image.payload {
            #expect(data == Data([1, 2, 3]))
            #expect(mediaType == "image/png")
        } else {
            Issue.record("Expected an image content block")
        }
    }

    @Test func codexParserKeepsToolCallsForGrouping() throws {
        let file = try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"01900000-0000-7000-8000-000000000004","cwd":"/tmp/project"}}
        {"type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-1","name":"exec","input":"rg TODO ."}}
        {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-1","output":"done"}}
        {"type":"response_item","payload":{"type":"function_call","call_id":"call-2","name":"Read","arguments":"{}"}}
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"call-2","output":"source"}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(session.messages.count == 4)
        let groups = TranscriptGrouping.groups(session.messages)
        if case .tools(_, let steps, _) = groups.first {
            #expect(steps.map(\.call?.name) == ["exec", "Read"])
            #expect(steps.map(\.result) == ["done", "source"])
        } else { Issue.record("Expected Codex tools to be grouped") }
    }

    @Test func codexParserImportsCumulativeTokenUsageWithoutDoubleCountingCache() throws {
        let file = try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"01900000-0000-7000-8000-000000000005"}}
        {"type":"turn_context","payload":{"model":"gpt-6-sol"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20}}}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":40,"output_tokens":25}}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(session.modelID == ModelID("gpt-6-sol"))
        #expect(session.totalUsage.inputTokens == 110)
        #expect(session.totalUsage.cacheReadTokens == 40)
        #expect(session.totalUsage.outputTokens == 25)
        #expect(session.totalUsage.totalTokens == 175)
    }

    @Test func claudeParserUsesAITitleAndTextMessages() throws {
        let file = try temporaryFile(contents: """
        {"type":"ai-title","sessionId":"10000000-0000-4000-8000-000000000001","aiTitle":"Refactor storage"}
        {"type":"user","sessionId":"10000000-0000-4000-8000-000000000001","cwd":"/tmp/project","timestamp":"2026-09-22T02:00:00.000Z","message":{"role":"user","content":"<local-command-caveat>hidden</local-command-caveat><command-name>/model</command-name>Please refactor storage<system-reminder>hidden</system-reminder>"}}
        {"type":"assistant","sessionId":"10000000-0000-4000-8000-000000000001","cwd":"/tmp/project","timestamp":"2026-09-22T02:00:01.000Z","message":{"role":"assistant","model":"claude-sonnet","content":[{"type":"text","text":"Finished"}]}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseClaudeTranscript(at: file))
        #expect(session.title == "Refactor storage")
        #expect(session.modelID == ModelID("claude-sonnet"))
        #expect(session.messages.map(\.plainText) == ["Please refactor storage", "Finished"])
    }

    @Test func claudeParserKeepsBase64ImageBlocks() throws {
        let file = try temporaryFile(contents: """
        {"type":"user","sessionId":"10000000-0000-4000-8000-000000000002","message":{"content":[{"type":"text","text":"Describe this"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AQID"}}]}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseClaudeTranscript(at: file))
        #expect(session.messages.first?.content.count == 2)
        if case .image = session.messages.first?.content.last {} else {
            Issue.record("Expected a Claude image content block")
        }
    }

    @Test func claudeParserDeduplicatesRepeatedAssistantUsage() throws {
        let file = try temporaryFile(contents: """
        {"type":"assistant","sessionId":"10000000-0000-4000-8000-000000000003","message":{"id":"msg-1","model":"claude-sonnet","content":[{"type":"text","text":"First"}],"usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3}}}
        {"type":"assistant","sessionId":"10000000-0000-4000-8000-000000000003","message":{"id":"msg-1","model":"claude-sonnet","content":[{"type":"text","text":"Updated"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":3}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseClaudeTranscript(at: file))
        #expect(session.totalUsage.inputTokens == 10)
        #expect(session.totalUsage.cacheReadTokens == 3)
        #expect(session.totalUsage.outputTokens == 5)
        #expect(session.messages.filter { $0.usage != nil }.count == 1)
    }

    private func temporaryFile(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try Data(contents.utf8).write(to: file)
        return file
    }
}
