import Foundation

// Shared between the menu bar app and the root helper.
//  - settings.json lives in /Users/Shared so the (non-root) app can write it.
//    The helper only ever reads it and clamps every value.
//  - status.json lives in a root-owned folder so only the helper can write it.
enum FanCoolPaths {
    static let settingsDir = "/Users/Shared/FanCool"
    static let settings = settingsDir + "/settings.json"
    static let statusDir = "/Library/Application Support/FanCool"
    static let status = statusDir + "/status.json"
}

enum FanMode: String, Codable {
    case auto   // boost only when the chip gets hot
    case max    // all fans at maximum
    case off    // never touch the fans, macOS decides
}

struct Settings: Codable, Equatable {
    var mode: FanMode = .auto
    var startTemp: Double = 75   // °C where boosting begins

    static let allowedStartTemps: [Double] = [60, 65, 70, 75, 80, 85]

    static func load() -> Settings {
        guard let data = FileManager.default.contents(atPath: FanCoolPaths.settings),
              var s = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        if !s.startTemp.isFinite { s.startTemp = 75 }
        s.startTemp = min(max(s.startTemp, 50), 90)
        return s
    }

    func save() throws {
        try FileManager.default.createDirectory(atPath: FanCoolPaths.settingsDir,
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: URL(fileURLWithPath: FanCoolPaths.settings), options: .atomic)
    }
}

struct FanStatus: Codable {
    var index: Int
    var rpm: Double
    var target: Double
    var minRPM: Double
    var maxRPM: Double
    var forced: Bool
}

struct Status: Codable {
    var time: Double              // seconds since 1970, used to detect a dead helper
    var chipTemp: Double?         // smoothed hottest chip sensor, °C
    var fans: [FanStatus]
    var boosting: Bool
    var mode: FanMode
    var startTemp: Double
    var message: String?

    static func load() -> Status? {
        guard let data = FileManager.default.contents(atPath: FanCoolPaths.status) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }
}
