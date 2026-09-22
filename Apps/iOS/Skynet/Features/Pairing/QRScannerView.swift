import SwiftUI
@preconcurrency import AVFoundation

/// Live QR scanner for the pairing flow. Wraps `AVCaptureSession`; when no
/// camera is available (Simulator) or permission has been denied, it shows an
/// explanatory fallback instead — the manual entry path in `PairingView`
/// remains the escape hatch in every case.
public struct QRScannerView: UIViewControllerRepresentable {
    /// Called on the main actor with the raw scanned string. Duplicate reads
    /// of the same code within a short window are filtered by the scanner.
    public let onCode: @MainActor (_ raw: String) -> Void

    public init(onCode: @MainActor @escaping (_ raw: String) -> Void) {
        self.onCode = onCode
    }

    public func makeUIViewController(context: Context) -> ScannerViewController {
        ScannerViewController(onCode: onCode)
    }

    public func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

/// UIKit-side owner of the capture session. Capture plumbing is markedly
/// simpler as a plain view controller: the session is configured and started
/// on a dedicated queue off the main thread, per the AVCam sample's guidance.
@MainActor
public final class ScannerViewController: UIViewController {
    private let onCode: @MainActor (String) -> Void
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.skynet.pairing.scanner", qos: .userInitiated)
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var fallbackView: UILabel?
    private var metadataDelegate: ScannerMetadataDelegate?

    /// Duplicate-scan suppression: the same QR can be decoded several times a
    /// second while the camera keeps seeing it.
    private var lastCode: String?
    private var lastCodeAt = Date.distantPast
    private static let duplicateWindow: TimeInterval = 2

    public init(onCode: @MainActor @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ScannerViewController is created in code")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = A11yID.Pairing.scannerView
        configureSession()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: - Session configuration

    private func configureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startConfiguration()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.startConfiguration()
                    } else {
                        self.showFallback(
                            title: "Camera access is off",
                            message: "Enable camera access in Settings, or type the pairing code instead."
                        )
                    }
                }
            }
        default:
            showFallback(
                title: "Camera unavailable",
                message: "Type the pairing code instead — it works everywhere the camera can't."
            )
        }
    }

    private func startConfiguration() {
        let delegate = ScannerMetadataDelegate(controller: self)
        metadataDelegate = delegate
        sessionQueue.async { [session, delegate, sessionQueue, weak self] in
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                Task { @MainActor [weak self] in
                    self?.showFallback(
                        title: "No camera found",
                        message: "This device has no usable camera. Type the pairing code instead."
                    )
                }
                return
            }

            session.beginConfiguration()
            session.sessionPreset = .high
            let output = AVCaptureMetadataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                Task { @MainActor [weak self] in
                    self?.showFallback(
                        title: "Scanner unavailable",
                        message: "The camera couldn't be configured. Type the pairing code instead."
                    )
                }
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: sessionQueue)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            session.startRunning()

            Task { @MainActor [weak self] in
                self?.attachPreview()
            }
        }
    }

    private func attachPreview() {
        guard previewLayer == nil else { return }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        addReticle(over: layer)
    }

    /// Centered rounded-rect reticle so users know where to point.
    private func addReticle(over layer: AVCaptureVideoPreviewLayer) {
        let reticle = UIView()
        reticle.isUserInteractionEnabled = false
        reticle.layer.borderColor = UIColor.white.cgColor
        reticle.layer.borderWidth = 2
        reticle.layer.cornerRadius = Theme.Radius.lg
        reticle.isAccessibilityElement = false
        reticle.accessibilityElementsHidden = true
        view.addSubview(reticle)
        reticle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            reticle.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.62),
            reticle.heightAnchor.constraint(equalTo: reticle.widthAnchor),
            reticle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            reticle.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func showFallback(title: String, message: String) {
        let label = UILabel()
        label.text = "\(title)\n\n\(message)"
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.xl),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Spacing.xl),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        fallbackView = label
    }

    // MARK: - Code delivery

    fileprivate func deliverIfFresh(_ raw: String) {
        let now = Date()
        if let lastCode, lastCode == raw, now.timeIntervalSince(lastCodeAt) < Self.duplicateWindow {
            return
        }
        lastCode = raw
        lastCodeAt = now
        Log.pairing.debug("Scanned pairing payload")
        onCode(raw)
    }
}

/// Adapter that satisfies `AVCaptureMetadataOutputObjectsDelegate` off the
/// main actor and forwards decoded QR strings to the main-actor controller.
private final class ScannerMetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    weak var controller: ScannerViewController?

    init(controller: ScannerViewController) {
        self.controller = controller
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              object.type == .qr,
              let value = object.stringValue else { return }
        Task { @MainActor [weak self] in
            self?.controller?.deliverIfFresh(value)
        }
    }
}
