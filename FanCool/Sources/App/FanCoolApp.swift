import AppKit

// FanCool menu bar app. It never touches the hardware: it reads status.json
// written by the root helper and writes settings.json for it to pick up.

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "FanCool")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
        let t = Timer(timeInterval: 3, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: status

    private func currentStatus() -> Status? {
        guard let s = Status.load(), Date().timeIntervalSince1970 - s.time < 15 else { return nil }
        return s
    }

    @objc private func refresh() {
        guard let button = statusItem.button else { return }
        guard let s = currentStatus() else {
            button.title = statusItem.button?.image == nil ? "Fan --" : " --"
            return
        }
        let temp = s.chipTemp.map { "\(Int($0.rounded()))°" } ?? "--"
        let prefix = button.image == nil ? "Fan " : " "
        button.title = prefix + temp + (s.boosting ? "↑" : "")
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = Settings.load()
        let status = currentStatus()

        if let s = status {
            let temp = s.chipTemp.map { String(format: "%.0f °C", $0) } ?? "unavailable"
            menu.addItem(info("Chip temperature: \(temp)"))
            for f in s.fans {
                var line = "Fan \(f.index + 1): \(Int(f.rpm)) rpm"
                if f.forced { line += "  (target \(Int(f.target)))" }
                menu.addItem(info(line))
            }
            let state: String
            if let m = s.message { state = "⚠︎ " + m }
            else if s.boosting { state = s.mode == .max ? "Fans at maximum" : "Boosting cooling" }
            else { state = "macOS is controlling the fans" }
            menu.addItem(info(state))
        } else {
            menu.addItem(info("⚠︎ Helper not running"))
            menu.addItem(info("Run install.sh again to fix"))
        }

        menu.addItem(.separator())
        menu.addItem(modeItem("Auto boost when hot", .auto, settings))
        menu.addItem(modeItem("Max fans", .max, settings))
        menu.addItem(modeItem("Off (macOS default)", .off, settings))

        let startItem = NSMenuItem(title: "Start boosting at", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for t in Settings.allowedStartTemps {
            let item = NSMenuItem(title: "\(Int(t)) °C", action: #selector(setStart(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t
            item.state = settings.startTemp == t ? .on : .off
            sub.addItem(item)
        }
        startItem.submenu = sub
        startItem.isEnabled = settings.mode == .auto
        menu.addItem(startItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FanCool menu", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func modeItem(_ title: String, _ mode: FanMode, _ settings: Settings) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mode.rawValue
        item.state = settings.mode == mode ? .on : .off
        return item
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = FanMode(rawValue: raw) else { return }
        var s = Settings.load()
        s.mode = mode
        save(s)
    }

    @objc private func setStart(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? Double else { return }
        var s = Settings.load()
        s.startTemp = t
        save(s)
    }

    private func save(_ s: Settings) {
        do { try s.save() } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save FanCool settings"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        // The helper picks the change up on its next 2-second tick.
        perform(#selector(refresh), with: nil, afterDelay: 2.5)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
