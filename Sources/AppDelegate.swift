import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settings = CameraSettings.load()
    private lazy var panel = ControlPanel(settings: settings)
    private lazy var session = OpalSession(settings: settings)
    private let streamWatcher = StreamWatcher()
    private let log = Logger(subsystem: "com.ryankirkman.c1tune", category: "app")
    private var status = OpalSession.Status.notConnected

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy may drive the camera.
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me }) {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        popover.behavior = .transient
        popover.contentViewController = panel
        popover.delegate = self

        panel.onChange = { [weak self] settings, group in self?.changed(settings, group) }
        panel.onReset = { [weak self] in self?.reset() }
        panel.onRestartNeeded = { [weak self] settings in self?.restartSoon(settings) }
        panel.onRetry = { [weak self] in self?.session.poke() }

        session.onStatus = { [weak self] status in self?.statusChanged(status) }
        session.start()
        streamWatcher.onStart = { [weak self] in self?.session.streamStarted() }
        streamWatcher.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(setFromCommandLine(_:)), name: .init("com.ryankirkman.c1tune.set"), object: nil)
        updateIcon()
    }

    /// Settings sent by `C1Tune --set key=value ...`.
    @objc private func setFromCommandLine(_ note: Notification) {
        let pairs = (note.userInfo as? [String: String]) ?? [:]
        let updated = settings.applying(pairs)
        log.info("--set \(pairs.map { "\($0)=\($1)" }.sorted().joined(separator: " "), privacy: .public)\(updated == self.settings ? " (no change)" : "")")
        guard updated != settings else { return }
        let restart = settings.needsRestart(for: updated)
        settings = updated
        settings.save()
        panel.replace(settings)
        if restart { restartSoon(settings) } else { session.send(CameraSettings.Group.allCases, settings: settings) }
    }

    private var pendingRestart: DispatchWorkItem?

    /// Settings that need a camera restart (zoom, framing, flip, back-to-default) are applied
    /// a moment after the last change, so adjusting them costs one restart, not several.
    private func restartSoon(_ settings: CameraSettings) {
        self.settings = settings
        settings.save()
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.session.restart(settings: self.settings)
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func changed(_ settings: CameraSettings, _ group: CameraSettings.Group) {
        self.settings = settings
        settings.save()
        session.send([group], settings: settings)
    }

    /// Back to defaults. Restarts the camera's pipeline so values without a "default"
    /// command (sharpness, denoise) return to the tuning's own.
    private func reset() {
        settings = CameraSettings()
        settings.save()
        panel.replace(settings)
        session.restart(settings: settings)
    }

    private func statusChanged(_ status: OpalSession.Status) {
        self.status = status
        panel.show(status)
        updateIcon()
    }

    @objc private func didWake() { session.poke() }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)   // so a click elsewhere closes the popover
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            panel.panelWillShow()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        panel.panelDidClose()
    }

    private func updateIcon() {
        statusItem.button?.appearsDisabled = status != .ready
        switch status {
        case .ready: statusItem.button?.toolTip = "Opal C1 ready"
        case .starting(let message): statusItem.button?.toolTip = message
        case .notConnected: statusItem.button?.toolTip = "Opal C1 not connected"
        case .busy: statusItem.button?.toolTip = OpalSession.Status.busyMessage
        case .failed(let message): statusItem.button?.toolTip = message
        }
    }
}
