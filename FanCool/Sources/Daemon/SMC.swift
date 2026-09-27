import Foundation
import IOKit

// Minimal AppleSMC client. Layout must match the kernel's 80-byte SMCParamStruct.

typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

struct SMCKeyData {
    struct Vers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    var key: UInt32 = 0
    var vers = Vers()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0      // Swift packs into KeyInfo's tail padding; C does not
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMC {
    private enum Cmd: UInt8 {
        case read = 5, write = 6, keyAtIndex = 8, keyInfo = 9
    }

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyData.KeyInfo] = [:]
    private var missing: Set<UInt32> = []

    init?() {
        guard MemoryLayout<SMCKeyData>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(conn) }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func name(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(decoding: b, as: UTF8.self)
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &outSize)
        guard r == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    func info(_ key: String) -> SMCKeyData.KeyInfo? {
        let k = SMC.fourCC(key)
        if let c = infoCache[k] { return c }
        if missing.contains(k) { return nil }
        var input = SMCKeyData()
        input.key = k
        input.data8 = Cmd.keyInfo.rawValue
        guard let out = call(&input), out.keyInfo.dataSize > 0 else {
            missing.insert(k)
            return nil
        }
        infoCache[k] = out.keyInfo
        return out.keyInfo
    }

    func exists(_ key: String) -> Bool { info(key) != nil }

    func type(of key: String) -> String? { info(key).map { SMC.name($0.dataType) } }

    func readRaw(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard let inf = info(key) else { return nil }
        var input = SMCKeyData()
        input.key = SMC.fourCC(key)
        input.keyInfo.dataSize = inf.dataSize
        input.data8 = Cmd.read.rawValue
        guard let out = call(&input) else { return nil }
        var b = out.bytes
        let n = min(Int(inf.dataSize), 32)
        let arr = withUnsafeBytes(of: &b) { Array($0.prefix(n)) }
        return (SMC.name(inf.dataType), arr)
    }

    func read(_ key: String) -> Double? {
        guard let raw = readRaw(key) else { return nil }
        return SMC.decode(type: raw.type, raw.bytes)
    }

    static func decode(type: String, _ b: [UInt8]) -> Double? {
        func be16() -> UInt16 { UInt16(b[0]) << 8 | UInt16(b[1]) }
        switch type {
        case "flt ":   // little-endian IEEE float (Apple Silicon)
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let f = Double(Float(bitPattern: bits))
            return f.isFinite ? f : nil
        case "ui8 ", "flag":
            return b.first.map { Double($0) }
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(be16())
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "fpe2":   // Intel fan RPM, big-endian 14.2 fixed point
            guard b.count >= 2 else { return nil }
            return Double(be16()) / 4
        case "sp78":   // Intel temperatures, signed 7.8 fixed point
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: be16())) / 256
        default:
            return nil
        }
    }

    @discardableResult
    func write(_ key: String, _ value: Double) -> Bool {
        guard let inf = info(key), value.isFinite else { return false }
        let bytes: [UInt8]
        switch SMC.name(inf.dataType) {
        case "flt ":
            let bits = Float(value).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                     UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
        case "ui8 ", "flag":
            bytes = [UInt8(clamping: Int(value))]
        case "ui16":
            let v = UInt16(clamping: Int(value))
            bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        case "fpe2":
            let v = UInt16(clamping: Int(value * 4))
            bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        default:
            return false
        }
        var input = SMCKeyData()
        input.key = SMC.fourCC(key)
        input.keyInfo.dataSize = inf.dataSize
        input.data8 = Cmd.write.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, v) in bytes.enumerated() where i < raw.count { raw[i] = v }
        }
        return call(&input) != nil
    }

    func allKeys() -> [String] {
        guard let n = read("#KEY"), n > 0, n < 10_000 else { return [] }
        var keys: [String] = []
        for i in 0..<UInt32(n) {
            var input = SMCKeyData()
            input.data8 = Cmd.keyAtIndex.rawValue
            input.data32 = i
            if let out = call(&input) { keys.append(SMC.name(out.key)) }
        }
        return keys
    }
}

// MARK: - Fans

struct FanInfo {
    let index: Int
    let minRPM: Double
    let maxRPM: Double
}

extension SMC {
    func fans() -> [FanInfo] {
        let n = Int(read("FNum") ?? 0)
        guard n > 0 else { return [] }
        return (0..<min(n, 4)).compactMap { i in
            guard let mx = read("F\(i)Mx"), mx > 0 else { return nil }
            let mn = read("F\(i)Mn") ?? 0
            return FanInfo(index: i, minRPM: mn, maxRPM: mx)
        }
    }

    func rpm(_ i: Int) -> Double? { read("F\(i)Ac") }
    func target(_ i: Int) -> Double? { read("F\(i)Tg") }

    /// Some Apple Silicon models spell the mode key with a lowercase m.
    func modeKey(_ i: Int) -> String? {
        ["F\(i)Md", "F\(i)md"].first { exists($0) }
    }

    func isForced(_ i: Int) -> Bool {
        guard let k = modeKey(i) else { return false }
        return (read(k) ?? 0) == 1
    }

    /// Switch one fan to manual (forced) mode. On Apple Silicon the SMC only
    /// accepts this after the "Ftst" unlock key is set, and it can take a
    /// moment before thermalmonitord lets go, hence the retry loop.
    func forceFan(_ i: Int) -> Bool {
        guard let k = modeKey(i) else { return false }
        if (read(k) ?? 0) == 1 { return true }
        if exists("Ftst") { write("Ftst", 1) }
        for _ in 0..<60 {
            if write(k, 1), (read(k) ?? 0) == 1 { return true }
            usleep(50_000)
        }
        return false
    }

    @discardableResult
    func setTarget(_ i: Int, _ rpm: Double) -> Bool { write("F\(i)Tg", rpm) }

    /// Hand every fan back to macOS.
    func releaseFans(_ fans: [FanInfo]) {
        for f in fans {
            if let k = modeKey(f.index) { write(k, 0) }
        }
        if exists("Ftst") { write("Ftst", 0) }
    }
}
