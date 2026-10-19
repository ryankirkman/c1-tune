import AppKit
import ServiceManagement

/// The popover: exposure, focus, white balance, image, anti-flicker, and an optional preview.
@MainActor
final class ControlPanel: NSViewController {
    /// Called with the new settings and which group of camera commands to send.
    var onChange: ((CameraSettings, CameraSettings.Group) -> Void)?
    var onReset: (() -> Void)?
    /// Settings that only take effect when the camera's pipeline restarts (orientation).
    var onRestartNeeded: ((CameraSettings) -> Void)?
    var onRetry: (() -> Void)?

    let preview = PreviewView()
    private(set) var settings: CameraSettings

    private let status = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let autoExposure = NSSwitch()
    private let autoFocus = NSSwitch()
    private let autoWhiteBalance = NSSwitch()
    private let flicker = NSPopUpButton()
    private let previewToggle = NSButton(checkboxWithTitle: "Preview", target: nil, action: nil)
    private let loginToggle = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let flipToggle = NSButton(checkboxWithTitle: "Flip image", target: nil, action: nil)
    private let micToggle = NSButton(checkboxWithTitle: "Microphone", target: nil, action: nil)

    private var previewHeight: NSLayoutConstraint!
    private var currentStatus = OpalSession.Status.notConnected
    private var isOpen = false

    private let shutter = SliderRow("Shutter", 100...33_000, step: 100) { String(format: "%.1f ms", Double($0) / 1000) }
    private let iso = SliderRow("ISO", 100...1600, step: 50) { "\($0)" }
    private let compensation = SliderRow("Bias", -9...9) { $0 > 0 ? "+\($0)" : "\($0)" }
    private let focus = SliderRow("Distance", 0...255) { "\($0)" }
    private let temperature = SliderRow("Temperature", 1000...12_000, step: 100) { "\($0) K" }
    private let brightness = SliderRow("Brightness", -10...10) { $0 > 0 ? "+\($0)" : "\($0)" }
    private let contrast = SliderRow("Contrast", -10...10) { $0 > 0 ? "+\($0)" : "\($0)" }
    private let saturation = SliderRow("Saturation", -10...10) { $0 > 0 ? "+\($0)" : "\($0)" }
    private let sharpness = SliderRow("Sharpness", 0...4) { "\($0)" }
    private let denoise = SliderRow("Denoise", 0...4) { "\($0)" }
    private let colorDenoise = SliderRow("Color denoise", 0...4) { "\($0)" }
    // Zoom and framing restart the camera, so they apply on release (the label tracks the drag).
    private let zoom = SliderRow("Zoom", 0...(CameraSettings.zoomStops.count - 1), applyOnRelease: true) {
        let p = CameraSettings.zoomStops[$0].percent
        return p == 100 ? "1×" : p == 200 ? "2×" : String(format: "%.2f×", Double(p) / 100)
    }
    private let frameX = SliderRow("Left – right", 0...100, applyOnRelease: true, snap: 50) { "\($0)%" }
    private let frameY = SliderRow("Up – down", 0...100, applyOnRelease: true, snap: 50) { "\($0)%" }

    private var previewOn = UserDefaults.standard.bool(forKey: "preview") {
        didSet { UserDefaults.standard.set(previewOn, forKey: "preview") }
    }

    private static let width: CGFloat = 300

    init(settings: CameraSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let title = NSTextField(labelWithString: "Opal C1")
        title.font = .boldSystemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        retryButton.controlSize = .small
        retryButton.bezelStyle = .recessed
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.isHidden = true
        let header = NSStackView(views: [title, NSView(), status, retryButton])

        for (toggle, action) in [(autoExposure, #selector(autoExposureChanged)), (autoFocus, #selector(autoFocusChanged)),
                                 (autoWhiteBalance, #selector(autoWhiteBalanceChanged))] {
            toggle.controlSize = .small
            toggle.target = self
            toggle.action = action
        }

        bind(shutter, .exposure) { $0.exposureUs = $1 }
        bind(iso, .exposure) { $0.iso = $1 }
        bind(compensation, .exposure) { $0.exposureCompensation = $1 }
        bind(focus, .focus) { $0.lensPosition = $1 }
        bind(temperature, .whiteBalance) { $0.whiteBalanceK = $1 }
        bind(brightness, .image) { $0.brightness = $1 }
        bind(contrast, .image) { $0.contrast = $1 }
        bind(saturation, .image) { $0.saturation = $1 }
        bind(sharpness, .image) { $0.sharpness = $1 }
        bind(denoise, .image) { $0.noiseReduction = $1 }
        bind(colorDenoise, .image) { $0.colorNoiseReduction = $1 }

        flicker.addItems(withTitles: ["Off", "50 Hz", "60 Hz", "Auto"])
        flicker.controlSize = .small
        flicker.target = self
        flicker.action = #selector(flickerChanged)

        zoom.toolTip = "Zooming restarts the camera (about 5 seconds)."
        zoom.onChange = { [weak self] index in
            guard let self else { return }
            self.settings.zoom = CameraSettings.zoomStops[index].percent
            self.updateEnabled()
            self.onRestartNeeded?(self.settings)
        }
        frameX.onChange = { [weak self] value in
            guard let self else { return }
            self.settings.frameX = value
            self.onRestartNeeded?(self.settings)
        }
        frameY.onChange = { [weak self] value in
            guard let self else { return }
            self.settings.frameY = value
            self.onRestartNeeded?(self.settings)
        }
        flipToggle.target = self
        flipToggle.action = #selector(flipToggled)
        flipToggle.toolTip = "Rotates the picture 180°. Restarts the camera (about 5 seconds)."
        micToggle.target = self
        micToggle.action = #selector(micToggled)
        micToggle.toolTip = "Turns on the camera's built-in microphone. When off, \"Opal C1 Audio Mic\" "
            + "still appears but records silence. Restarts the camera (about 5 seconds)."
        previewToggle.target = self
        previewToggle.action = #selector(previewToggled)
        loginToggle.target = self
        loginToggle.action = #selector(loginToggled)
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetClicked))
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let toggles = NSStackView(views: [previewToggle, NSView(), loginToggle])
        let footer = NSStackView(views: [NSView(), reset, quit])

        let version = NSTextField(labelWithString: "C1 Tune \(appVersion) (\(appCommit))")
        version.font = .systemFont(ofSize: 10)
        version.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            header, preview,
            Self.section("Exposure", autoExposure), shutter, iso, compensation,
            Self.section("Focus", autoFocus), focus,
            Self.section("White balance", autoWhiteBalance), temperature,
            Self.section("Framing", nil), zoom, frameX, frameY,
            Self.section("Image", nil), brightness, contrast, saturation, sharpness, denoise, colorDenoise,
            Self.row("Anti-flicker", flicker), NSStackView(views: [flipToggle, NSView(), micToggle]),
            toggles, footer, version,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        stack.setCustomSpacing(12, after: preview)
        for view in [compensation, focus, temperature, frameY, colorDenoise] as [NSView] { stack.setCustomSpacing(14, after: view) }
        stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 4])
        let inner = Self.width - 28
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalToConstant: inner).isActive = true }
        previewHeight = preview.heightAnchor.constraint(equalToConstant: 0)
        previewHeight.isActive = true
        preview.isHidden = true
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        view = stack
        refresh()
        show(currentStatus)
    }

    func replace(_ settings: CameraSettings) {
        self.settings = settings
        refresh()
    }

    func show(_ state: OpalSession.Status) {
        let wasReady = currentStatus == .ready
        currentStatus = state
        switch state {
        case .notConnected: status.stringValue = "Not connected"
        case .starting(let message): status.stringValue = message
        case .ready: status.stringValue = "Ready"
        case .busy: status.stringValue = "In use by another app"
        case .failed(let message): status.stringValue = message
        }
        status.toolTip = status.stringValue
        retryButton.isHidden = { if case .failed = state { return false } else { return true } }()
        previewToggle.isEnabled = state == .ready
        // The webcam re-enumerates whenever the camera restarts, so drop the old capture input.
        if wasReady && state != .ready { preview.reset() }
        if isOpen { showPreview(previewOn) }
    }

    func panelWillShow() {
        isOpen = true
        loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
        showPreview(previewOn)
    }

    func panelDidClose() {
        isOpen = false
        preview.stop()
    }

    // MARK: - Settings ↔ controls

    private func refresh() {
        autoExposure.state = settings.autoExposure ? .on : .off
        autoFocus.state = settings.autoFocus ? .on : .off
        autoWhiteBalance.state = settings.autoWhiteBalance ? .on : .off
        shutter.value = settings.exposureUs
        iso.value = settings.iso
        compensation.value = settings.exposureCompensation
        focus.value = settings.lensPosition
        temperature.value = settings.whiteBalanceK
        brightness.value = settings.brightness
        contrast.value = settings.contrast
        saturation.value = settings.saturation
        sharpness.value = settings.sharpness
        denoise.value = settings.noiseReduction
        colorDenoise.value = settings.colorNoiseReduction
        flicker.selectItem(at: min(max(settings.antiFlicker, 0), 3))
        flipToggle.state = settings.flipped ? .on : .off
        micToggle.state = settings.microphone ? .on : .off
        zoom.value = CameraSettings.zoomStops.firstIndex { $0.percent == CameraSettings.nearestZoom(settings.zoom) } ?? 0
        frameX.value = settings.frameX
        frameY.value = settings.frameY
        updateEnabled()
        previewToggle.state = previewOn ? .on : .off
    }

    private func updateEnabled() {
        shutter.isEnabled = !settings.autoExposure
        iso.isEnabled = !settings.autoExposure
        compensation.isEnabled = settings.autoExposure
        focus.isEnabled = !settings.autoFocus
        temperature.isEnabled = !settings.autoWhiteBalance
        frameX.isEnabled = settings.zoom != 100
        frameY.isEnabled = settings.zoom != 100
    }

    private func bind(_ row: SliderRow, _ group: CameraSettings.Group, _ apply: @escaping (inout CameraSettings, Int) -> Void) {
        row.onChange = { [weak self] value in
            guard let self else { return }
            apply(&self.settings, value)
            self.onChange?(self.settings, group)
        }
    }

    @objc private func autoExposureChanged() {
        settings.autoExposure = autoExposure.state == .on
        updateEnabled()
        onChange?(settings, .exposure)
    }

    @objc private func autoFocusChanged() {
        settings.autoFocus = autoFocus.state == .on
        updateEnabled()
        onChange?(settings, .focus)
    }

    @objc private func autoWhiteBalanceChanged() {
        settings.autoWhiteBalance = autoWhiteBalance.state == .on
        updateEnabled()
        onChange?(settings, .whiteBalance)
    }

    @objc private func flickerChanged() {
        settings.antiFlicker = flicker.indexOfSelectedItem
        onChange?(settings, .antiFlicker)
    }

    @objc private func flipToggled() {
        settings.flipped = flipToggle.state == .on
        onRestartNeeded?(settings)
    }

    @objc private func micToggled() {
        settings.microphone = micToggle.state == .on
        onRestartNeeded?(settings)
    }

    @objc private func previewToggled() {
        previewOn = previewToggle.state == .on
        showPreview(previewOn)
    }

    @objc private func resetClicked() { onReset?() }
    @objc private func retryClicked() { onRetry?() }

    @objc private func loginToggled() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func showPreview(_ on: Bool) {
        guard isViewLoaded else { return }
        previewHeight.constant = on ? (Self.width - 28) * 9 / 16 : 0
        preview.isHidden = !on
        if on && isOpen && currentStatus == .ready { preview.start() } else { preview.stop() }
    }

    private static func section(_ title: String, _ toggle: NSSwitch?) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        guard let toggle else { return label }
        let auto = NSTextField(labelWithString: "Auto")
        auto.font = .systemFont(ofSize: 11)
        auto.textColor = .secondaryLabelColor
        return NSStackView(views: [label, NSView(), auto, toggle])
    }

    private static func row(_ title: String, _ control: NSView) -> NSView {
        NSStackView(views: [NSTextField(labelWithString: title), NSView(), control])
    }
}

/// Title, slider and value for one setting. `nil` shows "Default" (leave the camera's tuning alone).
/// The value label always follows the drag. With `applyOnRelease`, `onChange` fires only when the
/// mouse is released (for settings that restart the camera). With `snap`, values near it stick to
/// it, with a tick mark and a haptic tap, like macOS's own centered sliders.
@MainActor
final class SliderRow: NSStackView {
    var onChange: ((Int) -> Void)?

    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let range: ClosedRange<Int>
    private let step: Int
    private let applyOnRelease: Bool
    private let snap: Int?
    private let snapDistance: Int
    private let format: (Int) -> String
    private var current: Int?
    private var committed: Int?

    init(_ title: String, _ range: ClosedRange<Int>, step: Int = 1, applyOnRelease: Bool = false, snap: Int? = nil,
         format: @escaping (Int) -> String) {
        self.range = range
        self.step = step
        self.applyOnRelease = applyOnRelease
        self.snap = snap
        self.snapDistance = max(step, (range.upperBound - range.lowerBound) * 3 / 100)
        self.format = format
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.widthAnchor.constraint(equalToConstant: 86).isActive = true
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true
        slider.controlSize = .small
        slider.isContinuous = true
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        if snap != nil {
            slider.numberOfTickMarks = 3            // ends and center
            slider.allowsTickMarkValuesOnly = false
        }
        slider.target = self
        slider.action = #selector(moved)
        setViews([titleLabel, slider, valueLabel], in: .leading)
        spacing = 6
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set { slider.isEnabled = newValue }
    }

    var value: Int? {
        get { current }
        set {
            current = newValue
            committed = newValue
            slider.doubleValue = Double(newValue ?? (range.lowerBound + range.upperBound) / 2)
            valueLabel.stringValue = newValue.map(format) ?? "Default"
        }
    }

    @objc private func moved() {
        let steps = ((slider.doubleValue - Double(range.lowerBound)) / Double(step)).rounded()
        var v = min(range.upperBound, range.lowerBound + Int(steps) * step)
        if let snap, abs(v - snap) <= snapDistance {
            if v != snap || current != snap {
                if current != snap { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                slider.doubleValue = Double(snap)
            }
            v = snap
        }
        if v != current {
            current = v
            valueLabel.stringValue = format(v)
        }
        // Mid-drag events only move the label when applying on release.
        let dragging = NSApp.currentEvent?.type == .leftMouseDragged
        guard !(applyOnRelease && dragging), v != committed else { return }
        committed = v
        onChange?(v)
    }
}
