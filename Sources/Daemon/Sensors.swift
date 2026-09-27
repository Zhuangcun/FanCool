import Foundation

// Chip temperature on Apple Silicon comes from the private IOHIDEventSystem
// temperature sensors ("PMU tdie*", "pACC MTR Temp Sensor*", ...). These
// functions are exported by IOKit but not in the public headers, so they are
// looked up with dlsym and called through C function pointers.

final class HIDTemperatures {
    private typealias CreateFn = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyPropertyFn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeRawPointer, Int32) -> Double

    private static let temperatureEvent: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16      // IOHIDEventFieldBase(type)

    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let client: UnsafeMutableRawPointer
    private let servicesArray: CFArray
    let services: [(name: String, ref: UnsafeRawPointer)]

    init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let client = create(nil)
        else { return nil }

        self.copyEvent = copyEvent
        self.getFloat = getFloat
        self.client = client   // kept for the life of the process

        let matching: NSDictionary = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        withExtendedLifetime(matching) {
            setMatching(client, Unmanaged.passUnretained(matching).toOpaque())
        }
        guard let arrPtr = copyServices(client) else { return nil }
        let arr = Unmanaged<CFArray>.fromOpaque(arrPtr).takeRetainedValue()
        servicesArray = arr

        let productKey = "Product" as CFString
        var list: [(name: String, ref: UnsafeRawPointer)] = []
        for i in 0..<CFArrayGetCount(arr) {
            guard let svc = CFArrayGetValueAtIndex(arr, i) else { continue }
            var name = "sensor \(i)"
            withExtendedLifetime(productKey) {
                if let p = copyProperty(svc, Unmanaged.passUnretained(productKey).toOpaque()),
                   let s = Unmanaged<AnyObject>.fromOpaque(p).takeRetainedValue() as? String {
                    name = s
                }
            }
            list.append((name: name, ref: svc))
        }
        services = list
    }

    /// Every readable temperature sensor, in °C.
    func readAll() -> [(name: String, celsius: Double)] {
        var out: [(name: String, celsius: Double)] = []
        for s in services {
            guard let ev = copyEvent(s.ref, Self.temperatureEvent, 0, 0) else { continue }
            let v = getFloat(ev, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(ev).release()
            if v.isFinite, v > 1, v < 150 { out.append((name: s.name, celsius: v)) }
        }
        return out
    }
}

/// Picks "the chip temperature": the hottest die sensor (CPU, GPU, SoC).
/// Falls back to SMC "Tp*/Te*/Tf*/Tg*" keys if the HID sensors are unavailable.
final class TemperatureReader {
    private let hid: HIDTemperatures?
    private let smc: SMC
    private lazy var smcKeys: [String] = self.findSMCTemperatureKeys()

    private func findSMCTemperatureKeys() -> [String] {
        let prefixes = ["Tp", "Te", "Tf", "Tg", "TC"]
        var keys: [String] = []
        for k in smc.allKeys() where k.count == 4 && prefixes.contains(where: { k.hasPrefix($0) }) {
            let t = smc.type(of: k)
            if t == "flt " || t == "sp78" { keys.append(k) }
        }
        return keys
    }

    init(smc: SMC) {
        self.smc = smc
        self.hid = HIDTemperatures()
    }

    static func isChipSensor(_ name: String) -> Bool {
        name.contains("tdie") || name.contains("MTR Temp")
    }

    static func isIgnored(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("battery") || n.contains("gas gauge") || n.contains("nand") || n.contains("tcal")
    }

    func hidReadings() -> [(name: String, celsius: Double)] { hid?.readAll() ?? [] }

    func smcReadings() -> [(name: String, celsius: Double)] {
        var out: [(name: String, celsius: Double)] = []
        for k in smcKeys {
            if let v = smc.read(k), v > 1, v < 150 { out.append((name: k, celsius: v)) }
        }
        return out
    }

    func chipTemperature() -> Double? {
        let all = hidReadings()
        if let t = all.filter({ Self.isChipSensor($0.name) }).map({ $0.celsius }).max() { return t }
        if let t = all.filter({ !Self.isIgnored($0.name) }).map({ $0.celsius }).max() { return t }
        return smcReadings().map({ $0.celsius }).max()
    }
}
