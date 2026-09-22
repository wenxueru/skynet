import Foundation

/// Observes the relay's connection state, drives automatic reconnection with
/// exponential backoff, and exposes a signal other components (queue flush,
/// banners) can subscribe to.
@MainActor
@Observable
public final class ConnectionMonitorModel {
    public private(set) var state: ConnectionState = .initial
    /// 1-based count of reconnect attempts since the last connected state.
    public private(set) var reconnectAttempt = 0

    private let relay: any SkynetRelay
    private let policy: ReconnectPolicy
    private let sleeper: any DurationSleeper

    private var observerTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Bumped to invalidate in-flight reconnect loops.
    private var reconnectGeneration = 0
    private let connectedChannel = EventChannel<Bool>(replaysLastValue: true)

    public init(
        relay: any SkynetRelay,
        policy: ReconnectPolicy = ReconnectPolicy(),
        sleeper: (any DurationSleeper)? = nil
    ) {
        self.relay = relay
        self.policy = policy
        self.sleeper = sleeper ?? ClockSleeper()
    }

    /// Starts observing the relay. Safe to call repeatedly.
    public func start() {
        guard observerTask == nil else { return }
        observerTask = Task { [weak self] in
            guard let self else { return }
            for await newState in self.relay.connectionEvents() {
                self.apply(newState)
            }
        }
    }

    /// Stops observing and cancels any in-flight reconnection. Call before
    /// discarding the monitor; `deinit` cannot touch actor-isolated state.
    public func stop() {
        observerTask?.cancel()
        observerTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// User-visible "try now" button.
    public func reconnectNow() async {
        reconnectAttempt = 0
        await relay.reconnect()
    }

    /// Fires (and replays) the current connected flag; used to trigger queue
    /// flushes as soon as the link returns.
    public func connectedEvents() -> AsyncStream<Bool> {
        connectedChannel.stream()
    }

    // MARK: - Private

    private func apply(_ newState: ConnectionState) {
        state = newState
        connectedChannel.send(newState.isConnected)
        switch newState {
        case .connected:
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
        case .connecting:
            break
        case .disconnected:
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        reconnectGeneration += 1
        let generation = reconnectGeneration
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.reconnectAttempt += 1
                let delay = self.policy.delay(afterAttempt: self.reconnectAttempt)
                await self.sleeper.sleep(for: delay)
                guard !Task.isCancelled, generation == self.reconnectGeneration else { return }
                await self.relay.reconnect()
                // Reconnect either pushes a new state (which cancels us via
                // apply) or leaves us disconnected; wait a beat and retry.
                await Task.yield()
                if self.state.isConnected { return }
            }
        }
    }
}
