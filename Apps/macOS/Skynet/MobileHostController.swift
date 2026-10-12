import AppKit
import Darwin
import Foundation
import ImageIO
import Observation
import SkynetCore
import SkynetMobile

/// Adapts authenticated mobile requests to existing application operations.
/// Sharing is opt-in and restricted to projects selected on the Mac.
@MainActor
@Observable
final class MobileHostController {
    private struct Credentials: Codable {
        var key: Data
        var devices: [String: String] = [:]
    }

    private struct Invitation {
        var token: String
        var code: String
        var expiresAt: Date
        var attempts = 0
    }

    private struct LiveReply {
        var id = SkynetMobile.TranscriptItemID(UUID().uuidString)
        var text = ""
        var date = Date()
    }

    private(set) var isEnabled = false
    private(set) var isWorking = false
    private(set) var pairingCode = ""
    private(set) var verificationCode = ""
    private(set) var error: String?
    private(set) var deviceCount = 0
    private(set) var port: UInt16?
    private(set) var invitationExpiresAt: Date?
    var address = MobileHostController.localAddress() ?? "" {
        didSet {
            clearInvitation()
        }
    }
    var sharedProjectIDs: Set<String> {
        didSet { defaults.set(Array(sharedProjectIDs), forKey: "mobileSharedProjects") }
    }

    private weak var model: AppModel?
    private let keychain: any PairedMachineStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private let loopbackOnly: Bool
    private let hostID = SkynetMobile.MachineID("mobile-host-secret")
    private let machineID: SkynetMobile.MachineID
    private var credentials: Credentials?
    private var credentialRevision = UUID()
    private var persistenceTail: Task<Void, Error>?
    private var invitation: Invitation?
    private var listener: MobileRelayListener?
    private var generation = UUID()
    private var liveReplies: [SkynetCore.SessionID: LiveReply] = [:]
    private var dispatchLedger: MobileDispatchLedger

    init(model: AppModel, defaults: UserDefaults = .standard,
         credentialStore: any PairedMachineStore = KeychainPairedMachineStore(service: "com.skynetresearch.skynet.mobile-host"),
         now: @escaping () -> Date = Date.init, loopbackOnly: Bool = false) {
        self.model = model
        self.defaults = defaults
        keychain = credentialStore
        self.now = now
        self.loopbackOnly = loopbackOnly
        dispatchLedger = MobileDispatchLedger(url: model.storageDirectoryURL?.appendingPathComponent("mobile-dispatches.json"))
        sharedProjectIDs = Set(defaults.stringArray(forKey: "mobileSharedProjects") ?? [])
        let savedID = defaults.string(forKey: "mobileMachineID")
        let id = savedID.flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
        defaults.set(id, forKey: "mobileMachineID")
        machineID = SkynetMobile.MachineID(id)
    }

    func restoreIfEnabled() {
        if defaults.bool(forKey: "mobileRelayEnabled"), !isEnabled, !isWorking { enable() }
    }

    func enable() {
        guard !isWorking, !isEnabled, listener == nil else { return }
        isWorking = true
        error = nil
        let current = UUID()
        generation = current
        Task {
            do {
                // Retry the in-memory intended grants after a persistence failure,
                // never reload a stale pre-revocation grant set from Keychain.
                _ = try? await persistenceTail?.value
                guard generation == current else { return }
                let loaded: Credentials
                if let cached = credentials {
                    loaded = cached
                } else if let saved = try await keychain.credential(for: hostID),
                   let bytes = Data(base64Encoded: saved.accessToken) {
                    loaded = try JSONDecoder().decode(Credentials.self, from: bytes)
                } else { loaded = Credentials(key: try MobileRelaySecret.randomKey()) }
                guard loaded.key.count == 32, loaded.devices.count <= 8,
                      loaded.devices.allSatisfy({ UUID(uuidString: $0.key) != nil && Data(base64Encoded: $0.value)?.count == 32 }) else {
                    throw CocoaError(.coderInvalidValue)
                }
                guard generation == current else { return }
                try await commitCredentials(loaded).task.value
                guard generation == current else { return }
                deviceCount = credentials?.devices.count ?? 0
                let savedPort = UInt16(exactly: defaults.integer(forKey: "mobileRelayPort")) ?? 0
                let server = try MobileRelayListener(key: loaded.key, port: savedPort, loopbackOnly: loopbackOnly, handler: { [weak self] request in
                    guard let self else { return .unauthorized("Mobile access is disabled.") }
                    return await self.handle(request, generation: current)
                }, state: { [weak self] port, error in
                    Task { @MainActor in
                        guard let self, self.generation == current else { return }
                        if let error { self.error = error; self.disable(); return }
                        self.port = port
                        self.isEnabled = port != nil
                        self.isWorking = false
                        self.defaults.set(self.isEnabled, forKey: "mobileRelayEnabled")
                        if let port {
                            self.defaults.set(Int(port), forKey: "mobileRelayPort")
                            self.generateInvitation()
                        }
                    }
                })
                listener = server
                server.start()
            } catch {
                guard generation == current else { return }
                self.error = "Could not enable mobile access: \(error.localizedDescription)"
                self.isWorking = false
            }
        }
    }

    func disable() {
        generation = UUID()
        listener?.stop()
        listener = nil
        clearInvitation()
        port = nil
        isEnabled = false
        isWorking = false
        defaults.set(false, forKey: "mobileRelayEnabled")
    }

    private func clearInvitation() {
        invitation = nil
        invitationExpiresAt = nil
        pairingCode = ""
        verificationCode = ""
    }

    func generateInvitation() {
        guard isEnabled, let credentials else { return }
        guard let endpoint else {
            error = "Enter a valid Mac IP address or host name before generating an invitation."
            return
        }
        do {
            let token = try MobileRelaySecret.randomToken()
            let invite = Invitation(token: token, code: String(Int.random(in: 100000...999999)),
                                    expiresAt: now().addingTimeInterval(180))
            invitation = invite
            invitationExpiresAt = invite.expiresAt
            verificationCode = invite.code
            pairingCode = PairingCodeCodec().encode(PairingOffer(
                relayEndpoint: endpoint, machineName: machine.displayName,
                token: credentials.key.base64EncodedString() + "." + token, expiresAt: invite.expiresAt
            ))
            error = nil
        } catch { self.error = "Could not generate a pairing invitation." }
    }

    func revokeDevices() {
        guard var updated = credentials else { return }
        do { try rememberRevocation(Set(updated.devices.keys)) }
        catch {
            self.error = error.localizedDescription
            return
        }
        updated.devices.removeAll()
        // Invalidate the in-memory grants before awaiting Keychain I/O.
        let persistence = commitCredentials(updated)
        clearInvitation()
        deviceCount = 0
        // Close existing authenticated requests as well as removing future grants.
        disable()
        Task {
            do { try await persistence.task.value }
            catch { self.error = "Could not persist device revocation. Keep mobile access disabled."; disable() }
        }
    }

    private var endpoint: URL? {
        guard let port, !address.isEmpty, address.count <= 253,
              address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !address.contains("/"), !address.contains("\\"), !address.contains("@") else { return nil }
        var value = URLComponents()
        value.scheme = "skynet-relay"
        value.host = address
        value.port = Int(port)
        return value.url
    }

    private var machine: SkynetMobile.Machine {
        .init(id: machineID, displayName: String((Host.current().localizedName ?? "Mac").prefix(128)),
              osVersion: ProcessInfo.processInfo.operatingSystemVersionString, status: .online,
              lastSeenAt: now())
    }

    private func persist(_ value: Credentials) async throws {
        let bytes = try JSONEncoder().encode(value)
        try await keychain.saveCredential(MachineCredential(
            relayEndpoint: URL(string: "skynet-relay://localhost")!, accessToken: bytes.base64EncodedString()
        ), for: hostID)
    }

    private var revokedDeviceIDs: Set<String> {
        Set(defaults.stringArray(forKey: "mobileRevokedDevices") ?? [])
    }

    /// Persist nonsecret device identities before awaiting Keychain. If a write
    /// fails or the app exits, a later enable still filters those stale grants.
    private func rememberRevocation(_ ids: Set<String>) throws {
        defaults.set(Array(revokedDeviceIDs.union(ids)), forKey: "mobileRevokedDevices")
        guard defaults.synchronize() else {
            disable()
            throw rejected("Could not persist device revocation. Keep mobile access disabled.")
        }
    }

    /// Mutate grants before suspension, and queue every Keychain write in the
    /// same order. A stale confirmation can neither restore nor return a revoked grant.
    private func commitCredentials(_ value: Credentials) -> (revision: UUID, task: Task<Void, Error>) {
        var updated = value
        for id in revokedDeviceIDs { updated.devices[id] = nil }
        credentials = updated
        let revision = UUID()
        credentialRevision = revision
        let previous = persistenceTail
        let task = Task {
            _ = try? await previous?.value
            try await persist(updated)
            // Never clear a newer revocation marker from an older write.
            if credentialRevision == revision {
                defaults.removeObject(forKey: "mobileRevokedDevices")
                // A leftover marker is safe; the authoritative grants above
                // have already been durably removed from Keychain.
                _ = defaults.synchronize()
            }
        }
        persistenceTail = task
        return (revision, task)
    }

    private func handle(_ request: MobileRelayRequest, generation current: UUID) async -> MobileRelayReply {
        guard isEnabled, generation == current, !Task.isCancelled else { return .unauthorized("Mobile access is disabled.") }
        do {
            switch request.command {
            case .beginPairing, .confirmPairing:
                guard var invite = invitation, invite.expiresAt > now(), invite.attempts < 5,
                      ConstantTimeComparison.equal(invite.token, request.credential) else {
                    return .failure("Pairing invitation expired. Generate a new code on your Mac.")
                }
                if case .beginPairing = request.command { return .machine(machine) }
                guard case .confirmPairing(let code) = request.command else { throw CocoaError(.coderInvalidValue) }
                invite.attempts += 1
                invitation = invite
                guard ConstantTimeComparison.equal(code, invite.code) else {
                    return .failure("Verification code does not match. Check the code on your Mac.")
                }
                guard var updated = credentials, let endpoint, updated.devices.count < 8 else {
                    return .failure("Revoke an existing device before pairing another one.")
                }
                let token = try MobileRelaySecret.randomToken()
                updated.devices[UUID().uuidString] = token
                // Consume before suspending; concurrent confirms cannot reuse this invitation.
                clearInvitation()
                let persistence = commitCredentials(updated)
                do { try await persistence.task.value }
                catch { disable(); throw error }
                guard isEnabled, generation == current, credentialRevision == persistence.revision,
                      !Task.isCancelled else { return .failure("Pairing was canceled. Generate a new invitation.") }
                deviceCount = updated.devices.count
                return .paired(PairingResult(machine: machine, credential: MachineCredential(
                    relayEndpoint: endpoint, accessToken: updated.key.base64EncodedString() + "." + token, issuedAt: now()
                )))
            default: break
            }

            guard let values = credentials,
                  let device = values.devices.first(where: { ConstantTimeComparison.equal($0.value, request.credential) })?.key,
                  let model else { return .unauthorized("Device is not authorized. Pair again.") }
            if case .unpair = request.command {
                var updated = values
                try rememberRevocation([device])
                updated.devices[device] = nil
                let persistence = commitCredentials(updated)
                deviceCount = updated.devices.count
                do { try await persistence.task.value }
                catch { disable(); throw error }
                return .ok
            }
            try Task.checkCancellation()
            let reply = try await execute(request.command, model: model)
            guard isEnabled, generation == current, !Task.isCancelled,
                  let token = credentials?.devices[device],
                  ConstantTimeComparison.equal(token, request.credential) else {
                return .unauthorized("Device is no longer authorized. Pair again.")
            }
            return reply
        } catch is CancellationError { return .failure("Request canceled.") }
        catch { return .failure(error.localizedDescription) }
    }

    private func execute(_ command: MobileRelayCommand, model: AppModel) async throws -> MobileRelayReply {
        switch command {
        case .ping: return .machine(machine)
        case .projects:
            return .projects(model.projects.filter { sharedProjectIDs.contains($0.id.description) }.map {
                SkynetMobile.Project(id: .init($0.id.description), machineID: machineID, name: $0.name,
                                     displayPath: $0.rootPath ?? "", lastActivityAt: $0.updatedAt)
            })
        case .sessions(let id):
            let project = try project(id, model: model)
            return .sessions(model.sessions(for: project).filter { $0.isArchived != true }.map(session))
        case .createSession(let id, let configuration):
            let project = try project(id, model: model)
            let settings = try configurationValues(configuration, model: model)
            var record = SkynetCore.SessionRecord(projectID: project.id, providerID: settings.provider,
                                                  backendID: model.mobileBackendID(for: project), workingDirectory: project.rootPath)
            apply(configuration, settings: settings, to: &record)
            try model.mobileSave(record)
            return .session(session(record))
        case .configure(let id, let configuration):
            var record = try record(id, model: model)
            guard record.status != .running, model.mobileActiveSessionID != record.id,
                  model.scheduledDispatchingSessionID != record.id else { throw busy() }
            let settings = try configurationValues(configuration, model: model)
            guard record.providerID == settings.provider else { throw rejected("A session's provider cannot be changed.") }
            apply(configuration, settings: settings, to: &record)
            try model.mobileSave(record)
            return .ok
        case .rename(let id, let name):
            var record = try record(id, model: model)
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 200 else { throw rejected("Enter a title of 1–200 characters.") }
            if record.providerID == .codex, let token = record.providerResumeToken {
                let provider = model.providers.first { $0.id == .codex }
                try await CodexThreadName.setName(title, threadID: token, backend: model.executionBackend(for: record),
                                                 executable: provider?.resolvedExecutableName ?? "codex",
                                                 environment: provider?.environment ?? [:])
                try Task.checkCancellation()
                record = try self.record(id, model: model)
            }
            record.title = title
            record.updatedAt = Date()
            try model.mobileSave(record)
            return .ok
        case .delete(let id):
            let record = try record(id, model: model)
            guard record.status != .running, model.mobileActiveSessionID != record.id else { throw busy() }
            let removed = await model.deleteSessions([record.id])
            guard removed.contains(record.id) else { throw rejected("Could not delete this session on the Mac.") }
            return .ok
        case .models:
            var result: [SkynetMobile.AgentModel] = []
            for provider in model.providers {
                let catalog = await ProviderModelDiscovery.models(for: provider, backend: LocalProcessBackend(), workingDirectory: nil)
                try Task.checkCancellation()
                result.append(contentsOf: catalog.models.map {
                    SkynetMobile.AgentModel(id: provider.id.description + "|" + $0.id.description,
                                             displayName: $0.displayName, summary: provider.displayName,
                                             supportsEffort: !$0.supportedEfforts.isEmpty)
                })
            }
            return .models(result)
        case .snapshot(let id):
            let record = try record(id, model: model)
            let messages = try await model.mobileMessages(for: record.id)
            try Task.checkCancellation()
            _ = try self.record(id, model: model)
            var items = MobileSessionProjection.transcript(messages, imageData: model.imageData(for:))
            if let live = liveReplies[record.id], !live.text.isEmpty {
                items.append(.assistantMessage(.init(id: live.id, text: live.text,
                                                      isStreaming: true, sentAt: live.date)))
            }
            if let pending = model.mobilePermission, pending.owner == record.id {
                let identity = pending.token.uuidString + ":" + pending.request.id
                items.append(.permissionRequest(.init(id: .init(identity), summary: pending.request.summary,
                                                     detail: pending.request.primaryArgument, scope: .other,
                                                     requestedAt: Date(timeIntervalSince1970: 0))))
            }
            let state = session(try self.record(id, model: model))
            let notice = SkynetMobile.TranscriptItem.systemNotice(.init(
                id: .init("mobile-history-limit"), text: "Older history is omitted from this mobile snapshot. View the full transcript on the Mac.",
                date: items.first?.timestamp ?? record.createdAt
            ))
            var clipped = false
            while try JSONEncoder().encode(MobileRelayReply.snapshot(.init(session: state, items: items))).count
                > MobileRelayConnection.maximumFrameSize - 1024, items.count > 1 {
                items.removeFirst(max(1, items.count / 4))
                clipped = true
            }
            if clipped { items.insert(notice, at: 0) }
            return .snapshot(.init(session: state, items: items))
        case .send(let id, let payload):
            let record = try record(id, model: model)
            guard !payload.isEffectivelyEmpty, payload.text.utf8.count <= 256 * 1024,
                  payload.attachments.count <= 8,
                  payload.attachments.reduce(0, { $0 + $1.data.count }) <= 5 * 1024 * 1024 else {
                throw rejected("The message is empty or too large. Send smaller attachments.")
            }
            let dispatch = payload.dispatchID.uuidString
            let digest = try MobileDispatchLedger.digest(payload)
            if try dispatchLedger.wasAccepted(dispatch, sessionID: record.id.description, digest: digest) {
                return .ok
            }
            guard !model.isRunning, record.status != .running,
                  model.scheduledDispatchingSessionID != record.id else { throw busy() }
            let url = try dispatchLedger.writableURL(receiptsURL)
            let attachments = try payload.attachments.map { image -> SkynetCore.ImageAttachment in
                guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 40000, height <= 40000,
                      width <= 40_000_000 / height else {
                    throw rejected("An attachment is invalid or exceeds 40 megapixels. Resize it before sending.")
                }
                // Use the same byte-based format validation as the Mac composer.
                return try ComposerImageImport.load(data: image.data, suggestedFileName: image.fileName)
            }
            try dispatchLedger.persist(.pending, dispatch: dispatch, sessionID: record.id.description, digest: digest, to: url)
            try model.mobileSend(payload.text, attachments: attachments, record: record)
            try dispatchLedger.persist(.accepted, dispatch: dispatch, sessionID: record.id.description, digest: digest, to: url)
            return .ok
        case .cancel(let id):
            try model.mobileCancel(sessionID: record(id, model: model).id)
            return .ok
        case .permission(let id, let requestID, let decision):
            guard decision != .approvedAlways else {
                throw rejected("Persistent permission grants must be changed on the Mac. Choose Allow Once instead.")
            }
            let record = try record(id, model: model)
            let parts = requestID.rawValue.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let token = UUID(uuidString: String(parts[0])) else {
                throw rejected("This approval request is no longer active.")
            }
            try model.mobileAnswerPermission(sessionID: record.id, token: token, requestID: String(parts[1]),
                                            decision: decision == .denied ? .deny : .allow)
            return .ok
        case .beginPairing, .confirmPairing, .unpair:
            throw rejected("Unauthorized pairing operation.")
        }
    }

    private func project(_ id: SkynetMobile.ProjectID, model: AppModel) throws -> SkynetCore.Project {
        guard sharedProjectIDs.contains(id.rawValue),
              let project = model.projects.first(where: { $0.id.description == id.rawValue }) else {
            throw rejected("This project is not shared with mobile devices.")
        }
        return project
    }

    private func record(_ id: SkynetMobile.SessionID, model: AppModel) throws -> SkynetCore.SessionRecord {
        guard let record = model.sessions.first(where: { $0.id.description == id.rawValue }),
              record.isArchived != true, let projectID = record.projectID else { throw rejected("Session is unavailable.") }
        _ = try project(.init(projectID.description), model: model)
        return record
    }

    private func session(_ record: SkynetCore.SessionRecord) -> SkynetMobile.AgentSession {
        let state: SkynetMobile.TurnState
        if model?.mobilePermission?.owner == record.id {
            state = .awaitingPermission
        } else if model?.mobileActiveSessionID == record.id || record.status == .running {
            state = .running
        } else if record.status == .failed {
            state = .failed
        } else {
            state = .idle
        }
        return MobileSessionProjection.session(record, state: state)
    }

    private func configurationValues(_ value: SkynetMobile.AgentConfiguration, model: AppModel)
        throws -> (provider: SkynetCore.ProviderID, model: SkynetCore.ModelID?) {
        guard value.permissions == .askForEverything else {
            throw rejected("Mobile session configuration supports Ask Always only. Change other permission modes on the Mac.")
        }
        if value.model.id == SkynetMobile.AgentModel.balanced.id {
            guard let provider = model.providers.first(where: { $0.id == .codex }) ?? model.providers.first else {
                throw rejected("Provider is unavailable.")
            }
            return (provider.id, nil)
        }
        let parts = value.model.id.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else { throw rejected("Select a model offered by this Mac.") }
        let provider = SkynetCore.ProviderID(String(parts[0]))
        guard model.providers.contains(where: { $0.id == provider }) else { throw rejected("Provider is unavailable.") }
        let modelID = parts[1] != "default" ? SkynetCore.ModelID(String(parts[1])) : nil
        return (provider, modelID)
    }

    private func apply(_ value: SkynetMobile.AgentConfiguration,
                       settings: (provider: SkynetCore.ProviderID, model: SkynetCore.ModelID?),
                       to record: inout SkynetCore.SessionRecord) {
        record.modelID = settings.model
        switch value.effort {
        case .minimal: record.effort = .low
        case .standard: record.effort = .medium
        case .thorough: record.effort = .high
        case .exhaustive: record.effort = .xhigh
        }
        record.permissionEffect = .ask
        record.codexApprovalMode = .manual
        record.claudePermissionMode = .manual
        // Escalating agent permissions is intentionally a Mac-side action.
        record.updatedAt = Date()
    }

    func receive(_ event: SkynetCore.AgentEvent, for id: SkynetCore.SessionID) {
        guard isEnabled else { return }
        switch event {
        case .turnStarted: liveReplies[id] = LiveReply()
        case .textDelta(let text):
            if liveReplies[id] == nil { liveReplies[id] = LiveReply() }
            liveReplies[id]?.text += text
            if let text = liveReplies[id]?.text, text.count > 64000 { liveReplies[id]?.text = String(text.suffix(64000)) }
        case .messageCompleted(let message) where message.origin == .agent:
            liveReplies[id] = LiveReply()
        case .turnFailed, .turnCompleted: liveReplies[id] = nil
        default: break
        }
    }

    func finishTurn(for id: SkynetCore.SessionID) { liveReplies[id] = nil }

    private var receiptsURL: URL? { model?.storageDirectoryURL?.appendingPathComponent("mobile-dispatches.json") }
    private func rejected(_ message: String) -> SkynetMobile.SkynetError { .relayRejected(message) }
    private func busy() -> SkynetMobile.SkynetError { rejected("A turn is running. Wait for it to finish.") }

    private static func localAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var item = interfaces
        while let interface = item {
            defer { item = interface.pointee.ifa_next }
            guard let socket = interface.pointee.ifa_addr,
                  interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.pointee.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  socket.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.pointee.ifa_name).hasPrefix("en") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(socket, socklen_t(socket.pointee.sa_len), &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 { return String(cString: hostname) }
        }
        return nil
    }
}
