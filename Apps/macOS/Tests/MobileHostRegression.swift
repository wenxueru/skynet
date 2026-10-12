import Darwin
import Foundation
import SkynetCore
import SkynetMobile

/// Synthetic application boundary: no native history, provider subprocesses,
/// shared user defaults or system credentials are touched by this fixture.
@MainActor
final class AppModel {
    var projects: [SkynetCore.Project]
    var sessions: [SkynetCore.SessionRecord]
    var providers: [AgentProviderDescriptor] = []
    let storageDirectoryURL: URL?
    var mobileActiveSessionID: SkynetCore.SessionID?
    var scheduledDispatchingSessionID: SkynetCore.SessionID?
    var mobilePermission: (request: PermissionRequest, token: UUID, owner: SkynetCore.SessionID)?
    var isRunning = false
    var sendEffects = 0
    var throwAfterSend = false
    var permissionAnswers: [PermissionResponse.Decision] = []
    var cancellations: [SkynetCore.SessionID] = []

    init(directory: URL, projects: [SkynetCore.Project], sessions: [SkynetCore.SessionRecord]) {
        storageDirectoryURL = directory
        self.projects = projects
        self.sessions = sessions
    }
    func sessions(for project: SkynetCore.Project) -> [SkynetCore.SessionRecord] {
        sessions.filter { $0.projectID == project.id }
    }
    func mobileBackendID(for project: SkynetCore.Project) -> BackendID { BackendID("synthetic-backend") }
    func executionBackend(for record: SkynetCore.SessionRecord) -> any ExecutionBackend {
        fatalError("Fixture must never execute a native provider operation.")
    }
    func mobileSave(_ record: SkynetCore.SessionRecord) throws {
        sessions.removeAll { $0.id == record.id }
        sessions.append(record)
    }
    func mobileMessages(for id: SkynetCore.SessionID) async throws -> [Message] { [] }
    func imageData(for image: SkynetCore.ImageAttachment) -> Data? { nil }
    func deleteSessions(_ ids: Set<SkynetCore.SessionID>) async -> Set<SkynetCore.SessionID> {
        sessions.removeAll { ids.contains($0.id) }
        return ids
    }
    func mobileSend(_ prompt: String, attachments: [SkynetCore.ImageAttachment], record: SkynetCore.SessionRecord) throws {
        guard providers.contains(where: { $0.id == record.providerID }) else {
            throw FixtureFailure.failed("Synthetic session provider is unavailable.")
        }
        sendEffects += 1
        mobileActiveSessionID = record.id
        isRunning = true
        if throwAfterSend { throw FixtureFailure.failed("Synthetic post-effect failure.") }
    }
    func mobileCancel(sessionID: SkynetCore.SessionID) throws {
        guard mobileActiveSessionID == sessionID else { throw FixtureFailure.failed("Wrong cancellation owner.") }
        cancellations.append(sessionID)
        mobileActiveSessionID = nil
        isRunning = false
    }
    func mobileAnswerPermission(sessionID: SkynetCore.SessionID, token: UUID, requestID: String,
                               decision: PermissionResponse.Decision) throws {
        guard let pending = mobilePermission, pending.owner == sessionID,
              pending.token == token, pending.request.id == requestID else {
            throw FixtureFailure.failed("Wrong approval owner.")
        }
        permissionAnswers.append(decision)
        mobilePermission = nil
    }
}

enum ComposerImageImport {
    static func load(data: Data, suggestedFileName: String?) throws -> SkynetCore.ImageAttachment {
        throw FixtureFailure.failed("This host-auth fixture must not import images.")
    }
}

/// Only configured synthetic catalog metadata crosses this fixture boundary;
/// discovery must never launch a CLI or inspect a user's provider settings.
enum ProviderModelDiscovery {
    struct Catalog { var models: [SkynetCore.ModelDescriptor] = [] }

    static func models(for provider: AgentProviderDescriptor?, backend: any ExecutionBackend,
                       workingDirectory: String?) async -> Catalog {
        Catalog(models: provider?.models ?? [])
    }
}

enum FixtureFailure: Error { case failed(String) }

/// Simulates failed secure-store writes without ever accessing Keychain.
private final class FaultingCredentialStore: PairedMachineStore, @unchecked Sendable {
    private let memory = InMemoryPairedMachineStore()
    private let lock = NSLock()
    private var writesFail = false

    var failWrites: Bool {
        get { lock.withLock { writesFail } }
        set { lock.withLock { writesFail = newValue } }
    }
    func machines() async throws -> [Machine] { try await memory.machines() }
    func rememberMachine(_ machine: Machine) async throws { try await memory.rememberMachine(machine) }
    func forgetMachine(_ id: MachineID) async throws { try await memory.forgetMachine(id) }
    func credential(for id: MachineID) async throws -> MachineCredential? { try await memory.credential(for: id) }
    func removeCredential(for id: MachineID) async throws { try await memory.removeCredential(for: id) }
    func saveCredential(_ credential: MachineCredential, for id: MachineID) async throws {
        guard !failWrites else { throw FixtureFailure.failed("Synthetic secure-store write failure.") }
        try await memory.saveCredential(credential, for: id)
    }
    func savePairing(machine: Machine, credential: MachineCredential) async throws {
        guard !failWrites else { throw FixtureFailure.failed("Synthetic secure-store write failure.") }
        try await memory.savePairing(machine: machine, credential: credential)
    }
}

@MainActor
private final class FixtureClock {
    var date = Date(timeIntervalSince1970: 2_000_000_000)
}

@main
@MainActor
enum MobileHostRegression {
    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw FixtureFailure.failed(label) }
        print("PASS: \(label)")
    }

    private static func enabled(_ host: MobileHostController) async throws {
        host.enable()
        let deadline = Date().addingTimeInterval(6)
        while !host.isEnabled, host.error == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(host.isEnabled && host.port != nil, "Synthetic loopback host starts")
    }

    private static func rpc(_ offer: PairingOffer, secret: String? = nil,
                            _ command: MobileRelayCommand) async throws -> MobileRelayReply {
        try await MobileRelayConnection.call(endpoint: offer.relayEndpoint, secret: secret ?? offer.token,
                                             command: command, timeout: .seconds(5))
    }

    private static func failsClosed(_ host: MobileHostController) async throws {
        host.enable()
        let deadline = Date().addingTimeInterval(6)
        while host.isWorking, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try require(!host.isWorking && !host.isEnabled && host.error != nil,
                    "Failed secure-store write keeps restarted mobile host disabled")
    }

    private static func pairedToken(_ host: MobileHostController, offer: PairingOffer) async throws -> String {
        guard case .paired(let pairing) = try await rpc(offer, .confirmPairing(code: host.verificationCode)) else {
            throw FixtureFailure.failed("Expected synthetic repair-test pairing.")
        }
        return pairing.credential.accessToken
    }

    private static func rejected(_ label: String, authorization: Bool = false,
                                 _ action: () async throws -> MobileRelayReply) async throws {
        do { _ = try await action() }
        catch SkynetMobile.SkynetError.relayRejected(_) where !authorization { print("PASS: \(label)"); return }
        catch SkynetMobile.SkynetError.authorizationFailed(_) where authorization { print("PASS: \(label)"); return }
        throw FixtureFailure.failed(label)
    }

    static func main() async {
        do { try await run(); print("PASS: Mobile host boundary regression") }
        catch {
            print("FAIL: Mobile host regression: \(error)")
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw FixtureFailure.failed("Expected isolated fixture directory.") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try projectionRegression()
        try ledgerRegression(in: root)
        let suite = "app.skynet.synthetic-mobile-fixture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw FixtureFailure.failed("Could not create fixture defaults.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let shared = SkynetCore.Project(name: "Synthetic Shared", rootPath: "/example/shared")
        let hidden = SkynetCore.Project(name: "Synthetic Hidden", rootPath: "/example/hidden")
        let sharedSession = SkynetCore.SessionRecord(projectID: shared.id, providerID: .codex, title: "Synthetic Shared")
        let hiddenSession = SkynetCore.SessionRecord(projectID: hidden.id, providerID: .codex, title: "Synthetic Hidden")
        let model = AppModel(directory: root, projects: [shared, hidden], sessions: [sharedSession, hiddenSession])
        let credentials = FaultingCredentialStore()
        let clock = FixtureClock()
        var host = MobileHostController(model: model, defaults: defaults, credentialStore: credentials,
                                        now: { clock.date }, loopbackOnly: true)
        host.address = "127.0.0.1"
        host.sharedProjectIDs = [shared.id.description]
        defer { host.disable() }
        try await enabled(host)
        var offer = try PairingCodeCodec().decode(host.pairingCode)

        _ = try await rpc(offer, .beginPairing)
        try await rejected("Incorrect verification digits do not grant access") {
            try await rpc(offer, .confirmPairing(code: "not-six-digits"))
        }
        for _ in 0..<4 {
            try await rejected("Incorrect verification attempts are rejected") {
                try await rpc(offer, .confirmPairing(code: "000000"))
            }
        }
        try await rejected("Five failed verification attempts lock the invitation") {
            try await rpc(offer, .confirmPairing(code: host.verificationCode))
        }
        host.generateInvitation()
        offer = try PairingCodeCodec().decode(host.pairingCode)
        clock.date = clock.date.addingTimeInterval(181)
        try await rejected("Expired pairing invitation is rejected") { try await rpc(offer, .beginPairing) }
        host.generateInvitation()
        offer = try PairingCodeCodec().decode(host.pairingCode)
        let verificationCode = host.verificationCode
        let phoneStore = InMemoryPairedMachineStore()
        let phone = NetworkSkynetRelay(store: phoneStore)
        let phoneOffer = try phone.parseCode(host.pairingCode)
        let handshake = try await phone.beginPairing(with: phoneOffer)
        try require(handshake.verificationCode.isEmpty, "Phone handshake never receives the Mac verification digits")
        let pairing = try await phone.confirm(handshake, enteredCode: verificationCode)
        try await phoneStore.savePairing(machine: pairing.machine, credential: pairing.credential)
        let storedPhoneCredential = try await phoneStore.credential(for: pairing.machine.id)
        try require(storedPhoneCredential == pairing.credential, "Real phone relay pairing persists to isolated memory store")
        let accessToken = pairing.credential.accessToken
        try require(host.deviceCount == 1, "Confirmed pairing persists exactly one device")
        try await rejected("Pairing invitation cannot be reused") {
            try await rpc(offer, .confirmPairing(code: verificationCode))
        }
        let secret = try MobileRelaySecret(accessToken)
        try await rejected("TLS key without valid application token is unauthorized", authorization: true) {
            try await rpc(offer, secret: secret.key.base64EncodedString() + "." + String(repeating: "x", count: 44), .projects)
        }
        let projects = try await phone.projects()
        try require(projects.map(\.id.rawValue) == [shared.id.description], "Project listing exposes only the explicit allowlist")
        let phoneSessions = try await phone.sessions(in: .init(shared.id.description))
        try require(phoneSessions.map(\.id.rawValue) == [sharedSession.id.description],
                    "Real phone relay loads the shared session library")
        try await rejected("Unshared project sessions cannot be listed") {
            try await rpc(offer, secret: accessToken, .sessions(.init(hidden.id.description)))
        }
        try await rejected("Unshared session snapshots cannot be read") {
            try await rpc(offer, secret: accessToken, .snapshot(.init(hiddenSession.id.description)))
        }
        try await rejected("Unshared session cannot start a provider turn") {
            try await rpc(offer, secret: accessToken, .send(.init(hiddenSession.id.description), PromptPayload(text: "Synthetic denied")))
        }
        try require(model.sendEffects == 0, "Rejected access has no send side effect")

        let wrapper = AgentProviderDescriptor(id: SkynetCore.ProviderID("synthetic-wrapper"),
                                              kind: .claudeCodeCompatible, displayName: "Synthetic wrapper",
                                              executable: "synthetic-never-run")
        let codex = AgentProviderDescriptor(id: .codex, kind: .codex, displayName: "Synthetic Codex", models: [
            SkynetCore.ModelDescriptor(id: SkynetCore.ModelID("synthetic-model"), displayName: "Synthetic Model",
                                       supportedEfforts: [.medium]),
        ])
        model.providers = [wrapper, codex]
        let phoneModels = try await phone.availableModels()
        try require(phoneModels.map(\.id) == ["codex|synthetic-model"] && phoneModels.first?.supportsEffort == true,
                    "Real phone relay receives configured synthetic model metadata without CLI discovery")
        var configuration = SkynetMobile.AgentConfiguration.standard
        configuration.permissions = .askForEverything
        guard case .session(let preferred) = try await rpc(offer, secret: accessToken,
            .createSession(.init(shared.id.description), configuration)) else {
            throw FixtureFailure.failed("Expected default-model session creation.")
        }
        try require(preferred.configuration.model.id == "codex|default", "Balanced sentinel selects Codex provider default")
        let created = model.sessions.first { $0.id.description == preferred.id.rawValue }
        try require(created?.permissionEffect == .ask && created?.codexApprovalMode == .manual,
                    "Mobile session creation preserves manual approval policy")
        model.providers = [wrapper]
        guard case .session(let fallback) = try await rpc(offer, secret: accessToken,
            .createSession(.init(shared.id.description), configuration)) else {
            throw FixtureFailure.failed("Expected fallback-provider session creation.")
        }
        try require(fallback.configuration.model.id == "synthetic-wrapper|default", "Balanced sentinel falls back to installed provider")
        configuration.model = .fast
        try await rejected("Unqualified non-default model is rejected") {
            try await rpc(offer, secret: accessToken, .createSession(.init(shared.id.description), configuration))
        }
        model.providers = [codex]
        model.scheduledDispatchingSessionID = sharedSession.id
        model.mobileActiveSessionID = created?.id
        var scheduledConfiguration = SkynetMobile.AgentConfiguration.standard
        scheduledConfiguration.permissions = .askForEverything
        try await rejected("Scheduled target cannot be configured when a different ordinary owner is active") {
            try await rpc(offer, secret: accessToken,
                .configure(.init(sharedSession.id.description), scheduledConfiguration))
        }
        try require(model.sessions.first(where: { $0.id == sharedSession.id })?.effort == nil,
                    "Rejected scheduled configuration preserves its session settings")
        model.scheduledDispatchingSessionID = nil
        model.mobileActiveSessionID = nil

        let approvalToken = UUID()
        let approval = PermissionRequest(id: "synthetic-approval", sessionID: sharedSession.id,
                                         toolName: "synthetic-tool", summary: "Synthetic approval")
        model.mobilePermission = (approval, approvalToken, sharedSession.id)
        guard case .snapshot(let snapshot) = try await rpc(offer, secret: accessToken,
            .snapshot(.init(sharedSession.id.description))),
              let approvalItem = snapshot.items.compactMap({ item -> PermissionRequestRecord? in
                  if case .permissionRequest(let request) = item { return request }
                  return nil
              }).first else { throw FixtureFailure.failed("Missing synthetic pending approval snapshot.") }
        try require(snapshot.session.state == .awaitingPermission && approvalItem.summary == approval.summary,
                    "Snapshot renders pending approval for its owning session")
        try await rejected("Approval cannot target a different shared session") {
            try await rpc(offer, secret: accessToken, .permission(preferred.id, approvalItem.id, .approvedOnce))
        }
        let staleRequest = SkynetMobile.TranscriptItemID(UUID().uuidString + ":" + approval.id)
        try await rejected("Stale approval generation cannot be resolved") {
            try await rpc(offer, secret: accessToken, .permission(.init(sharedSession.id.description), staleRequest, .approvedOnce))
        }
        try await rejected("Permanent permission escalation is denied on mobile") {
            try await rpc(offer, secret: accessToken, .permission(.init(sharedSession.id.description), approvalItem.id, .approvedAlways))
        }
        try require(model.permissionAnswers.isEmpty && model.mobilePermission != nil,
                    "Rejected approvals leave the real pending owner unchanged")
        try await phone.resolvePermission(approvalItem.id, decision: .approvedOnce,
                                          in: .init(sharedSession.id.description))
        try require(model.permissionAnswers == [.allow] && model.mobilePermission == nil,
                    "Allow Once resolves the exact owner and native approval token")
        model.mobilePermission = (approval, approvalToken, sharedSession.id)
        try await phone.resolvePermission(approvalItem.id, decision: .denied,
                                          in: .init(sharedSession.id.description))
        try require(model.permissionAnswers == [.allow, .deny], "Deny maps to native permission denial")

        let prompt = PromptPayload(text: "Synthetic accepted")
        try await phone.sendPrompt(prompt, to: .init(sharedSession.id.description))
        try await phone.sendPrompt(prompt, to: .init(sharedSession.id.description))
        try require(model.sendEffects == 1, "Accepted dispatch retry executes exactly once, even while busy")
        var conflicting = prompt
        conflicting.text = "Changed payload"
        try await rejected("Dispatch identity cannot be reused for different content") {
            try await rpc(offer, secret: accessToken, .send(.init(sharedSession.id.description), conflicting))
        }
        try await rejected("Stop cannot cancel another shared session's turn") {
            try await rpc(offer, secret: accessToken, .cancel(preferred.id))
        }
        try require(model.cancellations.isEmpty && model.mobileActiveSessionID == sharedSession.id,
                    "Rejected Stop preserves the active turn owner")
        try await phone.cancelCurrentTurn(in: .init(sharedSession.id.description))
        try require(model.cancellations == [sharedSession.id] && !model.isRunning,
                    "Stop cancels only the requested active session")

        host.disable()
        host = MobileHostController(model: model, defaults: defaults, credentialStore: credentials,
                                   now: { clock.date }, loopbackOnly: true)
        host.address = "127.0.0.1"
        try await enabled(host)
        offer = try PairingCodeCodec().decode(host.pairingCode)
        _ = try await rpc(offer, secret: accessToken, .send(.init(sharedSession.id.description), prompt))
        try require(model.sendEffects == 1, "Persisted accepted ledger prevents replay after host restart")
        model.isRunning = false
        model.mobileActiveSessionID = nil
        model.throwAfterSend = true
        let uncertain = PromptPayload(text: "Synthetic ambiguous delivery")
        try await rejected("Post-effect failure leaves dispatch pending") {
            try await rpc(offer, secret: accessToken, .send(.init(sharedSession.id.description), uncertain))
        }
        model.isRunning = false
        model.mobileActiveSessionID = nil
        model.throwAfterSend = false
        try await rejected("Uncertain dispatch never repeats the provider side effect") {
            try await rpc(offer, secret: accessToken, .send(.init(sharedSession.id.description), uncertain))
        }
        try require(model.sendEffects == 2, "Ambiguous delivery is held for review rather than resent")

        host.revokeDevices()
        try require(!host.isEnabled && host.deviceCount == 0, "Revocation disables active mobile access")
        try await enabled(host)
        offer = try PairingCodeCodec().decode(host.pairingCode)
        try await rejected("Revoked application credential stays unauthorized after re-enable", authorization: true) {
            try await rpc(offer, secret: accessToken, .ping)
        }
        try await rejected("Real phone relay surfaces revoked authorization distinctly", authorization: true) {
            _ = try await phone.projects()
            return .ok
        }
        try require(model.sendEffects == 2, "Host security regression never performs another send")

        // A failed revocation write intentionally leaves stale grants in the
        // fake secure store. A fresh controller must honor the durable marker.
        let revokeToken = try await pairedToken(host, offer: offer)
        credentials.failWrites = true
        host.revokeDevices()
        try require(!host.isEnabled && !(defaults.stringArray(forKey: "mobileRevokedDevices") ?? []).isEmpty,
                    "Revocation records a durable tombstone before secure-store suspension")
        host = MobileHostController(model: model, defaults: defaults, credentialStore: credentials,
                                   now: { clock.date }, loopbackOnly: true)
        host.address = "127.0.0.1"
        try await failsClosed(host)
        credentials.failWrites = false
        host = MobileHostController(model: model, defaults: defaults, credentialStore: credentials,
                                   now: { clock.date }, loopbackOnly: true)
        host.address = "127.0.0.1"
        try await enabled(host)
        offer = try PairingCodeCodec().decode(host.pairingCode)
        try require(host.deviceCount == 0, "Repaired startup filters revoked grants from stale secure-store data")
        try await rejected("Failed revocation write cannot resurrect grants after restart", authorization: true) {
            try await rpc(offer, secret: revokeToken, .ping)
        }

        let unpairToken = try await pairedToken(host, offer: offer)
        credentials.failWrites = true
        do {
            _ = try await rpc(offer, secret: unpairToken, .unpair)
            throw FixtureFailure.failed("Unpair must report an unsuccessful secure-store write.")
        } catch SkynetMobile.SkynetError.relayRejected(_) { }
        catch SkynetMobile.SkynetError.connectionLost(let reason) {
            try require(!reason.contains("did not respond"), "Failed unpair terminates its connection promptly")
        }
        try require(!host.isEnabled && !(defaults.stringArray(forKey: "mobileRevokedDevices") ?? []).isEmpty,
                    "Failed unpair disables mobile access and retains its tombstone")
        host = MobileHostController(model: model, defaults: defaults, credentialStore: credentials,
                                   now: { clock.date }, loopbackOnly: true)
        host.address = "127.0.0.1"
        try await failsClosed(host)
        credentials.failWrites = false
        host = MobileHostController(model: model, defaults: defaults, credentialStore: credentials,
                                   now: { clock.date }, loopbackOnly: true)
        host.address = "127.0.0.1"
        try await enabled(host)
        offer = try PairingCodeCodec().decode(host.pairingCode)
        try await rejected("Failed unpair write cannot resurrect its device after restart", authorization: true) {
            try await rpc(offer, secret: unpairToken, .ping)
        }
        try require(host.deviceCount == 0 && model.sendEffects == 2,
                    "Persistence-failure regressions preserve revoked state without provider execution")
    }

    private static func projectionRegression() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let call = ToolCall(id: ToolCallID("synthetic-projection-tool"), name: "Synthetic tool")
        let messages = [
            Message(origin: .user, content: [.text("Synthetic prompt")], createdAt: date),
            Message(origin: .agent, content: [.text("Synthetic answer"), .toolCall(call)], createdAt: date),
            Message(origin: .toolResult, content: [
                .toolResult(toolCallID: call.id, content: String(repeating: "x", count: 16001), isError: true)
            ], createdAt: date),
        ]
        let items = MobileSessionProjection.transcript(messages) { _ in nil }
        try require(items.count == 3 && items.map(\.timestamp).allSatisfy { $0 == date },
                    "Transcript projection preserves message order and timestamps")
        guard case .toolCall(let tool) = items.last else { throw FixtureFailure.failed("Missing projected tool.") }
        try require(tool.id.rawValue == call.id.description && tool.title == call.name
                    && tool.state == .failed && tool.output?.count == 16000 && tool.outputTruncated,
                    "Tool result projection updates the matching call with bounded output")

        let data = Data(repeating: 0, count: 256 * 1024)
        let image = SkynetCore.ImageAttachment(data: data, mediaType: "image/png", fileName: "synthetic.png")
        let images = [Message(origin: .user, content: [.text("Images")] + Array(repeating: .image(image), count: 5))]
        var imageReads = 0
        let projectedImages = MobileSessionProjection.transcript(images) { _ in imageReads += 1; return data }
        guard case .userMessage(let user) = projectedImages.first else { throw FixtureFailure.failed("Missing projected images.") }
        try require(user.attachments.count == 4 && imageReads == 4 && user.text.contains("Image omitted"),
                    "Image budget rejects excess bytes before loading another image")

        let history = (0..<201).map { Message(origin: .user, content: [.text(String($0))]) }
        let bounded = MobileSessionProjection.transcript(history) { _ in nil }
        try require(bounded.count == 200 && bounded.first?.searchableText == "1",
                    "Transcript projection keeps the last 200 messages")
        var record = SkynetCore.SessionRecord(providerID: .codex, title: "Synthetic projection")
        record.effort = .ultra
        record.permissionEffect = .allow
        let session = MobileSessionProjection.session(record, state: .awaitingPermission)
        try require(session.state == .awaitingPermission && session.configuration.effort == .exhaustive
                    && session.configuration.permissions == .autonomous,
                    "Session projection preserves caller-owned state and configuration mapping")
    }

    private static func ledgerRegression(in root: URL) throws {
        let url = root.appendingPathComponent("synthetic-ledger.json")
        let dispatch = "synthetic-dispatch"
        let session = "synthetic-session"
        let digest = try MobileDispatchLedger.digest(PromptPayload(text: "Synthetic ledger"))
        var ledger = MobileDispatchLedger(url: url)
        let initiallyAccepted = try ledger.wasAccepted(dispatch, sessionID: session, digest: digest)
        try require(!initiallyAccepted, "New dispatch is not accepted")
        try ledger.persist(.pending, dispatch: dispatch, sessionID: session, digest: digest, to: url)
        do {
            _ = try MobileDispatchLedger(url: url).wasAccepted(dispatch, sessionID: session, digest: digest)
            throw FixtureFailure.failed("Pending dispatch must remain uncertain.")
        } catch SkynetMobile.SkynetError.relayRejected {
            try require(true, "Pending receipt survives ledger recreation without becoming a send permission")
        }
        do {
            try ledger.persist(.accepted, dispatch: dispatch, sessionID: session, digest: digest,
                               to: root.appendingPathComponent("missing-parent/ledger.json"))
            throw FixtureFailure.failed("Synthetic missing parent must reject the ledger write.")
        } catch is CocoaError { }
        do {
            _ = try ledger.wasAccepted(dispatch, sessionID: session, digest: digest)
            throw FixtureFailure.failed("Failed write must not accept a dispatch.")
        } catch SkynetMobile.SkynetError.relayRejected {
            try require(true, "Failed ledger write preserves the in-memory pending receipt")
        }
        try ledger.persist(.accepted, dispatch: dispatch, sessionID: session, digest: digest, to: url)
        let restored = MobileDispatchLedger(url: url)
        let accepted = try restored.wasAccepted(dispatch, sessionID: session, digest: digest)
        try require(accepted, "Accepted receipt survives ledger recreation")
        do {
            _ = try restored.wasAccepted(dispatch, sessionID: "another-synthetic-session", digest: digest)
            throw FixtureFailure.failed("Receipt must not authorize a different session.")
        } catch SkynetMobile.SkynetError.relayRejected {
            try require(true, "Ledger binds accepted receipts to the exact session")
        }
        let corruptURL = root.appendingPathComponent("synthetic-corrupt-ledger.json")
        try Data("invalid-json".utf8).write(to: corruptURL)
        do {
            _ = try MobileDispatchLedger(url: corruptURL).writableURL(corruptURL)
            throw FixtureFailure.failed("Unreadable ledger must fail closed.")
        } catch SkynetMobile.SkynetError.relayRejected {
            try require(true, "Unreadable ledger never permits a new send")
        }
    }
}
