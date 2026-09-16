// Signal Menu — the visible half of the keeper.
//
// The daemon owns awdl0 and writes a status file; this app only reads that file
// and writes the request file (ADR-005, ADR-009). It holds no privileges and is
// useless on its own — deliberately, so that the interface has a single owner.

import Cocoa

private let statusPath = "/usr/local/var/run/signal/status"
private let requestPath = "/usr/local/var/run/signal/request"
private let logPath = "/usr/local/var/log/signal/awdl.log"
private let refreshInterval: TimeInterval = 2

struct KeeperStatus {
    let awdl: String
    let since: Int
    let windowUntil: Int
    let interceptsToday: Int
    let reason: String
    let updated: Int

    var isUp: Bool { awdl == "up" }
    var windowIsOpen: Bool { windowUntil > Int(Date().timeIntervalSince1970) }
    var isStale: Bool { Int(Date().timeIntervalSince1970) - updated > 10 }
    var windowRemaining: Int { max(0, windowUntil - Int(Date().timeIntervalSince1970)) }
    var upFor: Int { since > 0 ? Int(Date().timeIntervalSince1970) - since : 0 }

    static func read() -> KeeperStatus? {
        guard let data = FileManager.default.contents(atPath: statusPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return KeeperStatus(
            awdl: object["awdl"] as? String ?? "?",
            since: object["since"] as? Int ?? 0,
            windowUntil: object["window_until"] as? Int ?? 0,
            interceptsToday: object["intercepts_today"] as? Int ?? 0,
            reason: object["reason"] as? String ?? "",
            updated: object["updated"] as? Int ?? 0
        )
    }
}

func humanDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) с" }
    if seconds < 3600 { return "\(seconds / 60) м \(seconds % 60) с" }
    return "\(seconds / 3600) ч \((seconds % 3600) / 60) м"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func symbol(_ name: String, fallback: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "Signal")
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "Signal")
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        guard let status = KeeperStatus.read(), !status.isStale else {
            button.image = symbol("exclamationmark.triangle", fallback: "wifi.exclamationmark")
            button.toolTip = "Signal: сторож не отвечает"
            return
        }
        if status.isUp {
            // Distinguishing the deliberate window from an intercepted rise is
            // the whole point of the icon: one is expected, the other is a cost.
            button.image = status.windowIsOpen
                ? symbol("antenna.radiowaves.left.and.right.circle.fill", fallback: "antenna.radiowaves.left.and.right")
                : symbol("antenna.radiowaves.left.and.right", fallback: "wifi")
            button.toolTip = "AWDL поднят — \(status.reason)"
        } else {
            button.image = symbol("antenna.radiowaves.left.and.right.slash", fallback: "wifi.slash")
            button.toolTip = "AWDL погашен, перехватов сегодня: \(status.interceptsToday)"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = KeeperStatus.read()

        if status == nil || status!.isStale {
            menu.addItem(disabled("Сторож не отвечает"))
            menu.addItem(disabled("signal install — поставить"))
        } else if let status = status {
            if status.isUp {
                menu.addItem(disabled("AWDL поднят \(humanDuration(status.upFor)) — \(status.reason)"))
            } else {
                menu.addItem(disabled("AWDL погашен — радио чистое"))
            }
            menu.addItem(disabled("Перехватов сегодня: \(status.interceptsToday)"))
            if status.windowIsOpen {
                menu.addItem(disabled("Окно закроется через \(humanDuration(status.windowRemaining))"))
            }
        }

        menu.addItem(.separator())
        menu.addItem(action("Открыть AirDrop на 5 минут", #selector(openFive)))
        menu.addItem(action("Открыть на 15 минут", #selector(openFifteen)))
        if status?.windowIsOpen == true {
            menu.addItem(action("Закрыть окно сейчас", #selector(closeWindow)))
        }
        menu.addItem(.separator())
        menu.addItem(action("Журнал сторожа", #selector(openLog)))
        menu.addItem(action("Выйти", #selector(quit)))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func write(request: Int) {
        // Not atomic on purpose: the state directory belongs to root, so an
        // atomic write (temp file + rename inside that directory) would fail.
        // The request file itself is ours to write (ADR-005).
        try? String(request).write(toFile: requestPath, atomically: false, encoding: .utf8)
        refresh()
    }

    @objc private func openFive() { write(request: Int(Date().timeIntervalSince1970) + 5 * 60) }
    @objc private func openFifteen() { write(request: Int(Date().timeIntervalSince1970) + 15 * 60) }
    @objc private func closeWindow() { write(request: 0) }
    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc private func quit() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
