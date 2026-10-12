import SkynetMobile
import Foundation

/// Drives the secure pairing flow's UI state machine:
/// scan or type a pairing code → handshake → confirm the six-digit
/// verification code shown on the Mac → machine + credential stored.
///
/// The expected code is never displayed on this device; the user reads it off
/// the Mac and types it, which is what binds the two endpoints.
@MainActor
@Observable
public final class PairingViewModel {
    public enum Phase: Equatable {
        case idle
        case scanning
        case manualEntry
        case connecting(PairingOffer)
        case verifying(PairingHandshake)
        case paired(Machine)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public var enteredCode = ""
    public var verificationCode = ""
    public private(set) var errorMessage: String?
    public private(set) var isWorking = false

    /// Set once pairing completes, for callers that auto-dismiss.
    public private(set) var pairedMachine: Machine?

    private let pairing: any PairingService
    private let store: any PairedMachineStore
    private var generation = 0

    public init(pairing: any PairingService, store: any PairedMachineStore) {
        self.pairing = pairing
        self.store = store
    }

    // MARK: - Navigation between entry modes

    public func showScanner() {
        resetTransientState()
        phase = .scanning
    }

    public func showManualEntry() {
        resetTransientState()
        phase = .manualEntry
    }

    public func restart() {
        resetTransientState()
        phase = .idle
    }

    public func cancel() {
        resetTransientState()
        phase = .idle
    }

    // MARK: - Code intake

    /// Entry point for the QR scanner.
    public func handleScannedCode(_ raw: String) async {
        await intake(raw)
    }

    /// Entry point for the manual entry field.
    public func submitManualCode() async {
        await intake(enteredCode)
    }

    private func intake(_ raw: String) async {
        guard !isWorking else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter the pairing code shown on your Mac."
            return
        }
        let offer: PairingOffer
        do {
            offer = try pairing.parseCode(trimmed)
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
            return
        }
        guard !offer.isExpired else {
            errorMessage = "That pairing code has expired. Generate a new one on your Mac."
            return
        }

        isWorking = true
        generation += 1
        let requestGeneration = generation
        defer { if requestGeneration == generation { isWorking = false } }
        errorMessage = nil
        phase = .connecting(offer)
        do {
            guard try await store.machines().isEmpty else {
                throw PairingError.rejected("Unpair your current Mac before pairing another one.")
            }
            guard requestGeneration == generation, !Task.isCancelled else { return }
            let handshake = try await pairing.beginPairing(with: offer)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            verificationCode = ""
            phase = .verifying(handshake)
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            phase = .failed(Self.friendlyMessage(for: error))
        }
    }

    // MARK: - Verification

    public func confirmVerificationCode() async {
        guard !isWorking, case .verifying(let handshake) = phase else { return }
        let entered = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entered.count == 6, entered.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            errorMessage = "Enter the six-digit code shown on your Mac."
            return
        }

        isWorking = true
        let requestGeneration = generation
        defer { if requestGeneration == generation { isWorking = false } }
        do {
            let result = try await pairing.confirm(handshake, enteredCode: entered)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            try await store.savePairing(machine: result.machine, credential: result.credential)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            Log.pairing.info("Paired with \(result.machine.displayName)")
            pairedMachine = result.machine
            phase = .paired(result.machine)
        } catch let error as PairingError where error == .verificationCodeMismatch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            // Stay on the verification screen so the user can retry.
            errorMessage = "That code doesn't match. Check the code on your Mac and try again."
            verificationCode = ""
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            phase = .failed(Self.friendlyMessage(for: error))
        }
    }

    // MARK: - Helpers

    private func resetTransientState() {
        generation += 1
        pairedMachine = nil
        enteredCode = ""
        verificationCode = ""
        errorMessage = nil
        isWorking = false
    }

    private static func friendlyMessage(for error: Error) -> String {
        switch error {
        case PairingError.invalidCode:
            return "That doesn't look like a pairing code. Copy it again from your Mac."
        case PairingError.expired:
            return "That pairing code has expired. Generate a new one on your Mac."
        case PairingError.verificationCodeMismatch:
            return "That code doesn't match the one on your Mac."
        case PairingError.rejected(let detail):
            return detail.isEmpty ? "Your Mac refused the pairing request." : detail
        case PairingError.transportFailed(let detail):
            return detail.isEmpty ? "Couldn't reach your Mac. Check the network and try again." : detail
        case SkynetError.notPaired:
            return "Pairing isn't configured yet. Make sure the Mac app is running."
        default:
            return "Pairing failed. \(error.localizedDescription)"
        }
    }
}
