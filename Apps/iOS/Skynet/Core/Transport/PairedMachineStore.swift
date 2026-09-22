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
}

/// Production store: Keychain for credentials, UserDefaults for metadata.
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
        guard let data = defaults.data(forKey: Self.machinesKey),
              let list = try? JSONDecoder().decode([Machine].self, from: data) else {
            return []
        }
        return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func rememberMachine(_ machine: Machine) async throws {
        var list = try await machines()
        list.removeAll { $0.id == machine.id }
        list.append(machine)
        let data = try JSONEncoder().encode(list)
        defaults.set(data, forKey: Self.machinesKey)
    }

    public func forgetMachine(_ machineID: MachineID) async throws {
        var list = try await machines()
        list.removeAll { $0.id == machineID }
        let data = try JSONEncoder().encode(list)
        defaults.set(data, forKey: Self.machinesKey)
        try await removeCredential(for: machineID)
    }

    // MARK: - Credentials (Keychain)

    public func saveCredential(_ credential: MachineCredential, for machineID: MachineID) async throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: machineID.rawValue,
        ]

        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SkynetError.keychainFailure(addStatus)
            }
        } else if status != errSecSuccess {
            throw SkynetError.keychainFailure(status)
        }
    }

    public func credential(for machineID: MachineID) async throws -> MachineCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: machineID.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let credential = try? JSONDecoder().decode(MachineCredential.self, from: data) else {
                throw SkynetError.keychainFailure(errSecInvalidData)
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw SkynetError.keychainFailure(status)
        }
    }

    public func removeCredential(for machineID: MachineID) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: machineID.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SkynetError.keychainFailure(status)
        }
    }

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
