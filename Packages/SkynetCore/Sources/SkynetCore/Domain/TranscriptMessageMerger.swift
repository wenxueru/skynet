import Foundation

/// Reconciles transcript messages loaded from independent sources, such as the
/// local cache and a provider transcript whose timestamps may differ slightly.
public enum TranscriptMessageMerger {
    /// Local/provider timestamps for the same QA message differed by 10.87s.
    private static let crossSourceTimestampWindow: TimeInterval = 15
    /// Previously merged history may already have persisted adjacent copies.
    private static let sameSourceTimestampWindow: TimeInterval = 1

    private enum ContentIdentity: Hashable {
        case value(ContentBlock)
        case image(mediaType: String, sha256: String)
    }

    private struct Identity: Hashable {
        let origin: String
        let content: [ContentIdentity]
    }

    /// Removes adjacent cache copies, then reconciles one-to-one matches
    /// between sources. Distinct IDs within a source are preserved unless an
    /// explicit native/client alias proves they are the same protocol message;
    /// identical content and nearby timestamps alone cannot collapse them.
    public static func merge(_ first: [Message], _ second: [Message]) -> [Message] {
        let reconciled = reconcilingProviderCopies(first, second)
        let first = removingAdjacentDuplicates(reconciled.first)
        let second = removingAdjacentDuplicates(reconciled.second)
        let duplicateIndices = matchingIndices(
            in: second,
            comparedTo: first,
            timestampWindow: crossSourceTimestampWindow
        )
        let merged = first + second.enumerated().compactMap { index, message in
            duplicateIndices.contains(index) ? nil : message
        }
        return sorted(merged)
    }

    /// Returns candidate messages not already represented in an existing page.
    /// Use this before appending provider history to the local transcript cache.
    public static func messagesNotIn(
        _ candidates: [Message],
        comparedTo existing: [Message]
    ) -> [Message] {
        let reconciled = reconcilingProviderCopies(existing, candidates)
        let candidates = removingAdjacentDuplicates(reconciled.second)
        let existing = removingAdjacentDuplicates(reconciled.first)
        let duplicateIndices = matchingIndices(
            in: candidates,
            comparedTo: existing,
            timestampWindow: crossSourceTimestampWindow
        )
        return candidates.enumerated().compactMap { index, message in
            duplicateIndices.contains(index) ? nil : message
        }
    }

    private struct ScopedID: Hashable {
        let provider: ProviderID
        let origin: String
        let id: MessageID

        init?(_ message: Message, id: MessageID? = nil) {
            guard let provider = message.providerID else { return nil }
            self.provider = provider
            self.origin = message.origin.rawValue
            self.id = id ?? message.id
        }
    }

    /// Only explicit native/client ID pairs can repair an already cached
    /// normalized copy. Same text/time/pixels never creates an alias.
    private static func reconcilingProviderCopies(
        _ first: [Message], _ second: [Message]
    ) -> (first: [Message], second: [Message]) {
        let correlated = (first + second).filter {
            $0.providerID != nil && $0.providerMessageID != nil && $0.providerMessageID != $0.id
        }
        let groups = Dictionary(grouping: correlated) { ScopedID($0, id: $0.providerMessageID)! }
        let aliases = groups.compactMapValues { group -> Message? in
            guard let first = group.first,
                  group.allSatisfy({ $0.id == first.id && hasSameContent($0, first) }) else { return nil }
            return first
        }
        guard !aliases.isEmpty else { return (first, second) }
        // Both sources use the same explicit aliases. Build their index once;
        // represented client IDs must still be determined within each source.
        let clients = Dictionary(grouping: aliases.values) { ScopedID($0)! }
        func reconcile(_ messages: [Message]) -> [Message] {
            let represented = Set(messages.compactMap { message -> ScopedID? in
                guard let key = ScopedID(message),
                      clients[key]?.contains(where: { hasSameContent(message, $0) }) == true else { return nil }
                return key
            })
            return messages.compactMap { message in
                guard let key = ScopedID(message) else { return message }
                if let original = aliases[key], let clientKey = ScopedID(original) {
                    return represented.contains(clientKey) ? nil : original
                }
                if let original = clients[key]?.first(where: { hasSameContent(message, $0) }) {
                    var enriched = message
                    enriched.providerMessageID = original.providerMessageID
                    return enriched
                }
                return message
            }
        }
        return (reconcile(first), reconcile(second))
    }

    private static func matchingIndices(
        in candidates: [Message],
        comparedTo existing: [Message],
        timestampWindow: TimeInterval
    ) -> Set<Int> {
        let existingIndices = Dictionary(grouping: existing.indices, by: { identity(for: existing[$0]) })
        let candidateIndices = Dictionary(grouping: candidates.indices, by: { identity(for: candidates[$0]) })
        var matches = Set<Int>()

        for (identity, existingGroup) in existingIndices {
            guard let candidateGroup = candidateIndices[identity] else { continue }
            var usedExisting = Set<Int>()
            let existingByID = Dictionary(grouping: existingGroup, by: { existing[$0].id })
            // Protocol-correlated IDs take precedence over approximate clock matching.
            for index in candidateGroup {
                if let match = existingByID[candidates[index].id]?.first(where: { !usedExisting.contains($0) }) {
                    matches.insert(index)
                    usedExisting.insert(match)
                }
            }
            let orderedExisting = existingGroup.filter { !usedExisting.contains($0) }.sorted {
                existing[$0].createdAt < existing[$1].createdAt
            }
            let orderedCandidates = candidateGroup.filter { !matches.contains($0) }.sorted {
                candidates[$0].createdAt < candidates[$1].createdAt
            }
            var firstOffset = 0
            var secondOffset = 0

            while firstOffset < orderedExisting.count, secondOffset < orderedCandidates.count {
                let existingIndex = orderedExisting[firstOffset]
                let candidateIndex = orderedCandidates[secondOffset]
                let delta = candidates[candidateIndex].createdAt.timeIntervalSince(
                    existing[existingIndex].createdAt
                )

                if abs(delta) <= timestampWindow {
                    matches.insert(candidateIndex)
                    firstOffset += 1
                    secondOffset += 1
                } else if delta > 0 {
                    firstOffset += 1
                } else {
                    secondOffset += 1
                }
            }
        }
        return matches
    }

    private static func removingAdjacentDuplicates(_ messages: [Message]) -> [Message] {
        var result: [Message] = []
        for message in messages {
            if let previous = result.last,
               previous.id == message.id,
               identity(for: previous) == identity(for: message),
               abs(message.createdAt.timeIntervalSince(previous.createdAt)) <= sameSourceTimestampWindow {
                continue
            }
            result.append(message)
        }
        return result
    }

    private static func sorted(_ messages: [Message]) -> [Message] {
        messages.enumerated().sorted {
            if $0.element.createdAt == $1.element.createdAt {
                return $0.offset < $1.offset
            }
            return $0.element.createdAt < $1.element.createdAt
        }.map(\.element)
    }

    private static func identity(for message: Message) -> Identity {
        Identity(
            origin: message.origin.rawValue,
            content: message.content.map(identity(for:))
        )
    }

    static func hasSameContent(_ first: Message, _ second: Message) -> Bool {
        identity(for: first) == identity(for: second)
    }

    private static func identity(for block: ContentBlock) -> ContentIdentity {
        guard case .image(let attachment) = block else { return .value(block) }

        let digest: String
        switch attachment.payload {
        case .inline(let data, _):
            digest = BlobStore.contentID(for: data)
        case .blob(let reference):
            digest = reference.blobID.lowercased()
        }
        return .image(mediaType: attachment.mediaType.lowercased(), sha256: digest)
    }
}
