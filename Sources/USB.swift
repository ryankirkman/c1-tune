import Foundation
import IOKit
import IOKit.usb

/// USB product IDs the Myriad X inside the Opal C1 shows up as, by boot stage.
enum OpalPID: Int, Sendable {
    case booted = 0xF63B        // running firmware (Opal's standalone app, or ours)
    case bootloader = 0xF63C
    case rom = 0x2485           // chip's USB boot ROM, waiting for firmware
}

enum USB {
    static let vendorID = 0x03E7

    static func isPresent(_ pid: OpalPID) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching("IOUSBHostDevice", pid))
        if service != 0 { IOObjectRelease(service) }
        return service != 0
    }

    /// Polls every 100 ms until a device with `pid` appears.
    static func wait(for pid: OpalPID, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isPresent(pid) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Sends a control request with no data stage. The device often drops off the bus
    /// in response, so the result is informational only.
    @discardableResult
    static func deviceRequest(_ pid: OpalPID, type: UInt8, request: UInt8, value: UInt16, index: UInt16) -> IOReturn {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching("IOUSBHostDevice", pid))
        guard service != 0 else { return kIOReturnNotFound }
        defer { IOObjectRelease(service) }
        guard let device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?> =
            queryInterface(service, type: deviceUserClientTypeID, interface: deviceInterfaceID)
        else { return kIOReturnError }
        defer { _ = device.pointee?.pointee.Release(device) }
        var req = IOUSBDevRequest(bmRequestType: type, bRequest: request, wValue: value, wIndex: index,
                                  wLength: 0, pData: nil, wLenDone: 0)
        return device.pointee?.pointee.DeviceRequest(device, &req) ?? kIOReturnError
    }

    fileprivate static func matching(_ cls: String, _ pid: OpalPID, interface: Int? = nil) -> CFMutableDictionary {
        let dict = IOServiceMatching(cls) as NSMutableDictionary
        dict[kUSBVendorID] = vendorID
        dict[kUSBProductID] = pid.rawValue
        if let interface {
            dict[kUSBInterfaceNumber] = interface
            dict[kUSBConfigurationValue] = 1
        }
        return dict
    }

    fileprivate static func queryInterface<T>(_ service: io_service_t, type: CFUUID, interface: CFUUID)
        -> UnsafeMutablePointer<UnsafeMutablePointer<T>?>?
    {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, type, plugInInterfaceID, &plugin, &score) == kIOReturnSuccess,
              let plugin else { return nil }
        defer { _ = plugin.pointee?.pointee.Release(plugin) }
        var result: UnsafeMutablePointer<UnsafeMutablePointer<T>?>?
        let hr = withUnsafeMutablePointer(to: &result) { ptr in
            ptr.withMemoryRebound(to: LPVOID?.self, capacity: 1) {
                plugin.pointee?.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(interface), $0)
            }
        }
        return hr == 0 ? result : nil
    }

    // C macros in IOKit, so Swift can't see them.
    fileprivate static var plugInInterfaceID: CFUUID {        // kIOCFPlugInInterfaceID
        CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                                       0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    }
    fileprivate static var deviceUserClientTypeID: CFUUID {   // kIOUSBDeviceUserClientTypeID
        CFUUIDGetConstantUUIDWithBytes(nil, 0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
                                       0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    }
    fileprivate static var deviceInterfaceID: CFUUID {        // kIOUSBDeviceInterfaceID
        CFUUIDGetConstantUUIDWithBytes(nil, 0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4,
                                       0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    }
    fileprivate static var interfaceUserClientTypeID: CFUUID { // kIOUSBInterfaceUserClientTypeID
        CFUUIDGetConstantUUIDWithBytes(nil, 0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
                                       0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    }
    fileprivate static var interfaceInterfaceID300: CFUUID {  // kIOUSBInterfaceInterfaceID300
        CFUUIDGetConstantUUIDWithBytes(nil, 0xBC, 0xEA, 0xAD, 0xDC, 0x88, 0x4D, 0x4F, 0x27,
                                       0x83, 0x40, 0x36, 0xD6, 0x9F, 0xAB, 0x90, 0xF6)
    }
}

/// Exclusive access to interface 0 (the vendor bulk interface) in one boot stage.
/// Reads and writes are blocking; callers keep them off the main thread.
final class USBPipe: @unchecked Sendable {
    enum OpenError: Error { case notFound, busy, failed }

    private typealias Interface = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface300>?>
    private let interface: Interface
    private let pipeOut: UInt8
    private let pipeIn: UInt8   // 0 when the interface has no IN endpoint (boot ROM)
    private let lock = NSLock()
    private var isOpen = true   // guarded by lock

    /// Opens interface 0, or tells why not: `.busy` means another app holds the camera.
    static func open(_ pid: OpalPID) -> Result<USBPipe, OpenError> {
        do { return .success(try USBPipe(pid)) } catch let e as OpenError { return .failure(e) } catch { return .failure(.failed) }
    }

    private init(_ pid: OpalPID) throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, USB.matching("IOUSBHostInterface", pid, interface: 0))
        guard service != 0 else { throw OpenError.notFound }
        defer { IOObjectRelease(service) }
        guard let interface: Interface = USB.queryInterface(
            service, type: USB.interfaceUserClientTypeID, interface: USB.interfaceInterfaceID300),
              let fns = interface.pointee?.pointee
        else { throw OpenError.failed }
        let kr = fns.USBInterfaceOpen(interface)
        guard kr == kIOReturnSuccess else {
            _ = fns.Release(interface)
            throw kr == kIOReturnExclusiveAccess ? OpenError.busy : OpenError.failed
        }
        var count: UInt8 = 0
        _ = fns.GetNumEndpoints(interface, &count)
        var out: UInt8 = 0, inp: UInt8 = 0
        for i in 0..<count {
            let ref = i + 1
            var dir: UInt8 = 0, number: UInt8 = 0, type: UInt8 = 0, interval: UInt8 = 0
            var maxPacket: UInt16 = 0
            _ = fns.GetPipeProperties(interface, ref, &dir, &number, &type, &maxPacket, &interval)
            guard type == UInt8(kUSBBulk) else { continue }
            if dir == UInt8(kUSBOut), out == 0 { out = ref }
            if dir == UInt8(kUSBIn), inp == 0 { inp = ref }
        }
        guard out != 0 else {
            _ = fns.USBInterfaceClose(interface)
            _ = fns.Release(interface)
            throw OpenError.failed
        }
        self.interface = interface
        self.pipeOut = out
        self.pipeIn = inp
    }

    deinit { close() }

    /// Releases the interface. Unblocks a pending read first.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen, let fns = interface.pointee?.pointee else { return }
        isOpen = false
        if pipeIn != 0 { _ = fns.AbortPipe(interface, pipeIn) }
        _ = fns.USBInterfaceClose(interface)
        _ = fns.Release(interface)
    }

    /// Makes a blocking `read` return `.aborted` so its thread can exit.
    func abortRead() {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen, pipeIn != 0, let fns = interface.pointee?.pointee else { return }
        _ = fns.AbortPipe(interface, pipeIn)
    }

    /// Writes all of `data` (an empty buffer sends a zero-length packet); false on error or timeout.
    func write(_ data: UnsafeRawBufferPointer, timeoutMs: UInt32) -> Bool {
        lock.lock(); let open = isOpen; lock.unlock()
        guard open, let fns = interface.pointee?.pointee else { return false }
        var dummy: UInt8 = 0
        let kr = withUnsafeMutablePointer(to: &dummy) { zlp in
            fns.WritePipeTO(interface, pipeOut, data.baseAddress.map { UnsafeMutableRawPointer(mutating: $0) } ?? UnsafeMutableRawPointer(zlp),
                            UInt32(data.count), timeoutMs, timeoutMs)
        }
        if kr != kIOReturnSuccess { _ = fns.ClearPipeStallBothEnds(interface, pipeOut) }
        return kr == kIOReturnSuccess
    }

    func write(_ data: Data, timeoutMs: UInt32) -> Bool {
        data.withUnsafeBytes { write($0, timeoutMs: timeoutMs) }
    }

    enum ReadResult { case data(Int), timeout, aborted, failed }

    /// Reads up to `count` bytes. `timeoutMs` 0 waits until data arrives or `abortRead()`.
    func read(into buffer: UnsafeMutableRawPointer, count: Int, timeoutMs: UInt32) -> ReadResult {
        lock.lock(); let open = isOpen; lock.unlock()
        guard open, pipeIn != 0, let fns = interface.pointee?.pointee else { return .aborted }
        var size = UInt32(count)
        let kr = timeoutMs == 0
            ? fns.ReadPipe(interface, pipeIn, buffer, &size)
            : fns.ReadPipeTO(interface, pipeIn, buffer, &size, timeoutMs, timeoutMs)
        switch kr {
        case kIOReturnSuccess: return .data(Int(size))
        case IOReturn(bitPattern: 0xE000_4051), kIOReturnTimeout: return .timeout   // kIOUSBTransactionTimeout
        case kIOReturnAborted: return .aborted
        default:
            _ = fns.ClearPipeStallBothEnds(interface, pipeIn)
            return .failed
        }
    }
}
