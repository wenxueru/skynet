import Foundation
import Security

/// Long-lived credential issued to a paired machine. Secrets live in the
/// Keychain; this is the value type that crosses the store boundary.
public struct MachineCredential: Codable, Equatable, Sendable {
    public var relayEndpoint: URL
    public var accessToken: String
    public var issuedAt: Date

    public init(relayEndpoint: URL, accessToken: String, issuedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.relayEndpoint = relayEndpoint
        self.accessToken = accessToken
        self.issuedAt = issuedAt
    }
}

/// Persistence for paired machines: non-secret metadata in UserDefaults,
/// secrets in the Keychain. Protocol-fronted so previews and tests run
/// against memory.
public protocol PairedMachineStore: Sendable {
    func machines() async throws -> [Machine]
    func rememberMachine(_ machine: Machine) async throws
    func forgetMachine(_ machineID: MachineID) async throws

    func saveCredential(_ credential: MachineCredential, for machineID: MachineID) async throws
    func credential(for machineID: MachineID) async throws -> MachineCredential?
    func removeCredential(for machineID: MachineID) async throws
    /// Persist the pairing as one transaction. No machine may become visible without its credential.
    func savePairing(machine: Machine, credential: MachineCredential) async throws
}

public extension PairedMachineStore {
    func savePairing(machine: Machine, credential: MachineCredential) async throws {
        try await saveCredential(credential, for: machine.id)
        do { try await rememberMachine(machine) }
        catch {
            try? await removeCredential(for: machine.id)
            throw error
        }
    }
}

/// Production pairing is a single Keychain record; legacy metadata stays readable.
/// `@unchecked Sendable` because `UserDefaults` is documented thread-safe
/// but not annotated `Sendable`.
public final class KeychainPairedMachineStore: PairedMachineStore, @unchecked Sendable {
    private let service: String
    private let defaults: UserDefaults

    public init(
        service: String = "app.skynet.machine-credentials",
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
    }

    // MARK: - Machines (UserDefaults)

    public func machines() async throws -> [Machine] {
        if let pairing = try readPairing() { return [pairing.machine] }
        guard let data = defaults.data(forKey: Self.machinesKey),
              let list = try? JSONDecoder().decode([Machine].self, from: data) else {
            return []
        }
        return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func rememberMachine(_ machine: Machine) async throws {
        if let pairing = try readPairing(), pairing.machine.id == machine.id {
            try await savePairing(machine: machine, credential: pairing.credential)
            return
        }
        var list = try await machines()
        list.removeAll { $0.id == machine.id }
        list.append(machine)
        let data = try JSONEncoder().encode(list)
        defaults.set(data, forKey: Self.machinesKey)
    }

    public func forgetMachine(_ machineID: MachineID) async throws {
        if let pairing = try readPairing(), pairing.machine.id == machineID {
            try deleteKeychain(account: Self.pairingAccount)
        }
        var list = try await machines()
        list.removeAll { $0.id == machineID }
        let data = try JSONEncoder().encode(list)
        defaults.set(data, forKey: Self.machinesKey)
        try await removeCredential(for: machineID)
    }

    // MARK: - Credentials (Keychain)

    public func saveCredential(_ credential: MachineCredential, for machineID: MachineID) async throws {
        if let pairing = try readPairing(), pairing.machine.id == machineID {
            try await savePairing(machine: pairing.machine, credential: credential)
            return
        }
        try writeKeychain(JSONEncoder().encode(credential), account: machineID.rawValue)
    }

    public func credential(for machineID: MachineID) async throws -> MachineCredential? {
        if let pairing = try readPairing(), pairing.machine.id == machineID { return pairing.credential }
        return try readKeychain(MachineCredential.self, account: machineID.rawValue)
    }

    public func removeCredential(for machineID: MachineID) async throws {
        if let pairing = try readPairing(), pairing.machine.id == machineID {
            try deleteKeychain(account: Self.pairingAccount)
        }
        try deleteKeychain(account: machineID.rawValue)
    }

    public func savePairing(machine: Machine, credential: MachineCredential) async throws {
        let data = try JSONEncoder().encode(PairingRecord(machine: machine, credential: credential))
        try writeKeychain(data, account: Self.pairingAccount)
    }

    private struct PairingRecord: Codable {
        let machine: Machine
        let credential: MachineCredential
    }

    private func readPairing() throws -> PairingRecord? {
        try readKeychain(PairingRecord.self, account: Self.pairingAccount)
    }

    private func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func writeKeychain(_ data: Data, account: String) throws {
        let query = keychainQuery(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw SkynetError.keychainFailure(result) }
        } else if status != errSecSuccess {
            throw SkynetError.keychainFailure(status)
        }
    }

    private func readKeychain<Value: Decodable>(_ type: Value.Type, account: String) throws -> Value? {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SkynetError.keychainFailure(status) }
        guard let data = item as? Data else { throw SkynetError.keychainFailure(errSecInvalidData) }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw SkynetError.keychainFailure(errSecInvalidData) }
    }

    private func deleteKeychain(account: String) throws {
        let status = SecItemDelete(keychainQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SkynetError.keychainFailure(status) }
    }

    private static let pairingAccount = "paired-mac-record"

    private static let machinesKey = "app.skynet.paired-machines"
}

/// In-memory store for previews, unit tests, and UI-test fixtures.
public final class InMemoryPairedMachineStore: PairedMachineStore, @unchecked Sendable {
    private let lock = NSLock()
    private var machineList: [Machine] = []
    private var credentials: [MachineID: MachineCredential] = [:]

    public init(machines: [Machine] = [], credentials: [MachineID: MachineCredential] = [:]) {
        self.machineList = machines
        self.credentials = credentials
    }

    public func machines() async throws -> [Machine] {
        lock.withLock {
            machineList.sorted { $0.displayName < $1.displayName }
        }
    }

    public func rememberMachine(_ machine: Machine) async throws {
        lock.withLock {
            machineList.removeAll { $0.id == machine.id }
            machineList.append(machine)
        }
    }

    public func forgetMachine(_ machineID: MachineID) async throws {
        lock.withLock {
            machineList.removeAll { $0.id == machineID }
            credentials[machineID] = nil
        }
    }

    public func saveCredential(_ credential: MachineCredential, for machineID: MachineID) async throws {
        lock.withLock {
            credentials[machineID] = credential
        }
    }

    public func savePairing(machine: Machine, credential: MachineCredential) async throws {
        lock.withLock {
            machineList = [machine]
            credentials = [machine.id: credential]
        }
    }

    public func credential(for machineID: MachineID) async throws -> MachineCredential? {
        lock.withLock {
            credentials[machineID]
        }
    }

    public func removeCredential(for machineID: MachineID) async throws {
        lock.withLock {
            credentials[machineID] = nil
        }
    }
}
