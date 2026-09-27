import Foundation

// fancoold — the tiny root helper that actually drives the fans.
//
//   fancoold            run the control loop (launchd starts this as root)
//   fancoold --probe    print fans + temperature sensors (no root needed)
//   sudo fancoold --test   spin fans to max for 8 s, then hand back to macOS

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments

guard let smc = SMC() else {
    print("Could not open the AppleSMC driver (struct size \(MemoryLayout<SMCKeyData>.stride), expected 80).")
    exit(1)
}
let temps = TemperatureReader(smc: smc)

func modelName() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "?" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buf, &size, nil, 0)
    return String(cString: buf)
}

func probe() {
    print("Model: \(modelName())")
    let fans = smc.fans()
    print("Fans: \(fans.count)")
    for f in fans {
        let mk = smc.modeKey(f.index) ?? "none"
        let rpm = smc.rpm(f.index) ?? -1
        let tgt = smc.target(f.index) ?? -1
        let modeValue = smc.read(mk) ?? -1
        let line = String(format: "  fan %d: %.0f rpm (target %.0f, range %.0f-%.0f), ",
                          f.index, rpm, tgt, f.minRPM, f.maxRPM)
        print(line + "mode key " + mk + " = " + String(Int(modeValue)))
    }
    print("Ftst unlock key: \(smc.exists("Ftst") ? "present" : "absent")")

    let hid = temps.hidReadings().sorted { $0.name < $1.name }
    print("\nHID temperature sensors: \(hid.count)")
    for r in hid {
        let tag = TemperatureReader.isChipSensor(r.name) ? "  [chip]" : ""
        let name = r.name.padding(toLength: 32, withPad: " ", startingAt: 0)
        print("  " + name + String(format: " %5.1f °C", r.celsius) + tag)
    }
    if hid.isEmpty {
        let s = temps.smcReadings()
        print("SMC temperature keys: \(s.count)")
        for r in s { print("  " + r.name + String(format: " %5.1f °C", r.celsius)) }
    }
    if let t = temps.chipTemperature() {
        print(String(format: "\nChip temperature used for control: %.1f °C", t))
    } else {
        print("\nNo chip temperature available!")
    }
}

func test() {
    guard getuid() == 0 else { print("Run with sudo: sudo \(args[0]) --test"); exit(1) }
    let fans = smc.fans()
    guard !fans.isEmpty else { print("No fans found."); exit(1) }
    defer { smc.releaseFans(fans); print("Fans returned to macOS.") }
    for f in fans {
        guard smc.forceFan(f.index) else {
            print("Fan \(f.index): macOS refused manual mode. Fan control is not possible on this Mac/OS version.")
            return
        }
        smc.setTarget(f.index, f.maxRPM)
    }
    print("Fans forced to max. Watching for 8 seconds…")
    for _ in 0..<8 {
        sleep(1)
        print(fans.map { String(format: "fan %d: %.0f rpm", $0.index, smc.rpm($0.index) ?? 0) }.joined(separator: "   "))
    }
}

if args.contains("--probe") { probe(); exit(0) }
if args.contains("--test") { test(); exit(0) }

guard getuid() == 0 else {
    print("fancoold must run as root (it is normally started by launchd). Try --probe or --test.")
    exit(1)
}

let controller = Controller(smc: smc, temps: temps)

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        controller.shutdown()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

controller.start()
dispatchMain()
