import CoreMediaIO
import Foundation

/// Tells when any app starts using the Opal C1's video. The camera ignores control
/// messages until its sensor is streaming, so settings are re-sent at that moment.
/// Event-driven through CoreMediaIO property listeners; nothing polls.
@MainActor
final class StreamWatcher {
    var onStart: (() -> Void)?

    private var listeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var running: Set<CMIOObjectID> = []
    private var systemListener: CMIOObjectPropertyListenerBlock?

    func start() {
        var addr = Self.address(kCMIOHardwarePropertyDevices)
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        systemListener = block
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, DispatchQueue.main, block)
        refresh()
    }

    private func refresh() {
        let opal = Self.deviceIDs().filter {
            Self.stringProperty($0, kCMIODevicePropertyModelUID)?.contains("VendorID_\(USB.vendorID) ProductID_\(OpalPID.booted.rawValue)") == true
        }
        for (id, block) in listeners where !opal.contains(id) {
            var addr = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, block)
            listeners[id] = nil
            running.remove(id)
        }
        for id in opal where listeners[id] == nil {
            var addr = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.check(id) }
            }
            if CMIOObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == 0 { listeners[id] = block }
            check(id)
        }
    }

    private func check(_ id: CMIOObjectID) {
        let isRunning = Self.isRunningSomewhere(id)
        if isRunning && !running.contains(id) { onStart?() }
        if isRunning { running.insert(id) } else { running.remove(id) }
    }

    // MARK: - CoreMediaIO helpers

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func deviceIDs() -> [CMIOObjectID] {
        var addr = address(kCMIOHardwarePropertyDevices)
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == 0 else { return [] }
        return ids
    }

    private static func stringProperty(_ device: CMIOObjectID, _ selector: Int) -> String? {
        var addr = address(selector)
        guard CMIOObjectHasProperty(device, &addr) else { return nil }
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == 0 else { return nil }
        var used: UInt32 = 0
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, $0) }
        guard status == 0 else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var addr = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        guard CMIOObjectHasProperty(device, &addr) else { return false }
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == 0 && value != 0
    }
}
