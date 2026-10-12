import SkynetMobile
import XCTest
@testable import Skynet

/// Behavioral tests for the pairing state machine against the scripted
/// pairing service and an in-memory machine store.
@MainActor
final class PairingViewModelTests: XCTestCase {
    private var service: ScriptedPairingService!
    private var store: InMemoryPairedMachineStore!
    private var model: PairingViewModel!

    override func setUp() {
        super.setUp()
        service = ScriptedPairingService(machine: PreviewData.machine)
        store = InMemoryPairedMachineStore()
        model = PairingViewModel(pairing: service, store: store)
    }

    // MARK: - Entry points

    func testShowScannerAndManualEntryResetTransientState() {
        model.enteredCode = "leftover"
        model.verificationCode = "123456"
        model.showScanner()
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertEqual(model.enteredCode, "")

        model.enteredCode = "again"
        model.showManualEntry()
        XCTAssertEqual(model.phase, .manualEntry)
        XCTAssertEqual(model.enteredCode, "")
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - Code intake

    func testManualCodeHappyPathReachesVerification() async {
        model.showManualEntry()
        model.enteredCode = PreviewData.pairingCode()
        await model.submitManualCode()

        guard case .verifying(let handshake) = model.phase else {
            return XCTFail("Expected verifying phase, got \(model.phase)")
        }
        XCTAssertEqual(handshake.machine.displayName, "Studio Mac")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isWorking)
        // The expected code must not leak into user-visible state.
        XCTAssertEqual(model.verificationCode, "")
    }

    func testScannedCodeIntakeMatchesManualEntry() async {
        model.showScanner()
        await model.handleScannedCode(PreviewData.pairingCode())
        guard case .verifying = model.phase else {
            return XCTFail("Expected verifying phase, got \(model.phase)")
        }
    }

    func testInvalidCodeStaysOnEntryWithError() async {
        model.showManualEntry()
        model.enteredCode = "https://not-a-pairing-code.example/offer"
        await model.submitManualCode()

        XCTAssertEqual(model.phase, .manualEntry)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(service.confirmedCodes.isEmpty, "confirm must never be reached")
    }

    func testEmptyCodeShowsGuidance() async {
        model.showManualEntry()
        model.enteredCode = "   "
        await model.submitManualCode()

        XCTAssertEqual(model.phase, .manualEntry)
        XCTAssertNotNil(model.errorMessage)
    }

    func testExpiredOfferIsRejectedBeforeHandshake() async {
        let codec = PairingCodeCodec()
        let expired = PairingOffer(
            relayEndpoint: URL(string: "https://mac.example:7343/relay")!,
            machineName: "Studio Mac",
            token: "tok-expired",
            expiresAt: Date(timeIntervalSinceNow: -60)
        )
        model.showManualEntry()
        model.enteredCode = codec.encode(expired)
        await model.submitManualCode()

        XCTAssertEqual(model.phase, .manualEntry)
        XCTAssertNotNil(model.errorMessage)
    }

    func testBeginFailureLandsInFailedPhase() async {
        service.beginError = PairingError.transportFailed("relay unreachable")
        model.showManualEntry()
        model.enteredCode = PreviewData.pairingCode()
        await model.submitManualCode()

        XCTAssertEqual(model.phase, .failed("relay unreachable"))
    }

    // MARK: - Verification

    func testConfirmWithMatchingCodeStoresMachineAndCredential() async throws {
        await arrangeVerifying()
        model.verificationCode = service.expectedCode
        await model.confirmVerificationCode()

        guard case .paired(let machine) = model.phase else {
            return XCTFail("Expected paired phase, got \(model.phase)")
        }
        XCTAssertEqual(machine.id, PreviewData.machine.id)
        XCTAssertEqual(model.pairedMachine?.id, PreviewData.machine.id)

        let stored = try await store.machines()
        XCTAssertEqual(stored.map(\.id), [PreviewData.machine.id])
        let credential = try await store.credential(for: PreviewData.machine.id)
        XCTAssertEqual(credential?.accessToken, "preview-access-token")
    }

    func testConfirmWithWrongCodeStaysInVerifyingAndStoresNothing() async throws {
        await arrangeVerifying()
        model.verificationCode = "000000"
        await model.confirmVerificationCode()

        guard case .verifying = model.phase else {
            return XCTFail("A mismatch should stay in verifying, got \(model.phase)")
        }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.verificationCode, "", "field is cleared for a retry")
        let storedMachines = try await store.machines()
        XCTAssertTrue(storedMachines.isEmpty)
        let credential = try await store.credential(for: PreviewData.machine.id)
        XCTAssertNil(credential)
    }

    func testConfirmWithShortCodeNeverCallsTheService() async {
        await arrangeVerifying()
        model.verificationCode = "123"
        await model.confirmVerificationCode()

        XCTAssertTrue(service.confirmedCodes.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        guard case .verifying = model.phase else {
            return XCTFail("Expected to remain in verifying, got \(model.phase)")
        }
    }

    func testConfirmTransportFailureLandsInFailedPhase() async {
        service.confirmError = PairingError.rejected("already paired with another phone")
        await arrangeVerifying()
        model.verificationCode = service.expectedCode
        await model.confirmVerificationCode()

        guard case .failed(let message) = model.phase else {
            return XCTFail("Expected failed phase, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("already paired"))
    }

    func testConfirmOutsideVerifyingPhaseIsANoOp() async {
        model.verificationCode = "418942"
        await model.confirmVerificationCode()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(service.confirmedCodes.isEmpty)
    }

    // MARK: - Recovery

    func testRestartReturnsToIdleAndClearsState() async {
        await arrangeVerifying()
        model.restart()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.verificationCode, "")
        XCTAssertNil(model.errorMessage)
    }

    func testCancelDuringVerificationReturnsToIdle() async {
        await arrangeVerifying()
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
    }

    func testCannotPairSecondMac() async throws {
        try await store.rememberMachine(PreviewData.machine)
        model.enteredCode = PreviewData.pairingCode()
        await model.submitManualCode()
        guard case .failed(let message) = model.phase else { return XCTFail("Expected pairing limit") }
        XCTAssertTrue(message.contains("Unpair"))
        XCTAssertTrue(service.confirmedCodes.isEmpty)
    }

    func testNonNumericVerificationNeverReachesService() async {
        await arrangeVerifying()
        model.verificationCode = "ABCDEF"
        await model.confirmVerificationCode()
        XCTAssertTrue(service.confirmedCodes.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testCanceledHandshakeCannotOverwriteRestartedFlow() async {
        let suspended = SuspendedPairingService()
        let model = PairingViewModel(pairing: suspended, store: InMemoryPairedMachineStore())
        let intake = Task { await model.handleScannedCode(PreviewData.pairingCode()) }
        await suspended.waitForPendingHandshake()
        model.cancel()
        model.showManualEntry()
        await suspended.completeHandshake()
        await intake.value
        XCTAssertEqual(model.phase, .manualEntry)
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.pairedMachine)
    }

    // MARK: - Helpers

    private func arrangeVerifying() async {
        model.showManualEntry()
        model.enteredCode = PreviewData.pairingCode()
        await model.submitManualCode()
        guard case .verifying = model.phase else {
            XCTFail("Arrange failed: expected verifying, got \(model.phase)")
            return
        }
    }
}

private actor SuspendedPairingService: PairingService {
    private var continuation: CheckedContinuation<PairingHandshake, any Error>?
    private var pendingOffer: PairingOffer?

    nonisolated func parseCode(_ raw: String) throws -> PairingOffer {
        try PairingCodeCodec().decode(raw)
    }

    func beginPairing(with offer: PairingOffer) async throws -> PairingHandshake {
        pendingOffer = offer
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitForPendingHandshake() async {
        while continuation == nil { await Task.yield() }
    }

    func completeHandshake() {
        guard let offer = pendingOffer else { return }
        continuation?.resume(returning: PairingHandshake(
            offer: offer, verificationCode: "", machine: PreviewData.machine
        ))
        continuation = nil
    }

    func confirm(_ handshake: PairingHandshake, enteredCode: String) async throws -> PairingResult {
        throw PairingError.rejected("Not used by this fixture")
    }

    func unpair(_ machineID: MachineID) async throws {}
}
