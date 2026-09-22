import Foundation

/// A lock-protected multi-subscriber broadcast channel backed by
/// `AsyncStream`.
///
/// `AsyncStream` alone supports a single consumer; relay implementations need
/// several (connection banner, monitor, session views). `EventChannel` fans
/// every value out to all live subscribers and can buffer values that arrive
/// while nobody is listening, so late subscribers never miss events.
public final class EventChannel<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let replaysLastValue: Bool
    /// When true, values sent with no live subscriber are buffered and
    /// delivered to the next subscriber.
    private let buffersWhenIdle: Bool
    private var idleBuffer: [Element] = []
    private var lastValue: Element?
    private var finished = false

    /// - Parameters:
    ///   - replaysLastValue: New subscribers immediately receive the most
    ///     recently sent value. Useful for state-like streams (connection).
    ///   - buffersWhenIdle: Values sent while no subscriber is attached are
    ///     buffered and delivered to the next subscriber. Useful for
    ///     event-like streams (session transcripts) so no event is lost
    ///     between subscriptions.
    public init(replaysLastValue: Bool = false, buffersWhenIdle: Bool = false) {
        self.replaysLastValue = replaysLastValue
        self.buffersWhenIdle = buffersWhenIdle
    }

    /// A stream that receives values from now on, plus the replay/buffered
    /// values configured at init. Finishing the channel finishes the stream.
    ///
    /// The `AsyncStream` build closure runs synchronously at creation, so
    /// registration and backlog delivery are atomic with respect to `send`.
    public func stream() -> AsyncStream<Element> {
        stream(prefix: [])
    }

    /// Like `stream()`, but each new subscriber first receives `prefix`
    /// (e.g. a snapshot event) before any live values. Delivery of the
    /// prefix is atomic with respect to concurrent `send` calls.
    public func stream(prefix: [Element]) -> AsyncStream<Element> {
        let id = UUID()
        return AsyncStream { continuation in
            var channelAlreadyFinished = false
            self.lock.withLock {
                if self.finished {
                    channelAlreadyFinished = true
                    return
                }
                self.continuations[id] = continuation
                for value in prefix {
                    continuation.yield(value)
                }
                if self.replaysLastValue, let lastValue = self.lastValue {
                    continuation.yield(lastValue)
                }
                for value in self.idleBuffer {
                    continuation.yield(value)
                }
                self.idleBuffer = []
            }
            if channelAlreadyFinished {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    self.continuations[id] = nil
                }
            }
        }
    }

    /// Sends a value to every live subscriber, or buffers it when idle and
    /// buffering is enabled.
    public func send(_ value: Element) {
        let targets: [AsyncStream<Element>.Continuation] = lock.withLock {
            lastValue = value
            if continuations.isEmpty {
                if buffersWhenIdle, !finished {
                    idleBuffer.append(value)
                }
                return []
            }
            return Array(continuations.values)
        }
        for continuation in targets {
            continuation.yield(value)
        }
    }

    /// Marks the channel complete; subscribers' streams finish.
    public func finish() {
        let targets: [AsyncStream<Element>.Continuation] = lock.withLock {
            finished = true
            let targets = Array(continuations.values)
            continuations.removeAll()
            idleBuffer.removeAll()
            return targets
        }
        for continuation in targets {
            continuation.finish()
        }
    }
}
