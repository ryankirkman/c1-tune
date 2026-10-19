import AVFoundation
import AppKit

/// Live view from the Opal C1. Runs only while the panel is open with Preview on, at
/// 720p so it starts quickly and stays light. Nothing is set up until the first use.
@MainActor
final class PreviewView: NSView {
    private var capture: Capture?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let message = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }

    func start() {
        if let image = DemoMode.previewImage {
            layer?.contents = image
            layer?.contentsGravity = .resizeAspectFill
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            message.stringValue = ""
            setUpIfNeeded().start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted { self?.start() } else { self?.showDenied() }
                }
            }
        default:
            showDenied()
        }
    }

    func stop() { capture?.stop() }

    /// Drops the capture input; call when the camera re-enumerates.
    func reset() { capture?.reset() }

    private func setUpIfNeeded() -> Capture {
        if let capture { return capture }
        let capture = Capture()
        let previewLayer = AVCaptureVideoPreviewLayer(session: capture.session)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.frame = bounds
        layer?.insertSublayer(previewLayer, at: 0)
        self.capture = capture
        self.previewLayer = previewLayer
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceDisconnected), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        return capture
    }

    @objc private func deviceDisconnected() { capture?.reset() }

    private func showDenied() {
        message.stringValue = "Allow camera access for C1 Tune in\nSystem Settings → Privacy & Security."
    }
}

/// For README screenshots: `C1TUNE_DEMO_IMAGE=<photo> C1Tune` opens the panel on launch and
/// shows that photo in the preview instead of the camera.
enum DemoMode {
    static let previewImage: NSImage? = ProcessInfo.processInfo.environment["C1TUNE_DEMO_IMAGE"]
        .flatMap { NSImage(contentsOfFile: $0) }
}

/// Owns the capture session; all session work happens on its own queue.
private final class Capture: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.ryankirkman.c1tune.preview")
    private var configured = false   // only touched on `queue`

    func start() {
        queue.async { [self] in
            if !configured { configured = configure() }
            if configured && !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func reset() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
            configured = false
        }
    }

    private func configure() -> Bool {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices
        // Match the real USB camera, not Opal's virtual camera, if that is still installed.
        let usbID = "VendorID_\(USB.vendorID) ProductID_\(OpalPID.booted.rawValue)"
        guard let device = devices.first(where: { $0.modelID.contains(usbID) }),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        return true
    }
}
