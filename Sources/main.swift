import AppKit
import ServiceManagement

// Used by `make uninstall`: login-item registration lives with the system,
// not in the bundle, so only the app itself can remove it.
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

// `C1Tune --register-login-item`: same as ticking "Open at login" in the panel.
if CommandLine.arguments.contains("--register-login-item") {
    do {
        try SMAppService.mainApp.register()
        print("Open at login: on")
    } catch {
        print("Couldn't turn on Open at login: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

// `C1Tune --set key=value ...` hands settings to the running app and exits.
if let i = CommandLine.arguments.firstIndex(of: "--set") {
    var pairs: [String: String] = [:]
    for arg in CommandLine.arguments[(i + 1)...] {
        let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { pairs[parts[0]] = parts[1] }
    }
    DistributedNotificationCenter.default().postNotificationName(
        .init("com.ryankirkman.c1tune.set"), object: nil, userInfo: pairs, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
