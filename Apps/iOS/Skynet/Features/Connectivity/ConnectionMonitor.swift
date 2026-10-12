import SkynetMobile
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
    private var isManualReconnectInProgress = false
    private var hasObservedConnection = false
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
                guard !Task.isCancelled else { break }
                self.apply(newState)
            }
        }
    }

    /// Stops observing and cancels any in-flight reconnection. Call before
    /// discarding the monitor; `deinit` cannot touch actor-isolated state.
    public func stop() {
        observerTask?.cancel()
        observerTask = nil
        _ = cancelReconnect()
    }

    /// User-visible "try now" button.
    public func reconnectNow() async {
        guard !isManualReconnectInProgress else { return }
        isManualReconnectInProgress = true
        defer { isManualReconnectInProgress = false }
        let previous = cancelReconnect()
        let generation = reconnectGeneration
        // Drain the canceled attempt before starting another authenticated connection.
        await previous?.value
        guard !Task.isCancelled, generation == reconnectGeneration else { return }
        reconnectAttempt = 0
        let task = Task { await relay.reconnect() }
        reconnectTask = task
        await task.value
        guard generation == reconnectGeneration else { return }
        reconnectTask = nil
        isManualReconnectInProgress = false
        if !state.isConnected, observerTask != nil { scheduleReconnect() }
    }

    /// Fires (and replays) the current connected flag; used to trigger queue
    /// flushes as soon as the link returns.
    public func connectedEvents() -> AsyncStream<Bool> {
        connectedChannel.stream()
    }

    // MARK: - Private

    private func apply(_ newState: ConnectionState) {
        let connectivityChanged = state.isConnected != newState.isConnected
        state = newState
        // Successful RPCs also report .connected. Only a real transition
        // triggers reloads, otherwise a library refresh would trigger itself.
        if !hasObservedConnection || connectivityChanged {
            connectedChannel.send(newState.isConnected)
        }
        hasObservedConnection = true
        switch newState {
        case .connected:
            reconnectAttempt = 0
            _ = cancelReconnect()
        case .connecting:
            break
        case .disconnected:
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, !isManualReconnectInProgress else { return }
        reconnectGeneration += 1
        let generation = reconnectGeneration
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.reconnectGeneration { self.reconnectTask = nil }
            }
            while !Task.isCancelled {
                self.reconnectAttempt += 1
                let delay = self.policy.delay(afterAttempt: self.reconnectAttempt)
                await self.sleeper.sleep(for: delay)
                guard !Task.isCancelled, generation == self.reconnectGeneration else { return }
                await self.relay.reconnect()
                guard !Task.isCancelled, generation == self.reconnectGeneration else { return }
                // Reconnect either pushes a new state (which cancels us via
                // apply) or leaves us disconnected; wait a beat and retry.
                await Task.yield()
                if self.state.isConnected { return }
            }
        }
    }

    private func cancelReconnect() -> Task<Void, Never>? {
        reconnectGeneration += 1
        let previous = reconnectTask
        previous?.cancel()
        reconnectTask = nil
        return previous
    }
}
