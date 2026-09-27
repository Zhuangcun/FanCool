import Foundation

/// The control loop. Runs as root every 2 seconds.
///
/// Rules (auto mode):
///  - Below the start temperature, macOS owns the fans. We don't touch them.
///  - At/above it, we take over and ramp linearly from the fan's current speed
///    up to max over the next 20 °C.
///  - We never go *below* what macOS was running when we took over, so we can
///    only ever add cooling.
///  - We hand control back once the chip is 6 °C below the start temperature.
///  - At 95 °C we go to max regardless.
final class Controller {
    static let interval: TimeInterval = 2
    static let hysteresis: Double = 6
    static let rampSpan: Double = 20
    static let emergency: Double = 95

    private let smc: SMC
    private let temps: TemperatureReader
    private let fans: [FanInfo]
    private var boosting = false
    private var floorRPM: [Double] = []
    private var smoothed: Double?
    private var lastMode: FanMode?
    private var message: String?
    private var timer: DispatchSourceTimer?

    init(smc: SMC, temps: TemperatureReader) {
        self.smc = smc
        self.temps = temps
        self.fans = smc.fans()
    }

    func start() {
        try? FileManager.default.createDirectory(atPath: FanCoolPaths.statusDir,
                                                 withIntermediateDirectories: true)
        // Start from a clean state in case a previous run died while boosting.
        smc.releaseFans(fans)
        logLine("started: \(fans.count) fan(s) " +
            fans.map { "#\($0.index) \(Int($0.minRPM))–\(Int($0.maxRPM)) rpm" }.joined(separator: ", "))
        if fans.isEmpty { message = "No controllable fans found on this Mac" }

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: Controller.interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func shutdown() {
        timer?.cancel()
        if boosting || fans.contains(where: { smc.isForced($0.index) }) {
            smc.releaseFans(fans)
        }
        logLine("stopped, fans returned to macOS")
    }

    private func tick() {
        let settings = Settings.load()
        if settings.mode != lastMode {
            logLine("mode: \(settings.mode.rawValue), start at \(Int(settings.startTemp)) °C")
            lastMode = settings.mode
        }

        guard let raw = temps.chipTemperature() else {
            if boosting { release(reason: "temperature unreadable") }
            message = "Can't read chip temperature"
            writeStatus(settings)
            return
        }
        let t = smoothed.map { $0 * 0.6 + raw * 0.4 } ?? raw
        smoothed = t

        // Decide how much to boost (nil = leave it to macOS).
        var level: Double? = nil
        switch settings.mode {
        case .off:
            level = nil
        case .max:
            level = 1
        case .auto:
            let start = settings.startTemp
            if t >= Controller.emergency {
                level = 1
            } else if boosting ? (t > start - Controller.hysteresis) : (t >= start) {
                level = min(max((t - start) / Controller.rampSpan, 0), 1)
            }
        }

        if let level, !fans.isEmpty {
            if !boosting {
                floorRPM = fans.map { smc.rpm($0.index) ?? $0.minRPM }
                logLine(String(format: "boost on at %.1f °C", t))
            }
            apply(level: level)
        } else if boosting {
            release(reason: String(format: "%.1f °C", t))
        }
        writeStatus(settings)
    }

    private func apply(level: Double) {
        var failed: [Int] = []
        for (n, f) in fans.enumerated() {
            let curve = f.minRPM + (f.maxRPM - f.minRPM) * level
            let floor = n < floorRPM.count ? floorRPM[n] : f.minRPM
            let target = min(max(curve, floor, f.minRPM), f.maxRPM)

            if !smc.isForced(f.index), !smc.forceFan(f.index) {
                failed.append(f.index)
                continue
            }
            // Only write when it changed meaningfully; also re-applies after sleep/wake resets.
            if abs((smc.target(f.index) ?? 0) - target) > 40 {
                smc.setTarget(f.index, target)
            }
        }
        boosting = true
        if failed.isEmpty {
            message = nil
        } else {
            let names = failed.map { String($0 + 1) }.joined(separator: ", ")
            message = "macOS refused manual control of fan " + names
        }
    }

    private func release(reason: String) {
        smc.releaseFans(fans)
        boosting = false
        message = nil
        logLine("boost off (\(reason))")
    }

    private func writeStatus(_ settings: Settings) {
        let fanStatus = fans.map { f in
            FanStatus(index: f.index,
                      rpm: smc.rpm(f.index) ?? 0,
                      target: smc.target(f.index) ?? 0,
                      minRPM: f.minRPM,
                      maxRPM: f.maxRPM,
                      forced: smc.isForced(f.index))
        }
        let status = Status(time: Date().timeIntervalSince1970,
                            chipTemp: smoothed,
                            fans: fanStatus,
                            boosting: boosting,
                            mode: settings.mode,
                            startTemp: settings.startTemp,
                            message: message)
        if let data = try? JSONEncoder().encode(status) {
            try? data.write(to: URL(fileURLWithPath: FanCoolPaths.status), options: .atomic)
        }
    }
}

func logLine(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(f.string(from: Date()))  \(s)")
}
