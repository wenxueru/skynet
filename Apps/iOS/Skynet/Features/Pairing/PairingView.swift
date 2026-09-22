import SwiftUI

/// The secure pairing flow, presented as a sheet (or pushed on compact
/// widths). Phase-driven: entry → handshake → six-digit verification → done.
///
/// Security shape: the offer token travels in the QR code, but the pairing is
/// only completed when the user types the six-digit code the Mac displays —
/// this screen never shows that code itself.
public struct PairingView: View {
    @State private var model: PairingViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var codeFieldFocused: Bool

    private let onPaired: @MainActor (Machine) -> Void

    public init(environment: AppEnvironment, onPaired: @MainActor @escaping (Machine) -> Void = { _ in }) {
        // State is seeded from the environment at creation time; the pairing
        // service and store are stable for the lifetime of the flow.
        self.init(
            model: PairingViewModel(
                pairing: environment.pairing,
                store: environment.machineStore
            ),
            onPaired: onPaired
        )
    }

    /// Direct-model init for previews and UI tests that want to start in a
    /// specific phase.
    public init(model: PairingViewModel, onPaired: @MainActor @escaping (Machine) -> Void = { _ in }) {
        _model = State(initialValue: model)
        self.onPaired = onPaired
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .idle:
                    entryView
                case .scanning:
                    scannerView
                case .manualEntry:
                    manualEntryView
                case .connecting:
                    connectingView
                case .verifying(let handshake):
                    verifyingView(handshake)
                case .paired(let machine):
                    pairedView(machine)
                case .failed(let message):
                    failedView(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancel()
                        dismiss()
                    }
                    .accessibilityIdentifier(A11yID.Pairing.cancelButton)
                }
            }
        }
        .accessibilityIdentifier(A11yID.Pairing.root)
    }

    // MARK: - Entry

    private var entryView: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Connect to your Mac")
                    .font(.title2.weight(.semibold))
                Text(
                    "On your Mac, open the agent app and choose “Add iPhone”. "
                        + "Scan the pairing code it shows, or type it in."
                )
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Spacing.xl)

            VStack(spacing: Theme.Spacing.md) {
                Button {
                    model.showScanner()
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(A11yID.Pairing.scanQRButton)

                Button {
                    model.showManualEntry()
                } label: {
                    Label("Enter Code Manually", systemImage: "keyboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(A11yID.Pairing.enterCodeButton)
            }
            .padding(.horizontal, Theme.Spacing.xl)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Scanner

    private var scannerView: some View {
        VStack(spacing: 0) {
            QRScannerView { raw in
                Task { await model.handleScannedCode(raw) }
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: Theme.Spacing.md) {
                Text("Point the camera at the pairing code on your Mac")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)

                Button {
                    model.showManualEntry()
                } label: {
                    Label("Type the Code Instead", systemImage: "keyboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(A11yID.Pairing.enterCodeButton)
            }
            .padding(Theme.Spacing.lg)
            .background(.thinMaterial)
        }
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                BannerView(message, style: .error)
                    .padding(Theme.Spacing.md)
                    .accessibilityIdentifier(A11yID.Pairing.errorLabel)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Manual entry

    private var manualEntryView: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            VStack(spacing: Theme.Spacing.md) {
                Label("Pairing code", systemImage: "link")
                    .font(.headline)

                TextField(
                    "skynet-pair://pair?…",
                    text: $model.enteredCode,
                    axis: .vertical
                )
                .font(Theme.monoFootnote)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .lineLimit(1...4)
                .focused($codeFieldFocused)
                .onSubmit { Task { await model.submitManualCode() } }
                .accessibilityIdentifier(A11yID.Pairing.manualEntryField)

                Text("Copy the code shown on your Mac and paste it here.")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, Theme.Spacing.xl)

            Button {
                codeFieldFocused = false
                Task { await model.submitManualCode() }
            } label: {
                Label("Continue", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking)
            .padding(.horizontal, Theme.Spacing.xl)
            .accessibilityIdentifier(A11yID.Pairing.manualEntrySubmit)

            if let message = model.errorMessage {
                BannerView(message, style: .error)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .accessibilityIdentifier(A11yID.Pairing.errorLabel)
            }

            Spacer()
            Spacer()
        }
        .onAppear { codeFieldFocused = true }
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            if case .connecting(let offer) = model.phase {
                Text("Contacting \(offer.machineName)…")
                    .font(.headline)
                    .accessibilityIdentifier(A11yID.Pairing.machineNameLabel)
            }
            Text("Opening a secure handshake with the relay.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            Spacer()
            Spacer()
        }
    }

    // MARK: - Verification

    private func verifyingView(_ handshake: PairingHandshake) -> some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            VStack(spacing: Theme.Spacing.sm) {
                Label("Verify your Mac", systemImage: "lock.shield")
                    .font(.headline)
                Text("Your Mac is showing a six-digit code. Type it below to confirm both screens see the same code.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Spacing.xl)

            Text(handshake.machine.displayName)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier(A11yID.Pairing.machineNameLabel)

            TextField("6-digit code", text: $model.verificationCode)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .frame(maxWidth: 220)
                .padding(Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .focused($codeFieldFocused)
                .onChange(of: model.verificationCode) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue {
                        model.verificationCode = digits
                    }
                }
                .accessibilityIdentifier(A11yID.Pairing.verificationField)

            Button {
                codeFieldFocused = false
                Task { await model.confirmVerificationCode() }
            } label: {
                Label("Verify and Pair", systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking || model.verificationCode.count != 6)
            .padding(.horizontal, Theme.Spacing.xl)
            .accessibilityIdentifier(A11yID.Pairing.verifyButton)

            if let message = model.errorMessage {
                BannerView(message, style: .error)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .accessibilityIdentifier(A11yID.Pairing.errorLabel)
            }

            Spacer()
            Spacer()
        }
        .onAppear { codeFieldFocused = true }
    }

    // MARK: - Terminal states

    private func pairedView(_ machine: Machine) -> some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.success)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Paired with \(machine.displayName)")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(A11yID.Pairing.successLabel)
                Text("You can now start sessions on this device.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, Theme.Spacing.xl)

            Button {
                onPaired(machine)
                dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, Theme.Spacing.xl)
            .accessibilityIdentifier(A11yID.Pairing.successDoneButton)

            Spacer()
            Spacer()
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)

            BannerView(message, style: .error)
                .padding(.horizontal, Theme.Spacing.xl)
                .accessibilityIdentifier(A11yID.Pairing.errorLabel)

            Button {
                model.restart()
            } label: {
                Label("Try Again", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, Theme.Spacing.xl)

            Spacer()
            Spacer()
        }
    }
}

// MARK: - Previews

#Preview("Pairing flow") {
    // To try the full flow in the preview: tap “Enter Code Manually” and paste
    // a code from PreviewData.pairingCode(), then type 418942 to verify.
    PairingView(environment: .preview()) { _ in }
}

#Preview("Verifying") {
    let model = PairingViewModel(
        pairing: ScriptedPairingService(machine: PreviewData.machine),
        store: InMemoryPairedMachineStore()
    )
    return PairingView(model: model) { _ in }
        .task {
            // Drive the scripted service into the verification step.
            model.enteredCode = PreviewData.pairingCode()
            await model.submitManualCode()
        }
}
