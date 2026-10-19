import Compression
import Foundation

// Wire formats for the DepthAI firmware Opal ships (device side 26f3d765, depthai-shared
// 12dc4c5): libnop for messages and node properties, msgpack for RPC, and a preboot
// header that carries the board config in front of the firmware image.

/// libnop encoder: a prefix byte then little-endian payload, always the smallest encoding.
struct Nop {
    private(set) var bytes: [UInt8] = []

    mutating func uint(_ v: UInt64) {
        switch v {
        case 0..<0x80: bytes.append(UInt8(v))
        case 0..<0x100: bytes += [0x80, UInt8(v)]
        case 0..<0x10000: bytes.append(0x81); le(UInt16(v))
        case 0..<0x1_0000_0000: bytes.append(0x82); le(UInt32(v))
        default: bytes.append(0x83); le(v)
        }
    }

    mutating func int(_ v: Int64) {
        switch v {
        case -64..<0x80: bytes.append(UInt8(bitPattern: Int8(v)))
        case Int64(Int8.min)...Int64(Int8.max): bytes += [0x84, UInt8(bitPattern: Int8(v))]
        case Int64(Int16.min)...Int64(Int16.max): bytes.append(0x85); le(Int16(v))
        case Int64(Int32.min)...Int64(Int32.max): bytes.append(0x86); le(Int32(v))
        default: bytes.append(0x87); le(v)
        }
    }

    mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    mutating func float(_ v: Float) { bytes.append(0x88); le(v.bitPattern) }
    mutating func structure(_ members: Int) { bytes += [0xB9, UInt8(members)] }
    mutating func string(_ s: String) { bytes.append(0xBD); uint(UInt64(s.utf8.count)); bytes += Array(s.utf8) }
    mutating func emptyMap() { bytes += [0xBB, 0x00] }
    mutating func intMap(_ m: [(Int64, Int64)]) {
        bytes.append(0xBB); uint(UInt64(m.count))
        for (k, v) in m { int(k); int(v) }
    }
    mutating func emptyArray() { bytes += [0xBA, 0x00] }
    mutating func none() { bytes.append(0xBE) }      // empty tl::optional

    private mutating func le<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { bytes += $0 }
    }
}

/// msgpack value, encoded the way nlohmann::json::to_msgpack does: object keys sorted,
/// floats as float32 when that's exact.
indirect enum MsgPack {
    case null, bool(Bool), int(Int64), float(Double), string(String), array([MsgPack]), object([String: MsgPack])
    case raw([UInt8])   // pre-encoded bytes

    func encoded() -> [UInt8] { var out: [UInt8] = []; encode(into: &out); return out }

    private func encode(into out: inout [UInt8]) {
        switch self {
        case .null: out.append(0xC0)
        case .bool(let b): out.append(b ? 0xC3 : 0xC2)
        case .int(let v): Self.int(v, &out)
        case .float(let v):
            if Double(Float(v)) == v { out.append(0xCA); Self.be(Float(v).bitPattern, &out) }
            else { out.append(0xCB); Self.be(v.bitPattern, &out) }
        case .string(let s):
            let n = s.utf8.count
            if n < 32 { out.append(0xA0 | UInt8(n)) }
            else if n < 0x100 { out += [0xD9, UInt8(n)] }
            else { out.append(0xDA); Self.be(UInt16(n), &out) }
            out += Array(s.utf8)
        case .array(let items):
            Self.header(items.count, fix: 0x90, b16: 0xDC, &out)
            items.forEach { $0.encode(into: &out) }
        case .object(let dict):
            Self.header(dict.count, fix: 0x80, b16: 0xDE, &out)
            for key in dict.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                MsgPack.string(key).encode(into: &out)
                dict[key]!.encode(into: &out)
            }
        case .raw(let b): out += b
        }
    }

    private static func int(_ v: Int64, _ out: inout [UInt8]) {
        if v >= 0 {
            switch v {
            case 0..<0x80: out.append(UInt8(v))
            case 0..<0x100: out += [0xCC, UInt8(v)]
            case 0..<0x10000: out.append(0xCD); be(UInt16(v), &out)
            case 0..<0x1_0000_0000: out.append(0xCE); be(UInt32(v), &out)
            default: out.append(0xCF); be(UInt64(v), &out)
            }
        } else {
            switch v {
            case -32..<0: out.append(UInt8(bitPattern: Int8(v)))
            case Int64(Int8.min)...: out += [0xD0, UInt8(bitPattern: Int8(v))]
            case Int64(Int16.min)...: out.append(0xD1); be(Int16(v), &out)
            case Int64(Int32.min)...: out.append(0xD2); be(Int32(v), &out)
            default: out.append(0xD3); be(v, &out)
            }
        }
    }

    private static func header(_ n: Int, fix: UInt8, b16: UInt8, _ out: inout [UInt8]) {
        if n < 16 { out.append(fix | UInt8(n)) } else { out.append(b16); be(UInt16(n), &out) }
    }

    private static func be<T: FixedWidthInteger>(_ v: T, _ out: inout [UInt8]) {
        withUnsafeBytes(of: v.bigEndian) { out += $0 }
    }
}

// MARK: - Camera control

/// DepthAI RawCameraControl. `encoded()` is the XLinkIn payload: libnop metadata, then
/// int32 datatype (5 = CameraControl in this firmware) and uint32 metadata size.
struct CameraControl: Sendable, Equatable {
    enum Command: Int {
        case startStream = 1, stopStream = 2, moveLens = 4, afTrigger = 5, aeManual = 6, aeAuto = 7,
             awbMode = 8, sceneMode = 9, antiBanding = 10, expCompensation = 11, aeLock = 13, awbLock = 16,
             effect = 24, afMode = 26, lumaDenoiseOld = 27, saturation = 28, brightness = 31, sharpness = 35,
             contrast = 44, aeRegion = 45, afRegion = 46, lumaDenoise = 47, chromaDenoise = 48, wbColorTemp = 49,
             afLensRange = 51
    }
    enum AutoFocus: UInt8 { case off = 0, auto = 1, macro = 2, continuousVideo = 3, continuousPicture = 4 }
    enum WhiteBalance: UInt8 { case off = 0, auto = 1 }
    enum AntiBanding: UInt8 { case off = 0, hz50 = 1, hz60 = 2, auto = 3 }

    var cmdMask: UInt64 = 0
    var autoFocusMode = AutoFocus.continuousVideo
    var lensPosition: UInt8 = 0
    var lensPosAutoInfinity: UInt8 = 0
    var lensPosAutoMacro: UInt8 = 0
    var lensPosLimitMin: UInt8 = 0
    var lensPosLimitMax: UInt8 = 255
    var exposureTimeUs: UInt32 = 0
    var sensitivityIso: UInt32 = 0
    var frameDurationUs: UInt32 = 0
    var awbMode = WhiteBalance.off
    var antiBandingMode = AntiBanding.off
    var expCompensation: Int8 = 0
    var brightness: Int8 = 0
    var contrast: Int8 = 0
    var saturation: Int8 = 0
    var sharpness: UInt8 = 0
    var lumaDenoise: UInt8 = 0
    var chromaDenoise: UInt8 = 0
    var wbColorTemp: UInt16 = 0

    mutating func set(_ c: Command) { cmdMask |= 1 << UInt64(c.rawValue) }

    func has(_ c: Command) -> Bool { cmdMask & (1 << UInt64(c.rawValue)) != 0 }

    /// Adds another message's commands (and their values) to this one.
    mutating func absorb(_ o: CameraControl) {
        cmdMask |= o.cmdMask
        if o.has(.afMode) { autoFocusMode = o.autoFocusMode }
        if o.has(.moveLens) { lensPosition = o.lensPosition }
        if o.has(.aeManual) { exposureTimeUs = o.exposureTimeUs; sensitivityIso = o.sensitivityIso; frameDurationUs = o.frameDurationUs }
        if o.has(.expCompensation) { expCompensation = o.expCompensation }
        if o.has(.awbMode) { awbMode = o.awbMode }
        if o.has(.wbColorTemp) { wbColorTemp = o.wbColorTemp }
        if o.has(.antiBanding) { antiBandingMode = o.antiBandingMode }
        if o.has(.brightness) { brightness = o.brightness }
        if o.has(.contrast) { contrast = o.contrast }
        if o.has(.saturation) { saturation = o.saturation }
        if o.has(.sharpness) { sharpness = o.sharpness }
        if o.has(.lumaDenoise) { lumaDenoise = o.lumaDenoise }
        if o.has(.chromaDenoise) { chromaDenoise = o.chromaDenoise }
    }

    /// libnop RawCameraControl, 29 members in the firmware's order.
    func nop() -> [UInt8] {
        var n = Nop()
        n.structure(29)
        n.uint(cmdMask)
        n.uint(UInt64(autoFocusMode.rawValue)); n.uint(UInt64(lensPosition))
        n.uint(UInt64(lensPosAutoInfinity)); n.uint(UInt64(lensPosAutoMacro))
        n.uint(UInt64(lensPosLimitMin)); n.uint(UInt64(lensPosLimitMax))
        n.structure(3); n.uint(UInt64(exposureTimeUs)); n.uint(UInt64(sensitivityIso)); n.uint(UInt64(frameDurationUs))
        for _ in 0..<2 { n.structure(5); for _ in 0..<5 { n.uint(0) } }        // aeRegion, afRegion
        n.uint(UInt64(awbMode.rawValue)); n.uint(0); n.uint(UInt64(antiBandingMode.rawValue))  // awb, scene, antibanding
        n.bool(false); n.bool(false)                                          // aeLock, awbLock
        n.uint(0); n.uint(0); n.uint(0); n.uint(0)                            // captureIntent, controlMode, effect, frameSync
        n.int(Int64(expCompensation)); n.int(Int64(brightness)); n.int(Int64(contrast)); n.int(Int64(saturation))
        n.uint(UInt64(sharpness)); n.uint(UInt64(lumaDenoise)); n.uint(UInt64(chromaDenoise))
        n.uint(UInt64(wbColorTemp))
        n.uint(0); n.uint(0)                                                  // lowPower burst/discard
        return n.bytes
    }

    func encoded() -> Data {
        let meta = nop()
        var d = Data(meta)
        withUnsafeBytes(of: Int32(5).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(meta.count).littleEndian) { d.append(contentsOf: $0) }
        return d
    }
}

// MARK: - Boot image

enum BootImage {
    /// libnop BoardConfig: default USB ids, UVC on, and optionally the watchdog off so the
    /// camera keeps running if this app quits.
    static func boardConfig(watchdogMs: UInt32?, uvc: Bool) -> [UInt8] {
        var n = Nop()
        n.structure(8)
        n.structure(5); n.uint(0x03E7); n.uint(0xF63B); n.uint(0x03E7); n.uint(0xF63D); n.int(4)   // usb, SUPER speed
        n.structure(1); n.uint(0)                                                                  // network mtu
        n.emptyArray()                                                                             // sysctl
        if let watchdogMs { n.uint(UInt64(watchdogMs)) } else { n.none() }
        n.none()                                                                                   // watchdogInitialDelayMs
        n.emptyMap(); n.emptyMap()                                                                 // gpio, uart
        if uvc { n.bool(true) } else { n.none() }
        return n.bytes
    }

    /// Makes the webcam advertise only 1920x1080. The firmware picks its output size from the
    /// frame *index* the Mac requests (1 = 4K, 2 = 1440p, 3 = 1080p, 4 = 720p) and only streams
    /// when that matches the pipeline, so every frame descriptor is rewritten to describe the
    /// 1080p entry (same index, size and buffer). Any app then gets 1080p; macOS scales it if
    /// the app wants less. Patches each copy (USB 2 and USB 3); returns how many entries changed.
    @discardableResult
    static func patchFrameSizes(_ firmware: inout Data) -> Int {
        // NV12 uncompressed format descriptor (subtype 0x04); 4 frame descriptors follow it.
        let format = Data([0x1B, 0x24, 0x04, 0x01, 0x04, 0x4E, 0x56, 0x31, 0x32])
        let size = 0x1E
        var patched = 0
        var search = firmware.startIndex
        while let r = firmware.range(of: format, in: search..<firmware.endIndex) {
            search = r.upperBound
            let first = r.lowerBound + 0x1B
            var frames: [Int] = []
            for index in 1...4 {
                let f = first + (index - 1) * size
                guard f + size <= firmware.endIndex, firmware[f] == 0x1E, firmware[f + 1] == 0x24,
                      firmware[f + 2] == 0x05, firmware[f + 3] == UInt8(index) else { break }
                frames.append(f)
            }
            // The 1080p entry: width 0x0780, height 0x0438.
            guard let source = frames.first(where: { firmware[$0 + 5] == 0x80 && firmware[$0 + 6] == 0x07
                                                   && firmware[$0 + 7] == 0x38 && firmware[$0 + 8] == 0x04 })
            else { continue }
            let template = firmware.subdata(in: source..<source + size)
            for f in frames where f != source {
                firmware.replaceSubrange(f..<f + size, with: template)
                patched += 1
            }
        }
        return patched
    }

    /// Preboot header carrying `config`, followed by the firmware.
    static func image(firmware: Data, config: [UInt8]) -> Data {
        var h: [UInt8] = [0x4D, 0x41, 0x32, 0x78,
            0x9A, 0xA8, 0x00, 0x32, 0x20, 0xAD, 0xDE, 0xD0, 0xF1, 0x9A, 0x9C, 0x00, 0x32, 0x20, 0xFF, 0xFF, 0xFF, 0xFF,
            0x9A, 0xA8, 0x00, 0x32, 0x20, 0xAD, 0xDE, 0xD0, 0xF1, 0x9A, 0xA4, 0x00, 0x32, 0x20, 0x01, 0x00, 0x00, 0x00, 0x8A]
        let pad = (4 - (12 + config.count) % 4) % 4
        var sum: UInt32 = 5381
        for b in config { sum = sum &* 33 &+ UInt32(b) }
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { h += $0 } }
        le(UInt32(0x7801_0000)); le(UInt16((12 + config.count + pad) / 4)); le(UInt32(0x21EA_17E6))
        le(sum); le(UInt32(config.count))
        h += config + [UInt8](repeating: 0, count: pad)
        return Data(h) + firmware
    }
}

// MARK: - Pipeline

enum Pipeline {
    /// ColorCamera and node settings. Defaults mirror what Opal Composer sets (read from its
    /// binary): RGB socket, planar output, normal orientation, and UVC GPIOs 58/37/34 (the
    /// status light's blue, green and red) driven high while streaming. The sensor runs in
    /// its native 1080p30 mode, matching the 1080p-only webcam format (see patchFrameSizes).
    struct Camera {
        var initialControl = CameraControl()
        var resolution: Int32 = 0          // THE_1080_P
        var fps: Float = 30
        var videoWidth: Int32 = 1920
        var videoHeight: Int32 = 1080
        var ispScale: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)   // horiz num/den, vert num/den (0 = off)
        var sensorCropX: Float = -1        // top-left of the video window, 0…1 of the free range (-1 = centered)
        var sensorCropY: Float = -1
        var boardSocket: Int32 = 0         // RGB
        var interleaved = false
        var orientation: Int32 = 3         // ROTATE_180_DEG: the sensor is mounted upside down (0 = NORMAL)
        var uvcGpios = true
        var controlMaxDataSize: UInt32 = 1024
        var xlinkChunkSize: Int64 = 0

        /// depthai's untouched defaults (only used to compare against reference bytes).
        static var depthaiDefaults: Camera {
            Camera(resolution: 0, videoWidth: -1, videoHeight: -1, ispScale: (0, 0, 0, 0), boardSocket: -1,
                   interleaved: true, orientation: -1, uvcGpios: false, controlMaxDataSize: 5 << 20, xlinkChunkSize: -1)
        }
    }

    /// AudioMic settings. Defaults are what Opal Composer sets (read from its binary): front
    /// mics, a fixed 30 dB gain with the firmware's experimental AGC off, and 4-byte samples
    /// on the (unused) XLink output. Without an AudioMic feeding it, the USB mic sends silence.
    struct Mic {
        var gainDecibels: Float = 30
        var autoGain = false
        var backMics = false
        var xlinkApplyGain = true
        var xlinkSampleSizeBytes: UInt8 = 4
    }

    /// RPC request bytes for setPipelineSchema with XLinkIn("control") → ColorCamera → UVC,
    /// plus AudioMic → UAC (the USB microphone) when `mic` is set.
    static func setPipelineSchemaRequest(camera: Camera, mic: Mic?, tuningBlobUri: String = "", tuningBlobSize: Int? = nil) -> Data {
        let schema = schemaJSON(camera: camera, mic: mic, tuningBlobUri: tuningBlobUri, tuningBlobSize: tuningBlobSize)
        return RPC.request("setPipelineSchema", args: [schema])
    }

    static func schemaJSON(camera: Camera, mic: Mic?, tuningBlobUri: String, tuningBlobSize: Int?) -> MsgPack {
        func io(_ name: String, type: Int64, blocking: Bool, queueSize: Int64 = 8, waitForMessage: Bool = false) -> MsgPack {
            .array([.array([.string(""), .string(name)]),
                    .object(["blocking": .bool(blocking), "group": .string(""), "name": .string(name),
                             "queueSize": .int(queueSize), "type": .int(type), "waitForMessage": .bool(waitForMessage)])])
        }
        func node(_ id: Int64, _ name: String, _ properties: [UInt8], _ ioInfo: [MsgPack]) -> MsgPack {
            .array([.int(id), .object(["id": .int(id), "ioInfo": .array(ioInfo), "name": .string(name),
                                       "properties": .array(properties.map { .int(Int64($0)) })])])
        }
        func connection(_ a: Int64, _ out: String, _ b: Int64, _ input: String) -> MsgPack {
            .object(["node1Id": .int(a), "node1Output": .string(out), "node1OutputGroup": .string(""),
                     "node2Id": .int(b), "node2Input": .string(input), "node2InputGroup": .string("")])
        }
        let sender: Int64 = 0, receiver: Int64 = 3
        // Nodes and their IO are in the order depthai-core's unordered_maps serialize them.
        var nodes: [MsgPack] = []
        var connections = [connection(0, "out", 1, "inputControl"), connection(1, "video", 2, "in")]
        if let mic {
            // IO as registered by the AudioMic/UAC constructors in Opal's libdepthai-core;
            // UAC.inputConfig's queue size of 1 is what Opal sets.
            nodes += [
                node(4, "UAC", uacProperties(), [
                    io("input", type: receiver, blocking: false, queueSize: 4),
                    io("inputConfig", type: receiver, blocking: false, queueSize: 1),
                ]),
                node(3, "AudioMic", audioMicProperties(mic), [
                    io("outBack", type: sender, blocking: false), io("out", type: sender, blocking: false),
                    io("inputConfig", type: receiver, blocking: false, queueSize: 4),
                ]),
            ]
            connections.append(connection(3, "out", 4, "input"))
        }
        nodes += [
            node(2, "UVC", uvcProperties(gpios: camera.uvcGpios), [io("in", type: receiver, blocking: true, waitForMessage: true)]),
            node(1, "ColorCamera", colorCameraProperties(camera), [
                io("isp", type: sender, blocking: false), io("still", type: sender, blocking: false),
                io("preview", type: sender, blocking: false), io("video", type: sender, blocking: false),
                io("raw", type: sender, blocking: false), io("inputControl", type: receiver, blocking: true),
                io("inputConfig", type: receiver, blocking: false),
            ]),
            node(0, "XLinkIn", xlinkInProperties("control", maxDataSize: camera.controlMaxDataSize), [io("out", type: sender, blocking: false)]),
        ]
        let global: MsgPack = .object([
            "calibData": .null,
            "cameraTuningBlobSize": tuningBlobSize.map { .int(Int64($0)) } ?? .null,
            "cameraTuningBlobUri": .string(tuningBlobUri),
            "imageManipAdjustCmxSize": .int(0),
            "leonCssFrequencyHz": .float(700_000_000), "leonMssFrequencyHz": .float(700_000_000),
            "pipelineName": .null, "pipelineVersion": .null, "xlinkChunkSize": .int(camera.xlinkChunkSize),
        ])
        return .object([
            "connections": .array(connections),
            "globalProperties": global,
            "nodes": .array(nodes),
        ])
    }

    static func xlinkInProperties(_ stream: String, maxDataSize: UInt32) -> [UInt8] {
        var n = Nop()
        n.structure(3); n.string(stream); n.uint(UInt64(maxDataSize)); n.uint(8)
        return n.bytes
    }

    /// UVC node: GPIO levels at init, stream on and stream off (pin → level).
    static func uvcProperties(gpios: Bool) -> [UInt8] {
        let pins: [Int64] = [58, 37, 34]
        var n = Nop()
        n.structure(3)
        if gpios {
            n.intMap(pins.map { ($0, 0) }); n.intMap(pins.map { ($0, 1) }); n.intMap(pins.map { ($0, 0) })
        } else {
            n.emptyMap(); n.emptyMap(); n.emptyMap()
        }
        return n.bytes
    }

    /// RawAudioInConfig: { { micGain, disableOutput, passThrough } }.
    static func audioInConfig(gain: Float) -> [UInt8] {
        var n = Nop()
        n.structure(1); n.structure(3); n.float(gain); n.bool(false); n.bool(false)
        return n.bytes
    }

    static func audioMicProperties(_ m: Mic) -> [UInt8] {
        var n = Nop()
        n.structure(9)
        // AudioInConfig::setMicGainDecibels: exp10(dB / 20) in double, stored as float.
        let gain = Float(pow(10, Double(m.gainDecibels / 20)))
        var bytes = n.bytes + audioInConfig(gain: gain)
        n = Nop()
        n.bool(m.backMics); n.bool(m.autoGain)
        n.uint(48_000); n.uint(1440); n.uint(1440)     // sample rate, I2S read and XLink send sizes (samples)
        n.bool(true); n.bool(m.xlinkApplyGain)         // XLink interleaved, apply gain on XLink
        n.uint(UInt64(m.xlinkSampleSizeBytes))
        bytes += n.bytes
        return bytes
    }

    static func uacProperties() -> [UInt8] {
        var n = Nop()
        n.structure(1)
        return n.bytes + audioInConfig(gain: 1)
    }

    static func colorCameraProperties(_ c: Camera) -> [UInt8] {
        var n = Nop()
        n.structure(24)
        var bytes = n.bytes + c.initialControl.nop()
        n = Nop()
        n.int(Int64(c.boardSocket)); n.int(Int64(c.orientation)); n.int(0)   // board socket, orientation, colorOrder BGR
        n.bool(c.interleaved); n.bool(false)           // interleaved, fp16
        n.uint(300); n.uint(300)                       // preview height, width
        n.int(Int64(c.videoWidth)); n.int(Int64(c.videoHeight)); n.int(-1); n.int(-1)   // video, still
        n.int(Int64(c.resolution)); n.float(c.fps)
        n.float(c.sensorCropX); n.float(c.sensorCropY)  // sensor crop (video window position)
        n.bool(true); n.bool(false); n.bool(false)     // previewKeepAspectRatio, rawStreamMetadataOnly, rawPdafWindows8x6
        n.uint(0); n.uint(0); n.uint(0); n.uint(0)     // pdOffX/Y, pdWinW/H
        n.structure(4)                                 // ispScale
        n.int(Int64(c.ispScale.0)); n.int(Int64(c.ispScale.1)); n.int(Int64(c.ispScale.2)); n.int(Int64(c.ispScale.3))
        bytes += n.bytes
        return bytes
    }
}

// MARK: - Assets

/// The pipeline's asset table. The only asset is the camera tuning blob, stored at offset 0.
enum Assets {
    static let tuningKey = "camTuning"
    static var tuningUri: String { "asset:" + tuningKey }

    static func tuning(size: Int) -> MsgPack {
        .object(["map": .object(["/pipeline/" + tuningKey: .object([
            "alignment": .int(64), "offset": .int(0), "size": .int(Int64(size)),
        ])])])
    }
}

// MARK: - RPC

enum RPC {
    /// nanorpc request: [1, 1, hash(name), [args...]], or nil args for no arguments.
    static func request(_ name: String, args: [MsgPack] = []) -> Data {
        let body: MsgPack = .array([.int(1), .int(1), .raw([0xCF] + bigEndian(hash(name))),
                                    args.isEmpty ? .null : .array(args)])
        return Data(body.encoded())
    }

    static func hash(_ name: String) -> UInt64 {
        var h: UInt64 = 1_125_899_906_842_597
        for c in name.utf8 { h = 31 &* h &+ UInt64(c) }
        return h
    }

    /// True for `[1, 2, 1, ...]` (status good).
    static func succeeded(_ reply: Data) -> Bool {
        reply.count >= 4 && (reply[reply.startIndex] == 0x93 || reply[reply.startIndex] == 0x94)
            && reply[reply.startIndex + 3] == 0x01
    }

    private static func bigEndian(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }
}

// MARK: - Firmware

enum Firmware {
    static let opalLibrary = "/Applications/Opal Composer.app/Contents/Frameworks/libdepthai-core.dylib"
    static let opalResources = "/Applications/Opal Composer.app/Contents/XPCServices/OpalCameraDeviceService.xpc/Contents/Resources"

    /// Opal's image tuning for the camera's sensor: the original Opal C1 has an IMX378,
    /// a later revision an IMX582. `sensorReply` is the getCameraSensorNames RPC reply.
    static func tuningBlob(sensorReply: Data) -> Data? {
        let name = sensorReply.range(of: Data("582".utf8)) != nil ? "Opal582_v2.bin" : "Opal_v0.12.bin"
        return try? Data(contentsOf: URL(fileURLWithPath: opalResources).appendingPathComponent(name))
    }
    static let firmwareName = "depthai-device-openvino-2021.4-26f3d76548489ac14bc1c8ea9ef5ffc842e8adf7.cmd"

    /// The device firmware, cached after the first extraction from Opal's library.
    static func load() throws -> Data {
        let cache = cacheDirectory().appendingPathComponent(firmwareName)
        if let data = try? Data(contentsOf: cache), data.count > 1_000_000 { return data }
        let firmware = try extract(from: URL(fileURLWithPath: opalLibrary))
        try? FileManager.default.createDirectory(at: cacheDirectory(), withIntermediateDirectories: true)
        try? firmware.write(to: cache)
        return firmware
    }

    static func cacheDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("C1Tune", isDirectory: true)
    }

    struct Missing: LocalizedError {
        var errorDescription: String? {
            "Couldn't find the Opal C1 firmware. Install Opal Composer 1.0.1 (C1 Tune reads the firmware from it)."
        }
    }

    /// Finds the xz-compressed tarballs embedded in libdepthai-core and returns the device .cmd.
    static func extract(from library: URL) throws -> Data {
        let data = try Data(contentsOf: library, options: .mappedIfSafe)
        let magic = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
        var search = data.startIndex
        while let range = data.range(of: magic, in: search..<data.endIndex) {
            search = range.upperBound
            guard let tar = xzDecompress(data[range.lowerBound...]),
                  let file = tarFile(tar, named: firmwareName) else { continue }
            return file
        }
        throw Missing()
    }

    private static func xzDecompress(_ input: Data) -> Data? {
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        var output = Data()
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = min(src.count, 64 << 20)
            while true {
                stream.dst_ptr = dst
                stream.dst_size = 1 << 20
                let before = stream.src_size
                let status = compression_stream_process(&stream, 0)
                let produced = (1 << 20) - stream.dst_size
                output.append(dst, count: produced)
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK:
                    if output.count > 200 << 20 || (produced == 0 && stream.src_size == before) { return nil }
                default: return output.isEmpty ? nil : output
                }
            }
        }
    }

    private static func tarFile(_ tar: Data, named name: String) -> Data? {
        var offset = tar.startIndex
        while offset + 512 <= tar.endIndex {
            let header = tar[offset..<offset + 512]
            let fileName = String(decoding: header.prefix(100).prefix { $0 != 0 }, as: UTF8.self)
            if fileName.isEmpty { return nil }
            let sizeField = String(decoding: header[(offset + 124)..<(offset + 136)].prefix { $0 != 0 && $0 != 32 }, as: UTF8.self)
            guard let size = Int(sizeField, radix: 8) else { return nil }
            let start = offset + 512
            if (fileName as NSString).lastPathComponent == name, start + size <= tar.endIndex {
                return tar.subdata(in: start..<start + size)
            }
            offset = start + (size + 511) / 512 * 512
        }
        return nil
    }
}
