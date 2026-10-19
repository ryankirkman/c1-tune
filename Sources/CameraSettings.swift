import Foundation

/// What the user picked. Optional image values mean "leave the tuning's default".
/// Defaults were tuned on a live picture under warm (3000 K) bounced key light: a touch
/// darker than the auto-exposure target so skin and a white wall don't wash out, a little
/// more color, and slightly crisper than the tuning's own sharpness (≈2).
struct CameraSettings: Codable, Equatable, Sendable {
    var autoExposure = true
    var exposureUs = 16_667           // manual shutter, 100 µs–33 ms; 1/60 s avoids banding under 60 Hz light
    var iso = 400                     // manual ISO, 100–1600
    var exposureCompensation = -1     // auto exposure bias, -9…9

    var autoFocus = true
    var lensPosition = 130            // manual focus, 0 (far)…255 (near)

    var autoWhiteBalance = true
    var whiteBalanceK = 4500          // manual, 1000–12000 K

    var brightness = 0                // -10…10
    var contrast = 0                  // -10…10
    var saturation = 1                // -10…10
    var sharpness: Int? = 3           // 0…4
    var noiseReduction: Int?          // luma denoise 0…4
    var colorNoiseReduction: Int?     // chroma denoise 0…4

    var antiFlicker = 3               // 0 off, 1 50 Hz, 2 60 Hz, 3 auto

    /// The Opal C1's sensor is mounted upside down, so the picture is normally rotated 180°
    /// (as Opal does). `flipped` turns that off, e.g. for a camera mounted upside down.
    var flipped = false
    var orientation: Int32 { flipped ? 0 : 3 }   // CameraImageOrientation: 0 NORMAL, 3 ROTATE_180_DEG

    /// The camera's built-in microphone. Off, the pipeline has no audio nodes, so the camera's
    /// USB mic (which the firmware always advertises) only sends silence. Applies when the
    /// camera starts.
    var microphone = false
    var pipelineMic: Pipeline.Mic? { microphone ? Pipeline.Mic() : nil }

    /// Zoom in percent (100…200), one of `zoomStops`. The sensor always runs at 4K; the ISP
    /// scales it by n/d and a 1920x1080 window is taken from the result, so there's no upscaling.
    var zoom = 100
    /// Where the zoomed window sits, in percent of the free range (0 = left/top, 100 = right/bottom).
    var frameX = 50
    var frameY = 50

    /// Every zoom the camera can do without upscaling, each tested on hardware: ISP scale n/d of
    /// the 4K sensor image, zoom = 2·n/d. The scaler accepts numerators up to 16 (MAX_N); larger
    /// ones (17/30, 19/24, …) make the firmware silently disable scaling.
    static let zoomStops: [(percent: Int, n: Int32, d: Int32)] = [
        (100, 1, 2), (107, 8, 15), (108, 13, 24), (110, 11, 20), (117, 7, 12), (120, 3, 5), (125, 5, 8),
        (130, 13, 20), (133, 2, 3), (140, 7, 10), (147, 11, 15), (150, 3, 4), (160, 4, 5), (167, 5, 6),
        (173, 13, 15), (175, 7, 8), (180, 9, 10), (183, 11, 12), (187, 14, 15), (200, 1, 1),
    ]

    static func nearestZoom(_ percent: Int) -> Int {
        zoomStops.map(\.percent).min { abs($0 - percent) < abs($1 - percent) } ?? 100
    }

    /// ColorCamera settings for this zoom and framing. 1× is the 4K image scaled by 1/2, which
    /// measured less noisy and more detailed than the sensor's own 1080p mode.
    func pipelineCamera() -> Pipeline.Camera {
        var camera = Pipeline.Camera()
        camera.initialControl = fullControl()
        camera.orientation = orientation
        camera.resolution = 2   // THE_4_K
        let stop = Self.zoomStops.first { $0.percent == Self.nearestZoom(zoom) } ?? Self.zoomStops[0]
        camera.ispScale = stop.n == stop.d ? (0, 0, 0, 0) : (stop.n, stop.d, stop.n, stop.d)
        let window = Float(stop.d) / Float(2 * stop.n)   // share of the scaled frame the 1080p window covers
        if window < 1 {
            camera.sensorCropX = Float(min(max(frameX, 0), 100)) / 100 * (1 - window)
            camera.sensorCropY = Float(min(max(frameY, 0), 100)) / 100 * (1 - window)
        }
        return camera
    }

    // MARK: Persistence

    /// Saved settings over the defaults, so settings added in later versions keep their defaults.
    static func load() -> CameraSettings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var merged = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(CameraSettings()))) as? [String: Any]
        else { return CameraSettings() }
        merged.merge(saved) { _, new in new }
        guard let json = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(CameraSettings.self, from: json) else { return CameraSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") }
    }

    /// True when going from `self` to `new` returns a value to the tuning's default, which
    /// needs the camera's pipeline restarted (there's no command for "default").
    func needsRestart(for new: CameraSettings) -> Bool {
        (sharpness != nil && new.sharpness == nil) || (noiseReduction != nil && new.noiseReduction == nil)
            || (colorNoiseReduction != nil && new.colorNoiseReduction == nil) || flipped != new.flipped || microphone != new.microphone
            || zoom != new.zoom || (new.zoom != 100 && (frameX != new.frameX || frameY != new.frameY))
    }

    /// Applies `key=value` pairs (from `C1Tune --set`). Unknown keys and unparseable
    /// values are ignored; "default" clears sharpness or a denoise value.
    func applying(_ pairs: [String: String]) -> CameraSettings {
        var s = self
        for (key, raw) in pairs {
            let value = raw.lowercased()
            let flag: Bool? = ["true", "on", "yes", "1"].contains(value) ? true
                : ["false", "off", "no", "0"].contains(value) ? false : nil
            let clear = ["default", "nil", ""].contains(value)
            let number = Int(raw)
            switch key {
            case "autoExposure": s.autoExposure = flag ?? s.autoExposure
            case "autoFocus": s.autoFocus = flag ?? s.autoFocus
            case "autoWhiteBalance": s.autoWhiteBalance = flag ?? s.autoWhiteBalance
            case "flipped": s.flipped = flag ?? s.flipped
            case "microphone": s.microphone = flag ?? s.microphone
            case "exposureUs": s.exposureUs = number ?? s.exposureUs
            case "iso": s.iso = number ?? s.iso
            case "exposureCompensation": s.exposureCompensation = number ?? s.exposureCompensation
            case "lensPosition": s.lensPosition = number ?? s.lensPosition
            case "whiteBalanceK": s.whiteBalanceK = number ?? s.whiteBalanceK
            case "brightness": s.brightness = number ?? s.brightness
            case "contrast": s.contrast = number ?? s.contrast
            case "saturation": s.saturation = number ?? s.saturation
            case "antiFlicker": s.antiFlicker = number ?? s.antiFlicker
            case "zoom": s.zoom = number.map(Self.nearestZoom) ?? s.zoom
            case "frameX": s.frameX = number.map { min(max($0, 0), 100) } ?? s.frameX
            case "frameY": s.frameY = number.map { min(max($0, 0), 100) } ?? s.frameY
            case "sharpness": s.sharpness = clear ? nil : number ?? s.sharpness
            case "noiseReduction": s.noiseReduction = clear ? nil : number ?? s.noiseReduction
            case "colorNoiseReduction": s.colorNoiseReduction = clear ? nil : number ?? s.colorNoiseReduction
            default: break
            }
        }
        return s
    }

    // MARK: Camera commands

    enum Group: CaseIterable, Hashable, Sendable { case exposure, focus, whiteBalance, image, antiFlicker }

    /// One control message setting everything; used as the pipeline's initial control.
    func fullControl() -> CameraControl {
        var c = CameraControl()
        for group in Group.allCases { add(group, to: &c) }
        return c
    }

    /// A control message for just one group of settings.
    func control(for group: Group) -> CameraControl {
        var c = CameraControl()
        add(group, to: &c)
        return c
    }

    private func add(_ group: Group, to c: inout CameraControl) {
        switch group {
        case .exposure:
            if autoExposure {
                c.set(.aeAuto)
                c.set(.expCompensation); c.expCompensation = Int8(clamping: exposureCompensation)
            } else {
                c.set(.aeManual)
                c.exposureTimeUs = UInt32(clamping: exposureUs)
                c.sensitivityIso = UInt32(clamping: iso)
            }
        case .focus:
            c.set(.afMode)
            if autoFocus {
                c.autoFocusMode = .continuousVideo
            } else {
                c.autoFocusMode = .off
                c.set(.moveLens); c.lensPosition = UInt8(clamping: lensPosition)
            }
        case .whiteBalance:
            if autoWhiteBalance {
                c.set(.awbMode); c.awbMode = .auto
            } else {
                c.set(.wbColorTemp); c.wbColorTemp = UInt16(clamping: whiteBalanceK)
            }
        case .image:
            c.set(.brightness); c.brightness = Int8(clamping: brightness)
            c.set(.contrast); c.contrast = Int8(clamping: contrast)
            c.set(.saturation); c.saturation = Int8(clamping: saturation)
            if let sharpness { c.set(.sharpness); c.sharpness = UInt8(clamping: sharpness) }
            if let noiseReduction { c.set(.lumaDenoise); c.lumaDenoise = UInt8(clamping: noiseReduction) }
            if let colorNoiseReduction { c.set(.chromaDenoise); c.chromaDenoise = UInt8(clamping: colorNoiseReduction) }
        case .antiFlicker:
            c.set(.antiBanding)
            c.antiBandingMode = CameraControl.AntiBanding(rawValue: UInt8(clamping: antiFlicker)) ?? .auto
        }
    }
}
