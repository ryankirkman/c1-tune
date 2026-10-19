import Foundation

/// A minimal XLink host: the link protocol DepthAI devices speak over the vendor bulk
/// interface. Every message is an 84-byte header, plus a payload for writes. A reader
/// thread answers everything the device initiates (stream creation, writes, releases,
/// pings, timesync); `open`, `write` and `read` are blocking and run off the main thread.
final class XLinkConnection: @unchecked Sendable {
    enum ConnectError: Error {
        case notFound
        case busy            // another app holds the camera
        case notListening    // the device didn't accept our first write (e.g. Opal's standalone app)
        case noAnswer        // it accepted the PING but never replied
    }

    private enum Event: Int32 {
        case writeReq = 0, readReq, readRelReq, createStreamReq, closeStreamReq, pingReq, resetReq
        case writeResp = 8, readResp, readRelResp, createStreamResp, closeStreamResp, pingResp, resetResp
    }

    private struct Header {
        var id: Int32 = 0
        var type: Int32 = 0
        var name = ""
        var streamId: UInt32 = 0
        var size: UInt32 = 0
        var flags: UInt32 = 1     // ack

        static let length = 84

        func encoded() -> Data {
            var d = Data(count: Header.length)
            d.withUnsafeMutableBytes { b in
                b.storeBytes(of: id.littleEndian, toByteOffset: 0, as: Int32.self)
                b.storeBytes(of: type.littleEndian, toByteOffset: 4, as: Int32.self)
                for (i, c) in name.utf8.prefix(63).enumerated() { b[8 + i] = c }
                b.storeBytes(of: streamId.littleEndian, toByteOffset: 72, as: UInt32.self)
                b.storeBytes(of: size.littleEndian, toByteOffset: 76, as: UInt32.self)
                b.storeBytes(of: flags.littleEndian, toByteOffset: 80, as: UInt32.self)
            }
            return d
        }

        init() {}

        init(_ b: UnsafeRawBufferPointer) {
            id = b.loadUnaligned(fromByteOffset: 0, as: Int32.self)
            type = b.loadUnaligned(fromByteOffset: 4, as: Int32.self)
            name = String(decoding: b[8..<72].prefix { $0 != 0 }, as: UTF8.self)
            streamId = b.loadUnaligned(fromByteOffset: 72, as: UInt32.self)
            size = b.loadUnaligned(fromByteOffset: 76, as: UInt32.self)
            flags = b.loadUnaligned(fromByteOffset: 80, as: UInt32.self)
        }
    }

    private static let maxPayload: UInt32 = 64 << 20

    private let pipe: USBPipe
    private let onLog: (@Sendable (String) -> Void)?
    private let sendLock = NSLock()
    private let state = NSCondition()          // guards everything below
    private var outstanding: Set<Int32> = []   // ids of our requests still waiting for a response
    private var responses: [Int32: Header] = [:]
    private var nextId: Int32 = 0x0B
    private var streams: [String: UInt32] = [:]
    private var hostStreams: Set<UInt32> = []  // streams we opened; only these queue packets
    private var packets: [UInt32: [Data]] = [:]
    private var running = true
    private var alive = true
    private let readerDone = DispatchSemaphore(value: 0)

    var isAlive: Bool { state.withLock { alive && running } }

    /// Opens interface 0 of the device in this boot stage and handshakes with a PING.
    static func connect(_ pid: OpalPID, pingTimeout: TimeInterval = 3,
                        onLog: (@Sendable (String) -> Void)? = nil) -> Result<XLinkConnection, ConnectError> {
        switch USBPipe.open(pid) {
        case .failure(.notFound): return .failure(.notFound)
        case .failure(.busy): return .failure(.busy)
        case .failure: return .failure(.notListening)
        case .success(let pipe):
            let link = XLinkConnection(pipe: pipe, onLog: onLog)
            var ping = Header()
            ping.type = Event.pingReq.rawValue
            switch link.exchange(ping, timeout: pingTimeout) {
            case .response: return .success(link)
            case .sendFailed: link.close(); return .failure(.notListening)
            case .timedOut: link.close(); return .failure(.noAnswer)
            }
        }
    }

    private init(pipe: USBPipe, onLog: (@Sendable (String) -> Void)?) {
        self.pipe = pipe
        self.onLog = onLog
        let thread = Thread { [self] in readLoop() }
        thread.name = "XLink reader"
        thread.start()
    }

    /// Stops the reader and releases the interface. Never sends a reset, so the
    /// device keeps running whatever it's running.
    func close() {
        let wasRunning = state.withLock {
            defer { running = false; state.broadcast() }
            return running
        }
        guard wasRunning else { return }
        pipe.abortRead()
        readerDone.wait()
        pipe.close()
    }

    /// Writes the 4-byte keepalive on `stream` every 500 ms on its own thread until the link
    /// closes. Separate from everything else so slow RPCs can never starve it.
    func feedWatchdog(_ stream: UInt32) {
        let thread = Thread { [self] in
            let keepalive = Data([0, 0, 0, 0])
            while isAlive {
                _ = write(stream, keepalive, timeout: 1)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.name = "XLink watchdog"
        thread.start()
    }

    /// Asks the device to reboot (it comes back running its standalone app).
    func reset() {
        var h = Header()
        h.id = nextRequestId()
        h.type = Event.resetReq.rawValue
        _ = send(h)
    }

    /// Creates (or joins) a named stream; returns the id the device uses for it.
    func open(_ name: String, size: UInt32) -> UInt32? {
        let local = state.withLock { () -> UInt32 in
            let id = streams[name] ?? Self.freeId(in: streams)
            streams[name] = id
            return id
        }
        var h = Header()
        h.type = Event.createStreamReq.rawValue
        h.name = name
        h.streamId = local
        h.size = (size + 63) & ~63
        guard case .response(let r) = exchange(h, timeout: 3), r.flags & 1 == 1 else { return nil }
        state.withLock {
            streams[name] = r.streamId
            hostStreams.insert(r.streamId)
        }
        return r.streamId
    }

    /// Writes one packet and waits for the device to acknowledge it.
    @discardableResult
    func write(_ stream: UInt32, _ data: Data, timeout: TimeInterval = 3) -> Bool {
        var h = Header()
        h.type = Event.writeReq.rawValue
        h.streamId = stream
        h.size = UInt32(data.count)
        guard case .response(let r) = exchange(h, payload: data, timeout: timeout) else { return false }
        return r.flags & 1 == 1
    }

    /// Next packet the device wrote on `stream`, or nil on timeout or a dropped link.
    func read(_ stream: UInt32, timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        state.lock()
        defer { state.unlock() }
        while packets[stream, default: []].isEmpty {
            guard alive, running, state.wait(until: deadline) else { return nil }
        }
        return packets[stream]!.removeFirst()
    }

    // MARK: - Requests

    private enum Outcome { case response(Header), sendFailed, timedOut }

    private func exchange(_ header: Header, payload: Data? = nil, timeout: TimeInterval) -> Outcome {
        var h = header
        h.id = nextRequestId()
        state.withLock { _ = outstanding.insert(h.id) }
        guard send(h, payload, timeout: timeout) else {
            state.withLock { _ = outstanding.remove(h.id) }
            markDead()
            return .sendFailed
        }
        let deadline = Date().addingTimeInterval(timeout)
        state.lock()
        defer { state.unlock() }
        while responses[h.id] == nil {
            guard alive, running, state.wait(until: deadline) else {
                outstanding.remove(h.id)
                return .timedOut
            }
        }
        outstanding.remove(h.id)
        return .response(responses.removeValue(forKey: h.id)!)
    }

    private func send(_ h: Header, _ payload: Data? = nil, timeout: TimeInterval = 3) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard pipe.write(h.encoded(), timeoutMs: 2000) else { return false }
        if let payload, !payload.isEmpty {
            return pipe.write(payload, timeoutMs: UInt32(max(2, timeout) * 1000))
        }
        return true
    }

    private func nextRequestId() -> Int32 {
        state.withLock {
            let id = nextId
            nextId = nextId == Int32.max ? 0x0B : nextId + 1
            return id
        }
    }

    private static func freeId(in streams: [String: UInt32]) -> UInt32 {
        let used = Set(streams.values)
        return (0..<32).first { !used.contains($0) } ?? 31
    }

    private func markDead() {
        state.withLock {
            alive = false
            state.broadcast()
        }
    }

    // MARK: - Reader thread

    private func readLoop() {
        defer { readerDone.signal() }
        var headerBytes = [UInt8](repeating: 0, count: Header.length)
        var payload = [UInt8](repeating: 0, count: 1 << 20)
        var failures = 0
        while state.withLock({ running }) {
            // Block until the device sends something; close() aborts the read.
            let result = headerBytes.withUnsafeMutableBytes { pipe.read(into: $0.baseAddress!, count: Header.length, timeoutMs: 0) }
            switch result {
            case .aborted: return
            case .timeout: continue
            case .failed:
                failures += 1
                if failures > 5 { markDead(); return }
                continue
            case .data(let n):
                failures = 0
                guard n == Header.length else { continue }   // zero-length packet
            }
            let h = headerBytes.withUnsafeBytes { Header($0) }
            // Anything that isn't a plausible header means we've lost sync with the device.
            // Only writes carry a payload; other events can have stale size fields.
            guard (0...14).contains(h.type), h.type != 7,
                  h.type != Event.writeReq.rawValue || h.size <= Self.maxPayload else { markDead(); return }

            var body = Data()
            if h.type == Event.writeReq.rawValue, h.size > 0 {
                if payload.count < Int(h.size) { payload = [UInt8](repeating: 0, count: Int(h.size)) }
                var got = 0
                while got < Int(h.size) {
                    let r = payload.withUnsafeMutableBytes { pipe.read(into: $0.baseAddress! + got, count: Int(h.size) - got, timeoutMs: 3000) }
                    guard case .data(let m) = r else { markDead(); return }
                    got += m
                }
                body = Data(payload[0..<got])
            }
            handle(h, body)
        }
    }

    private func handle(_ h: Header, _ body: Data) {
        if h.type >= Event.writeResp.rawValue {
            state.withLock {
                // Keep only responses someone is waiting for (not e.g. READ_REL_RESP to our releases).
                if outstanding.contains(h.id) {
                    responses[h.id] = h
                    state.broadcast()
                }
            }
            return
        }
        guard let event = Event(rawValue: h.type) else { return }
        var reply = Header()
        reply.id = h.id
        reply.type = h.type + 8
        switch event {
        case .writeReq:
            reply.streamId = h.streamId
            reply.size = h.size
            guard send(reply) else { markDead(); return }
            deviceWrote(h.streamId, body)
            var release = Header()
            release.id = nextRequestId()
            release.type = Event.readRelReq.rawValue
            release.streamId = h.streamId
            release.size = h.size
            _ = send(release)
        case .createStreamReq:
            let id = state.withLock { () -> UInt32 in
                let id = streams[h.name] ?? Self.freeId(in: streams)
                streams[h.name] = id
                return id
            }
            reply.name = h.name
            reply.size = h.size
            reply.streamId = id
            _ = send(reply)
        case .closeStreamReq:
            reply.streamId = h.streamId
            _ = send(reply)
        case .readRelReq, .pingReq, .resetReq:
            _ = send(reply)
        default:
            break
        }
    }

    private func deviceWrote(_ stream: UInt32, _ data: Data) {
        let (name, queued) = state.withLock {
            (streams.first { $0.value == stream }?.key ?? "", hostStreams.contains(stream))
        }
        switch name {
        case "__timesync":
            // Answer with our steady clock as {int64 sec, int64 nsec}.
            var ts = timespec()
            clock_gettime(CLOCK_MONOTONIC, &ts)
            var reply = Data()
            withUnsafeBytes(of: Int64(ts.tv_sec).littleEndian) { reply.append(contentsOf: $0) }
            withUnsafeBytes(of: Int64(ts.tv_nsec).littleEndian) { reply.append(contentsOf: $0) }
            var h = Header()
            h.id = nextRequestId()
            h.type = Event.writeReq.rawValue
            h.streamId = stream
            h.size = UInt32(reply.count)
            _ = send(h, reply)
        case "__log":
            let text = String(decoding: data.map { (32..<127).contains($0) ? $0 : 32 }, as: UTF8.self)
            onLog?(text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
        default:
            guard queued else { return }   // nobody will read it; already acknowledged and released
            state.withLock {
                packets[stream, default: []].append(data)
                state.broadcast()
            }
        }
    }
}
