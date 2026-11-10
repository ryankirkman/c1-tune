import CryptoKit
import Foundation

// Protocol tests: `make test`. Compares encoders with reference bytes produced by compiling
// DepthAI's own headers (Tests/fixtures), and checks the firmware can be obtained.

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    print(ok ? "✓ \(what)" : "✗ \(what)")
    if !ok { failures += 1 }
}
func hex(_ s: String) -> Data {
    let digits = Array(s.replacingOccurrences(of: " ", with: ""))
    return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
}
func fixture(_ name: String) -> Data {
    let dir = URL(fileURLWithPath: CommandLine.arguments[1])
    return (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data()
}
@MainActor func same(_ a: Data, _ b: Data, _ what: String) {
    check(a == b, "\(what) (\(a.count) bytes)")
    if a != b, let i = zip(a, b).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? Optional(min(a.count, b.count)) {
        print("  first difference at byte \(i): got \(a.dropFirst(i).prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")) expected \(b.dropFirst(i).prefix(12).map { String(format: "%02X", $0) }.joined(separator: " "))")
    }
}

let regions = "B903000000" + "B9050000000000" + "B9050000000000"

var focus = CameraControl()
focus.set(.moveLens); focus.lensPosition = 130
same(focus.encoded(), hex("B91D10038082000000" + "80FF" + regions + String(repeating: "00", count: 19) + "0500000031000000"),
     "CameraControl setManualFocus(130)")

var wb = CameraControl()
wb.set(.wbColorTemp); wb.wbColorTemp = 4000
same(wb.encoded(), hex("B91D830000000000000200" + "0300000000" + "80FF" + regions + String(repeating: "00", count: 16)
                       + "81A00F0000" + "050000003A000000"), "CameraControl setManualWhiteBalance(4000)")

let boot = BootImage.image(firmware: Data(), config: BootImage.boardConfig(watchdogMs: 0, uvc: true))
same(boot, hex("4D4132789AA8003220ADDED0F19A9C003220FFFFFFFF9AA8003220ADDED0F19AA4003220010000008A00000178"
               + "0B00E617EA21CD856B041D000000B908B90581E703813BF681E703813DF604B90100BA0000BEBB00BB0001000000"),
     "Boot header (UVC on, watchdog off)")

same(Pipeline.setPipelineSchemaRequest(camera: .depthaiDefaults, mic: nil), fixture("setPipelineSchema_request.bin"),
     "setPipelineSchema (camera defaults)")
same(Pipeline.setPipelineSchemaRequest(camera: .depthaiDefaults, mic: nil, tuningBlobUri: "asset:camTuning", tuningBlobSize: 195_916),
     fixture("setPipelineSchema_tuning_request.bin"), "setPipelineSchema (with tuning blob)")
same(Pipeline.setPipelineSchemaRequest(camera: .depthaiDefaults, mic: Pipeline.Mic(), tuningBlobUri: "asset:camTuning",
                                       tuningBlobSize: 195_916),
     fixture("setPipelineSchema_audio_request.bin"), "setPipelineSchema (tuning blob, AudioMic → UAC as Opal sets it)")
same(RPC.request("setAssets", args: [Assets.tuning(size: 195_916)]), fixture("setAssets_request.bin"), "setAssets")
same(RPC.request("memAlloc", args: [.int(195_916)]), fixture("memAlloc_request.bin"), "memAlloc")
check(RPC.hash("setLogLevel") == 0x8D4F_7389_1DCA_A01D, "RPC name hash")

// The firmware from wherever this Mac can get it: Opal Composer if it's installed (offline),
// otherwise Luxonis's archive, as the app does. C1TUNE_TEST_DOWNLOAD=1 checks the download too.
let hasOpal = FileManager.default.fileExists(atPath: Firmware.opalLibrary)
if hasOpal {
    let start = Date()
    let firmware = try? Firmware.extract(from: URL(fileURLWithPath: Firmware.opalLibrary))
    let digest = firmware.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    check(digest == Firmware.firmwareSHA256,
          String(format: "Firmware extracted from Opal Composer (%.1f s)", Date().timeIntervalSince(start)))
}
if !hasOpal || ProcessInfo.processInfo.environment["C1TUNE_TEST_DOWNLOAD"] != nil {
    let start = Date()
    // download() only returns firmware whose hash matches.
    check((try? Firmware.download())?.count == 25_205_008,
          String(format: "Firmware downloaded from Luxonis and verified (%.1f s)", Date().timeIntervalSince(start)))
}

print(failures == 0 ? "PASS" : "FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
