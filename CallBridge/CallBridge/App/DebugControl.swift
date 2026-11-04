import Cocoa
import Foundation

// MARK: - Debug Control

/// Test hook for driving the status menu without a mouse (remote UAT over SSH, where
/// there is no Accessibility grant and no screen capture). Off unless the app is started
/// with CALLBRIDGE_DEBUG_CONTROL=1, so a normal launch never reads the folder.
///
/// Write one command to /tmp/callbridge-ctl/cmd:
///   dump                      the rebuilt menu tree goes to /tmp/callbridge-ctl/menu.txt
///   click Mislukt (1) > X > Opnieuw proberen
///                             performs the item at that title path (a prefix match per level)
/// The answer of the last command goes to /tmp/callbridge-ctl/out.txt.
final class DebugControl {
    static let dir = "/tmp/callbridge-ctl"
    private var timer: Timer?
    private weak var app: AppDelegate?

    static var enabled: Bool { ProcessInfo.processInfo.environment["CALLBRIDGE_DEBUG_CONTROL"] == "1" }

    init(app: AppDelegate) { self.app = app }

    func start() {
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        debugLog("DebugControl: on, commands in \(Self.dir)/cmd")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let cmdPath = Self.dir + "/cmd"
        guard let raw = try? String(contentsOfFile: cmdPath, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: cmdPath)
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let app = app, let menu = app.statusItem?.menu else { return }
        // Same path as a real menu open: rebuild, then kick and poll the DSH queue.
        app.menuNeedsUpdate(menu)
        var out = ""
        if cmd == "dump" {
            out = Self.render(menu, depth: 0)
            write("menu.txt", out)
        } else if cmd.hasPrefix("click ") {
            let path = cmd.dropFirst(6).components(separatedBy: " > ").map { $0.trimmingCharacters(in: .whitespaces) }
            if let item = Self.find(path, in: menu), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
                out = "clicked \(item.title)"
            } else {
                out = "not found: \(path.joined(separator: " > "))"
            }
        } else {
            out = "unknown command"
        }
        debugLog("DebugControl: \(cmd) -> \(out.split(separator: "\n").first ?? "")")
        write("out.txt", out)
    }

    private func write(_ name: String, _ text: String) {
        try? text.write(toFile: Self.dir + "/" + name, atomically: true, encoding: .utf8)
    }

    private static func render(_ menu: NSMenu, depth: Int) -> String {
        var s = ""
        for item in menu.items {
            let pad = String(repeating: "  ", count: depth)
            if item.isSeparatorItem { s += pad + "---\n"; continue }
            s += pad + item.title + (item.isEnabled ? "" : "  [disabled]") + "\n"
            if let sub = item.submenu { s += render(sub, depth: depth + 1) }
        }
        return s
    }

    private static func find(_ path: [String], in menu: NSMenu) -> NSMenuItem? {
        guard let first = path.first else { return nil }
        guard let item = menu.items.first(where: { !$0.isSeparatorItem && $0.title.hasPrefix(first) }) else { return nil }
        if path.count == 1 { return item }
        guard let sub = item.submenu else { return nil }
        return find(Array(path.dropFirst()), in: sub)
    }
}
