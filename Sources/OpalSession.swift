import Foundation
import os

/// Keeps the Opal C1 running our pipeline and delivers control messages to it.
///
/// Out of the box the camera runs a standalone app that ignores control requests. When it
/// shows up like that, the session reboots it into its bootloader, has that drop to the
/// chip's USB boot ROM, uploads DepthAI firmware (taken from Opal Composer) with UVC on and
/// a 1080p-only webcam format, then starts a pipeline: camera (with Opal's tuning) → webcam
/// output, plus a "control" input. A keepalive thread feeds the camera's watchdog; if this
/// app quits, the camera resets to its standalone webcam after about 1.5 s.
///
/// All work happens on one serial queue; status changes are reported on the main queue.
final class OpalSession: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case notConnected
        case starting(String)
        case ready
        case busy                 // another app (e.g. Opal Composer) is using the camera
        case failed(String)
    }

    var onStatus: (@MainActor @Sendable (Status) -> Void)?

    private let queue = DispatchQueue(label: "com.ryankirkman.c1tune.session")
    private let log = Logger(subsystem: "com.ryankirkman.c1tune", category: "session")
    private var link: XLinkConnection?            // everything below is on `queue`
    private var rpcStream: UInt32 = 0
    private var controlStream: UInt32?
    private var settings: CameraSettings
    private var timer: DispatchSourceTimer?
    private var lastStatus: Status?
    private var failures = 0
    private var retryAfter = Date.distantPast
    private var wasPresent = false

    private let pendingLock = NSLock()
    private var pending: [CameraSettings.Group: CameraControl] = [:]   // guarded by pendingLock

    private static let maxFailures = 4

    init(settings: CameraSettings) {
        self.settings = settings
    }

    /// Starts watching for the camera. Checks every 1.5 s; costs nothing while idle.
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.5, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Sends commands for these groups as soon as the camera is ready, and remembers the
    /// settings for the next start. Rapid calls keep only the newest message per group.
    func send(_ groups: [CameraSettings.Group], settings: CameraSettings) {
        pendingLock.withLock {
            for group in groups { pending[group] = settings.control(for: group) }
        }
        queue.async { [self] in
            self.settings = settings
            flush()
        }
    }

    /// An app just started the webcam. The camera drops control messages while its sensor
    /// is idle, so send every setting again once it's running.
    func streamStarted() {
        for delay in [0.8, 2.5] {
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                pendingLock.withLock {
                    for group in CameraSettings.Group.allCases { pending[group] = settings.control(for: group) }
                }
                flush()
            }
        }
    }

    /// Re-checks the camera now, e.g. after the Mac wakes or the user taps Retry.
    func poke() {
        queue.async { [self] in
            failures = 0
            retryAfter = .distantPast
            tick()
        }
    }

    /// Restarts the camera so the pipeline is rebuilt from the current settings
    /// (needed to return sharpness and denoise to the tuning's defaults).
    func restart(settings: CameraSettings) {
        queue.async { [self] in
            self.settings = settings
            pendingLock.withLock { pending.removeAll() }
            guard let link else { return }
            report(.starting("Restarting camera…"))
            link.close()
            self.link = nil
            controlStream = nil
            // Straight to the bootloader (≈5 s to a fresh pipeline); an XLink reset would wait
            // for the standalone app to boot first (≈14 s).
            USB.deviceRequest(.booted, type: 0x00, request: 0xF5, value: 0x0DA1, index: 0)
            retryAfter = Date().addingTimeInterval(0.5)
        }
    }

    // MARK: - Queue

    private func flush() {
        guard let link, let controlStream else { return }
        let batch = pendingLock.withLock { () -> [CameraControl] in
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        guard !batch.isEmpty else { return }
        // Each group sets its own commands, so they combine without conflicts.
        var merged = CameraControl()
        for c in batch { merged.absorb(c) }
        if !link.write(controlStream, merged.encoded(), timeout: 2) {
            log.error("control write failed")
        }
    }

    private func tick() {
        if let link {
            if link.isAlive { return }
            log.notice("camera link lost")
            link.close()
            self.link = nil
            controlStream = nil
        }
        let present = USB.isPresent(.booted) || USB.isPresent(.bootloader) || USB.isPresent(.rom)
        if present && !wasPresent { failures = 0; retryAfter = .distantPast }   // plugged in: start over
        wasPresent = present
        guard present else {
            report(.notConnected)
            return
        }
        guard Date() >= retryAfter, failures < Self.maxFailures else { return }
        do {
            try connect()
            failures = 0
            report(.ready)
            pendingLock.withLock {
                for group in CameraSettings.Group.allCases where pending[group] == nil {
                    pending[group] = settings.control(for: group)
                }
            }
            flush()
        } catch Busy.busy {
            retryAfter = Date().addingTimeInterval(5)
            report(.busy)
        } catch {
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
            link?.close()
            link = nil
            controlStream = nil
            failures += 1
            retryAfter = Date().addingTimeInterval([3, 10, 30, 60][min(failures - 1, 3)])
            report(failures >= Self.maxFailures ? .failed(error.localizedDescription) : .starting("Retrying…"))
        }
    }

    private func report(_ status: Status) {
        guard status != lastStatus else { return }
        lastStatus = status
        let handler = onStatus
        DispatchQueue.main.async { handler?(status) }
    }

    // MARK: - Connect or boot

    private enum Busy: Error { case busy }

    struct StartError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func connect() throws {
        let logDevice: @Sendable (String) -> Void = { [log] text in log.info("device: \(text, privacy: .public)") }

        if USB.isPresent(.booted) {
            // Our firmware answers XLink; Opal's standalone app doesn't accept the first write.
            var result = XLinkConnection.connect(.booted, pingTimeout: 3, onLog: logDevice)
            if case .failure(.noAnswer) = result {
                result = XLinkConnection.connect(.booted, pingTimeout: 3, onLog: logDevice)
            }
            switch result {
            case .success(let existing):
                do {
                    try attach(existing, freshBoot: false)
                    return
                } catch {
                    log.error("reattach failed, rebooting camera: \(error.localizedDescription, privacy: .public)")
                    existing.close()
                    link = nil
                }
            case .failure(.busy):
                throw Busy.busy
            case .failure:
                break
            }
        }

        report(.starting("Starting camera…"))
        var firmware = try Firmware.load()
        BootImage.patchFrameSizes(&firmware)

        if USB.isPresent(.booted) {
            // Ask whatever firmware is running to reboot into the bootloader.
            USB.deviceRequest(.booted, type: 0x00, request: 0xF5, value: 0x0DA1, index: 0)
            guard USB.wait(for: .bootloader, timeout: 6) else { throw StartError("The camera didn't restart into its bootloader.") }
        }
        if USB.isPresent(.bootloader) {
            let bootloader = try retrying("Couldn't talk to the camera's bootloader.") { XLinkConnection.connect(.bootloader) }
            if let watchdog = bootloader.open("__watchdog", size: 64) {
                bootloader.write(watchdog, Data([0, 0, 0, 0]), timeout: 1)          // keepalive
            }
            if let stream = bootloader.open("__bootloader", size: 5 << 20) {
                bootloader.write(stream, Data([0, 0, 0, 0]), timeout: 2)          // USB_ROM_BOOT
            }
            bootloader.close()
            guard USB.wait(for: .rom, timeout: 6) else { throw StartError("The camera didn't enter USB boot mode.") }
        }
        if USB.isPresent(.rom) {
            let rom = try retrying("Couldn't open the camera in USB boot mode.") { USBPipe.open(.rom) }
            // Default watchdog (fed from our keepalive thread); 0 makes the firmware reset when video starts.
            try upload(BootImage.image(firmware: firmware, config: BootImage.boardConfig(watchdogMs: nil, uvc: true)), to: rom)
            rom.close()
            guard USB.wait(for: .booted, timeout: 10) else { throw StartError("The camera didn't come back after loading firmware.") }
        }
        let connection = try retrying("Couldn't connect to the camera after loading firmware.", attempts: 20) {
            XLinkConnection.connect(.booted, onLog: logDevice)
        }
        try attach(connection, freshBoot: true)
    }

    /// Retries `open` every 250 ms; the device takes a moment to register its interfaces.
    private func retrying<T, E: Error>(_ message: String, attempts: Int = 12, _ open: () -> Result<T, E>) throws -> T {
        for _ in 0..<attempts {
            if case .success(let value) = open() { return value }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw StartError(message)
    }

    private func upload(_ image: Data, to pipe: USBPipe) throws {
        let chunk = 1 << 20
        var offset = 0
        try image.withUnsafeBytes { all in
            while offset < image.count {
                let n = min(chunk, image.count - offset)
                guard pipe.write(UnsafeRawBufferPointer(rebasing: all[offset..<offset + n]), timeoutMs: 2000) else {
                    throw StartError("Firmware upload failed.")
                }
                offset += n
            }
        }
        if image.count % 512 == 0 { _ = pipe.write(Data(), timeoutMs: 2000) }   // zero-length packet ends the transfer
    }

    private func attach(_ connection: XLinkConnection, freshBoot: Bool) throws {
        link = connection
        if let watchdog = connection.open("__watchdog", size: 128) { connection.feedWatchdog(watchdog) }
        guard let rpc = connection.open("__rpc_main", size: 5 << 20),
              let control = connection.open("control", size: 5 << 20)
        else { throw StartError("Couldn't open the camera's control channels.") }
        rpcStream = rpc

        if !freshBoot {
            let running = try call("isPipelineRunning")
            guard running.last == 0xC3 else { throw StartError("The camera's pipeline isn't running.") }
            controlStream = control
            return
        }

        report(.starting("Configuring camera…"))
        let camera = settings.pipelineCamera()
        let sensors = (try? call("getCameraSensorNames")) ?? Data()
        let tuning = Firmware.tuningBlob(sensorReply: sensors)
        if tuning == nil { log.error("Opal tuning file not found; using the firmware's defaults") }
        try call("setPipelineSchema", raw: Pipeline.setPipelineSchemaRequest(
            camera: camera, mic: settings.pipelineMic, tuningBlobUri: tuning == nil ? "" : Assets.tuningUri, tuningBlobSize: tuning?.count))
        if let tuning { try uploadAsset(tuning) }
        let built = [UInt8](try call("buildPipeline"))
        // Reply is [1, 2, 1, [ok, message]]: 94 01 02 01 92 C3|C2 <string>.
        guard built.count >= 6, built[4] == 0x92, built[5] == 0xC3 else {
            let message = String(decoding: built.dropFirst(6).filter { (32..<127).contains($0) }, as: UTF8.self)
            throw StartError("The camera rejected the pipeline: \(message)")
        }
        try call("startPipeline")
        controlStream = control
    }

    /// setAssets → memAlloc → readFromXLink (with the blob on its stream) → setAssetStorage.
    private func uploadAsset(_ blob: Data) throws {
        guard let link else { return }
        try call("setAssets", [Assets.tuning(size: blob.count)])
        let alloc = try call("memAlloc", [.int(Int64(blob.count))])
        guard let handle = Self.trailingUInt(alloc), handle != 0 else {
            throw StartError("The camera didn't allocate memory for the tuning file.")
        }
        // Open the data stream before asking the camera to read from it.
        guard let storage = link.open("__stream_asset_storage", size: 5 << 20) else { throw StartError("Tuning upload failed.") }
        let request = RPC.request("readFromXLink", args: [.string("__stream_asset_storage"), .int(Int64(handle)), .int(Int64(blob.count))])
        guard link.write(rpcStream, request), link.write(storage, blob, timeout: 10) else { throw StartError("Tuning upload failed.") }
        guard let reply = link.read(rpcStream, timeout: 15), RPC.succeeded(reply) else { throw StartError("Tuning upload wasn't accepted.") }
        try call("setAssetStorage", [.int(Int64(handle)), .int(Int64(blob.count))])
    }

    @discardableResult
    private func call(_ name: String, _ args: [MsgPack] = [], raw: Data? = nil) throws -> Data {
        guard let link else { throw StartError("Camera disconnected.") }
        guard link.write(rpcStream, raw ?? RPC.request(name, args: args)),
              let reply = link.read(rpcStream, timeout: 15)
        else { throw StartError("The camera didn't answer \(name).") }
        guard RPC.succeeded(reply) else {
            let message = String(decoding: reply.dropFirst(4).filter { (32..<127).contains($0) }, as: UTF8.self)
            throw StartError("\(name) failed: \(message)")
        }
        return reply
    }

    /// The unsigned integer a reply ends with (msgpack uint of any width).
    static func trailingUInt(_ reply: Data) -> UInt64? {
        let b = [UInt8](reply)
        guard b.count >= 5 else { return nil }
        let v = Array(b[4...])
        switch v[0] {
        case 0x00...0x7F: return UInt64(v[0])
        case 0xCC where v.count >= 2: return UInt64(v[1])
        case 0xCD where v.count >= 3: return v[1...2].reduce(0) { $0 << 8 | UInt64($1) }
        case 0xCE where v.count >= 5: return v[1...4].reduce(0) { $0 << 8 | UInt64($1) }
        case 0xCF where v.count >= 9: return v[1...8].reduce(0) { $0 << 8 | UInt64($1) }
        default: return nil
        }
    }
}
