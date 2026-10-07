import Foundation
import SkynetCore
import Testing

@Suite("Transcript message merge")
struct TranscriptMessageMergerTests {
    @Test func explicitProviderAliasRepairsPersistedNormalizedCopyAndKeepsOriginalImage() {
        let original = Message(origin: .user, content: [.text("look"),
            .image(ImageAttachment(data: Data("animated source".utf8), mediaType: "image/gif", fileName: "source.gif"))],
            createdAt: Date(timeIntervalSince1970: 100), providerID: .codex)
        let normalized = Message(origin: .user, content: [.text("look"),
            .image(ImageAttachment(data: Data("normalized frame".utf8), mediaType: "image/png"))],
            createdAt: Date(timeIntervalSince1970: 111), providerID: .codex)
        var correlated = original
        correlated.providerMessageID = normalized.id
        correlated.createdAt = normalized.createdAt

        let merged = TranscriptMessageMerger.merge([original, normalized], [correlated])
        #expect(merged.count == 1)
        #expect(merged[0].id == original.id)
        #expect(merged[0].content == original.content)
        #expect(merged[0].createdAt == original.createdAt)
        #expect(merged[0].providerMessageID == normalized.id)
        #expect(TranscriptMessageMerger.messagesNotIn([correlated], comparedTo: [original, normalized]).isEmpty)
        #expect(TranscriptMessageMerger.merge([normalized], [correlated]) == [correlated])
        #expect(TranscriptMessageMerger.merge([correlated], [normalized]) == [correlated])
        #expect(TranscriptMessageMerger.messagesNotIn([normalized], comparedTo: [correlated]).isEmpty)
        #expect(TranscriptMessageMerger.messagesNotIn([original, normalized], comparedTo: [correlated]).isEmpty)
        #expect(TranscriptMessageMerger.merge([original, normalized], []).count == 2)
    }

    @Test func explicitAliasesPreserveSeparateRepeatedRequestsAndIgnoreConflictingProviders() {
        let first = message("continue", at: 100)
        let repeated = message("continue", at: 105)
        let native = message("normalized", at: 111)
        let secondNative = message("normalized", at: 116)
        var correlated = first
        correlated.providerMessageID = native.id
        var secondCorrelated = repeated
        secondCorrelated.providerMessageID = secondNative.id
        let merged = TranscriptMessageMerger.merge(
            [first, native, repeated, secondNative], [correlated, secondCorrelated])
        #expect(merged.map(\.id) == [first.id, repeated.id])

        var otherProvider = native
        otherProvider.providerID = .claudeCode
        #expect(TranscriptMessageMerger.merge([otherProvider], [correlated]).count == 2)
        var otherOrigin = native
        otherOrigin.origin = .agent
        #expect(TranscriptMessageMerger.merge([otherOrigin], [correlated]).count == 2)
        var conflicting = repeated
        conflicting.providerMessageID = native.id
        #expect(TranscriptMessageMerger.merge([native], [correlated, conflicting]).count == 3)
    }

    @Test func optionalProviderAliasDecodesOldMessagesAndRoundTripsNewOnes() throws {
        let original = message("legacy", at: 100)
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "providerMessageID")
        #expect(try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: object)) == original)
        var correlated = original
        correlated.providerMessageID = MessageID()
        #expect(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(correlated)) == correlated)
    }
    @Test func preservesDistinctRapidAssistantMessagesWithinOneSource() {
        let commentary = message("Received", at: 100, origin: .agent)
        let final = message("Received", at: 100.006, origin: .agent)
        let replies = [commentary, final]
        #expect(TranscriptMessageMerger.merge(replies, []).map(\.id) == replies.map(\.id))
        #expect(TranscriptMessageMerger.messagesNotIn(replies, comparedTo: []).map(\.id) == replies.map(\.id))
        var providerFinal = final
        providerFinal.createdAt = Date(timeIntervalSince1970: 700)
        let merged = TranscriptMessageMerger.merge(replies, [providerFinal])
        #expect(merged.map(\.id) == replies.map(\.id))
        #expect(merged.map(\.createdAt) == replies.map(\.createdAt))
    }

    @Test func preservesDistinctRapidUserRequestsWithinOneSource() {
        let first = message("continue", at: 100)
        let repeated = message("continue", at: 100.006)
        let requests = [first, repeated]
        #expect(TranscriptMessageMerger.merge(requests, []).map(\.id) == requests.map(\.id))
        #expect(TranscriptMessageMerger.messagesNotIn(requests, comparedTo: []).map(\.id) == requests.map(\.id))
        var provider = repeated
        provider.createdAt = Date(timeIntervalSince1970: 700)
        #expect(TranscriptMessageMerger.merge(requests, [provider]).map(\.id) == requests.map(\.id))
    }

    @Test func collapsesRapidUserCopiesOnlyWithTheSameID() {
        let first = message("continue", at: 100)
        var copy = first
        copy.createdAt = Date(timeIntervalSince1970: 100.006)
        #expect(TranscriptMessageMerger.merge([first, copy], []).map(\.id) == [first.id])
        #expect(TranscriptMessageMerger.messagesNotIn([first, copy], comparedTo: []).map(\.id) == [first.id])
    }

    @Test func stableMessageIDReconcilesDelayedProviderCopyWithoutWideningClockWindow() {
        let cached = message("same request", at: 100)
        var provider = message("same request", at: 700)
        provider.id = cached.id

        #expect(TranscriptMessageMerger.merge([cached], [provider]).map(\.id) == [cached.id])
        #expect(TranscriptMessageMerger.messagesNotIn([provider], comparedTo: [cached]).isEmpty)
    }

    @Test func stableIDsPreserveLegitimateRepeatsAndTakePrecedenceOverNearerTimestamps() {
        let first = message("continue", at: 100)
        let repeated = message("continue", at: 105)
        var provider = repeated
        provider.createdAt = Date(timeIntervalSince1970: 101)

        #expect(TranscriptMessageMerger.merge([first, repeated], [provider]).map(\.id)
            == [first.id, repeated.id])
        var later = first
        later.createdAt = Date(timeIntervalSince1970: 400)
        #expect(TranscriptMessageMerger.merge([first, repeated], [provider, later]).count == 2)
    }

    @Test func deduplicatesSameTurnWhenProviderTimestampIsDelayed() {
        let cached = message("inspect the diff", at: 100)
        let provider = message("inspect the diff", at: 108.7)

        let merged = TranscriptMessageMerger.merge([provider], [cached])

        #expect(merged.count == 1)
        #expect(merged[0].createdAt == provider.createdAt)
    }

    @Test func deduplicatesObservedTenPointEightSevenSecondClockSkew() {
        let cached = message("Skynet Release smoke", at: 100)
        let provider = message("Skynet Release smoke", at: 110.87)

        let merged = TranscriptMessageMerger.merge([cached], [provider])

        #expect(merged.count == 1)
        #expect(merged[0].createdAt == cached.createdAt)
    }

    @Test func crossSourceMatchingPreservesRepeatedMessagesOneToOne() {
        let cached = [message("continue", at: 100), message("continue", at: 105)]
        let provider = [message("continue", at: 110.87), message("continue", at: 115.87)]

        let merged = TranscriptMessageMerger.merge(cached, provider)

        #expect(merged.count == 2)
        #expect(merged.map(\.createdAt) == cached.map(\.createdAt))
    }

    @Test func preservesRepeatedMessagesWithinOneSource() {
        let first = [message("continue", at: 100), message("continue", at: 105)]
        let second = [message("continue", at: 108)]

        let merged = TranscriptMessageMerger.merge(first, second)

        #expect(merged.count == 2)
        #expect(merged.map(\.createdAt) == first.map(\.createdAt))
    }

    @Test func collapsesAdjacentDuplicatesAlreadyPersistedInOneSource() {
        let original = message("same assistant reply", at: 100, origin: .agent)
        var copy = original
        copy.createdAt = Date(timeIntervalSince1970: 100.006)
        let first = [original, copy]

        let merged = TranscriptMessageMerger.merge(first, [])

        #expect(merged.count == 1)
        #expect(merged[0].createdAt == first[0].createdAt)
        #expect(TranscriptMessageMerger.messagesNotIn(first, comparedTo: []).map(\.id) == [original.id])
    }

    @Test func keepsIdenticalMessagesOutsideTheTimestampWindow() {
        let earlier = message("continue", at: 100)
        let later = message("continue", at: 116)

        let merged = TranscriptMessageMerger.merge([earlier], [later])

        #expect(merged.count == 2)
        #expect(merged.map(\.createdAt) == [earlier.createdAt, later.createdAt])
    }

    @Test func keepsDifferentMessagesAndSortsChronologically() {
        let later = message("finished", at: 120, origin: .agent)
        let earlier = message("start", at: 100)

        let merged = TranscriptMessageMerger.merge([later], [earlier])

        #expect(merged.map(\.plainText) == ["start", "finished"])
    }

    @Test func doesNotAppendProviderCopyAlreadyInTheCacheDespiteClockSkew() {
        let cached = message("look up the function", at: 100, providerID: nil)
        let provider = message("look up the function", at: 108.7)

        let newMessages = TranscriptMessageMerger.messagesNotIn([provider], comparedTo: [cached])

        #expect(newMessages.isEmpty)
    }

    @Test func returnsOnlyMessagesAbsentFromTheCache() {
        let cached = message("already cached", at: 100)
        let providerCopy = message("already cached", at: 108)
        let newProviderMessage = message("new from provider", at: 120, origin: .agent)

        let newMessages = TranscriptMessageMerger.messagesNotIn(
            [providerCopy, newProviderMessage],
            comparedTo: [cached]
        )

        #expect(newMessages.map(\.plainText) == ["new from provider"])
    }

    @Test func reconcilesProviderInlineImageWithCachedBlobDespiteDifferentIDs() throws {
        let temporaryDirectory = try TempDirectory()
        let imageData = Data("same image bytes".utf8)
        let blobStore = try BlobStore(
            directory: temporaryDirectory.url.appendingPathComponent("blobs", isDirectory: true)
        )
        let blob = try blobStore.store(imageData, mediaType: "image/png", fileName: "icon.png")
        let cachedAttachment = ImageAttachment(
            id: UUID(),
            payload: .blob(blob),
            fileName: "icon.png"
        )
        let providerAttachment = ImageAttachment(
            data: imageData,
            mediaType: "image/png"
        )
        let cached = Message(
            origin: .user,
            content: [.text("what is in this image?"), .image(cachedAttachment)],
            createdAt: Date(timeIntervalSince1970: 100),
            providerID: .codex
        )
        let provider = Message(
            origin: .user,
            content: [.text("what is in this image?"), .image(providerAttachment)],
            createdAt: Date(timeIntervalSince1970: 108),
            providerID: .codex
        )

        let merged = TranscriptMessageMerger.merge([provider], [cached])

        #expect(merged.count == 1)
        #expect(merged[0].id == provider.id)
    }

    @Test func preservesRapidRepeatedImageMessagesWithinOneSource() {
        let imageData = Data("same image bytes".utf8)
        let first = Message(
            origin: .user,
            content: [
                .text("what is in this image?"),
                .image(ImageAttachment(data: imageData, mediaType: "image/png")),
            ],
            createdAt: Date(timeIntervalSince1970: 100),
            providerID: .codex
        )
        let repeated = Message(
            origin: .user,
            content: [
                .text("what is in this image?"),
                .image(ImageAttachment(data: imageData, mediaType: "image/png")),
            ],
            createdAt: Date(timeIntervalSince1970: 100.006),
            providerID: .codex
        )

        let merged = TranscriptMessageMerger.merge([first, repeated], [])

        #expect(merged.map(\.id) == [first.id, repeated.id])
        #expect(TranscriptMessageMerger.messagesNotIn([first, repeated], comparedTo: []).map(\.id)
            == [first.id, repeated.id])
    }

    private func message(
        _ text: String,
        at timestamp: TimeInterval,
        origin: Message.Origin = .user,
        providerID: ProviderID? = .codex
    ) -> Message {
        Message(
            origin: origin,
            content: [.text(text)],
            createdAt: Date(timeIntervalSince1970: timestamp),
            providerID: providerID
        )
    }
}
