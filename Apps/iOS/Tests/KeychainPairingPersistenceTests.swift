import SkynetMobile
import Foundation
import Security
import XCTest

#if targetEnvironment(simulator)
/// Exercises the simulator's real Keychain entitlement with an isolated,
/// synthetic pairing. No production service, account, or defaults are touched.
final class KeychainPairingPersistenceTests: XCTestCase {
    func testAtomicPairingSurvivesStoreRecreationAndForgetsBothValues() async throws {
        let namespace = UUID().uuidString.lowercased()
        let service = "app.skynet.tests.pairing.\(namespace)"
        let suite = "app.skynet.tests.metadata.\(namespace)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            // Exact generated service only, including cleanup after assertions fail.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            let status = SecItemDelete(query as CFDictionary)
            XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound,
                          "Fixture Keychain cleanup failed: \(status)")
            defaults.removePersistentDomain(forName: suite)
        }

        let machine = Machine(id: MachineID("synthetic-keychain-mac"), displayName: "Fixture Mac", status: .online)
        let credential = MachineCredential(
            relayEndpoint: try XCTUnwrap(URL(string: "skynet-relay://127.0.0.1:7343")),
            accessToken: "synthetic-access-token",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let original = KeychainPairedMachineStore(service: service, defaults: defaults)
        let initialMachines = try await original.machines()
        let initialCredential = try await original.credential(for: machine.id)
        XCTAssertTrue(initialMachines.isEmpty)
        XCTAssertNil(initialCredential)

        // Legacy account CRUD uses the same query/update/delete primitives.
        try await original.saveCredential(credential, for: machine.id)
        var replacement = credential
        replacement.accessToken = "synthetic-replacement-token"
        try await original.saveCredential(replacement, for: machine.id)
        let legacyCredential = try await original.credential(for: machine.id)
        XCTAssertEqual(legacyCredential, replacement)
        try await original.removeCredential(for: machine.id)
        try await original.removeCredential(for: machine.id)
        let removedLegacyCredential = try await original.credential(for: machine.id)
        XCTAssertNil(removedLegacyCredential)

        try await original.savePairing(machine: machine, credential: credential)
        let recreated = KeychainPairedMachineStore(
            service: service, defaults: try XCTUnwrap(UserDefaults(suiteName: suite))
        )
        let recoveredMachines = try await recreated.machines()
        let recoveredCredential = try await recreated.credential(for: machine.id)
        XCTAssertEqual(recoveredMachines, [machine])
        XCTAssertEqual(recoveredCredential, credential)

        var renamed = machine
        renamed.displayName = "Renamed Fixture Mac"
        try await recreated.rememberMachine(renamed)
        try await recreated.saveCredential(replacement, for: machine.id)
        let updatedMachines = try await original.machines()
        let updatedCredential = try await original.credential(for: machine.id)
        XCTAssertEqual(updatedMachines, [renamed])
        XCTAssertEqual(updatedCredential, replacement)
        try await original.removeCredential(for: machine.id)
        let removedPairing = try await recreated.machines()
        XCTAssertTrue(removedPairing.isEmpty)

        try await original.savePairing(machine: machine, credential: credential)
        try await recreated.forgetMachine(machine.id)
        let remainingMachines = try await original.machines()
        let remainingCredential = try await original.credential(for: machine.id)
        XCTAssertTrue(remainingMachines.isEmpty)
        XCTAssertNil(remainingCredential)
    }
}
#endif
