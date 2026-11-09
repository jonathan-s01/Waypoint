// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's Anywhere (plan 4.11, the part that needs no language model): one list, narrowed and ranked as you type,
// of the apps you could switch to or open, the front app's menu commands, what can be done to the item you are on,
// the front app's parts of the window, and Waypoint's own commands. Return runs one, Escape closes the list; the
// list never moves focus, so the focus is where it was. Which result fits and what is risky is AnywhereRanking.swift.
import AppKit
import ApplicationServices

@MainActor
enum Anywhere {
    /// A result and what choosing it does.
    struct Candidate {
        let entry: AnywhereEntry
        let run: () -> Void
    }

    private static let recentKey = "waypoint.anywhere.recent"
    private static var pending: (id: String, at: Date)?
    private static var installedCache: (at: Date, apps: [(name: String, path: String)])?

    static var recents: [String] { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }

    static func open() {
        let pid = API.focusPid
        let running = runningApps()
        var all: [Candidate] = []
        all += itemActions()
        all += regions(pid: pid)
        all += running
        all += menuCommands(pid: pid)
        all += waypointCommands()
        all += installedApps(excluding: Set(running.map(\.entry.id)))
        guard !all.isEmpty else { Tones.edge(); return }
        Log.io("anywhere: \(all.count) results")
        present(all)
    }

    // MARK: The list

    private static func present(_ all: [Candidate]) {
        let entries = all.map(\.entry)
        pending = nil
        func items(_ order: [Int]) -> [MenuItem] { order.map { item(all[$0]) } }
        let title = String(localized: "Anywhere", comment: "Waypoint's list of apps, menu commands and commands that you search by typing")
        TurnOverMenu.shared.openChooser(verbatim: title, items: items(AnywhereRanking.rank(query: "", entries: entries, recents: recents)))
        TurnOverMenu.shared.filterMatcher = { text in items(AnywhereRanking.rank(query: text, entries: entries, recents: recents)) }
    }

    private static func item(_ c: Candidate) -> MenuItem {
        let spoken = AnywhereRanking.spokenTitle(c.entry)
        if AnywhereRanking.isRisky(name: c.entry.name, kind: c.entry.kind) {
            return MenuItem(verbatim: spoken, .select { confirmOrRun(c) }, hint: c.entry.place)
        }
        return MenuItem(verbatim: spoken, .action { run(c) }, hint: c.entry.place)
    }

    private static func run(_ c: Candidate) {
        pending = nil
        UserDefaults.standard.set(AnywhereRanking.recordRecent(c.entry.id, in: recents), forKey: recentKey)
        Log.io("anywhere: ran a \(c.entry.kind.spoken) \"\(Log.words(c.entry.name))\"")
        c.run()
    }

    /// Delete, Quit and the like: the first Return only says so, the second (within a few seconds) runs it.
    private static func confirmOrRun(_ c: Candidate) {
        let now = Date()
        if AnywhereRanking.isConfirmation(pendingID: pending?.id, pendingAt: pending?.at, id: c.entry.id, now: now) {
            TurnOverMenu.shared.close()
            run(c)
            return
        }
        pending = (c.entry.id, now)
        Speech.speakMessage(String(localized: "press Return again to confirm", comment: "Spoken after choosing a risky command (Delete, Quit): Return again runs it"))
    }

    // MARK: Apps

    private static func runningApps() -> [Candidate] {
        let own = ProcessInfo.processInfo.processIdentifier
        let place = String(localized: "running", comment: "Anywhere: an app that is already open, said after a pause on it")
        var out: [Candidate] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != own {
            guard let name = app.localizedName, let path = app.bundleURL?.path else { continue }
            let pid = app.processIdentifier
            out.append(Candidate(entry: AnywhereEntry(id: "app:" + path, name: name, kind: .app, place: place)) {
                ApplicationChooser.switchTo(ApplicationChooser.Entry(pid: pid, name: name, windows: []), window: nil)
            })
        }
        return out
    }

    /// The top level of the Applications folders, read once in a while (a listing of a few hundred names).
    private static func installedApps(excluding running: Set<String>) -> [Candidate] {
        let place = String(localized: "installed", comment: "Anywhere: an app that is not open yet, said after a pause on it")
        var out: [Candidate] = []
        for app in installed() where !running.contains("app:" + app.path) {
            let name = app.name, path = app.path
            out.append(Candidate(entry: AnywhereEntry(id: "app:" + path, name: name, kind: .app, place: place)) {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { onMain { Speech.speakMessage(String(localized: "could not open \(name): \(error.localizedDescription)", comment: "An app could not open: the app, then why")) } }
                }
            })
        }
        return out
    }

    private static func installed() -> [(name: String, path: String)] {
        if let c = installedCache, Date().timeIntervalSince(c.at) < 600 { return c.apps }
        var apps: [(name: String, path: String)] = []
        var seen = Set<String>()
        for dir in ["/Applications", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities"] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".app") {
                let path = dir + "/" + file
                if seen.insert(path).inserted { apps.append((name: (file as NSString).deletingPathExtension, path: path)) }
            }
        }
        installedCache = (Date(), apps)
        return apps
    }

    // MARK: Menu commands

    /// The front app's menus, walked as the menu bar search does (up to a second on main; one pass per opening).
    private static func menuCommands(pid: pid_t?) -> [Candidate] {
        guard let pid, let found = MenuBarList.allItems(pid: pid, budget: 1.0) else { return [] }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? String(pid)
        return found.map { f in
            let id = "menu:\(bundle):\(f.path.joined(separator: ">"))>\(f.title)"
            return Candidate(entry: AnywhereEntry(id: id, name: f.title, kind: .menuCommand, shortcut: f.shortcut, place: f.place, enabled: f.enabled), run: f.press)
        }
    }

    // MARK: The item you are on

    private static func itemActions() -> [Candidate] {
        guard let target = ItemActions.resolve() else { return [] }
        var out: [Candidate] = []
        var seen = Set<String>()
        for a in target.ownActions where seen.insert(a.title.lowercased()).inserted {
            let owner = a.owner, action = a.action
            out.append(Candidate(entry: AnywhereEntry(id: "action:" + a.title.lowercased(), name: a.title, kind: .action)) {
                _ = AXUIElementPerformAction(owner, action as CFString)
            })
        }
        for b in target.buttons where seen.insert(b.title.lowercased()).inserted {
            let button = b.element
            out.append(Candidate(entry: AnywhereEntry(id: "action:" + b.title.lowercased(), name: b.title, kind: .action)) {
                _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
            })
        }
        return out
    }

    // MARK: Parts of the window

    /// The front app's recipe parts, reached through its own "Straight to" commands (Command Control 1 to 9), as the
    /// module keeps its PanesView private: so the first nine parts, and none where the app has no panes recipe.
    private static func regions(pid: pid_t?) -> [Candidate] {
        guard let pid, let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              let parts = Recipes.recipe(for: bundle)?.view.panes?.parts else { return [] }
        let module = AppModuleHandler.shared.appModule(for: pid)
        var out: [Candidate] = []
        for (i, part) in parts.prefix(9).enumerated() {
            guard let script = module.script(named: "panes_part\(i + 1)"),
                  let gesture = KeyboardGesture(identifier: "kb:control+command+\(i + 1)") else { continue }
            out.append(Candidate(entry: AnywhereEntry(id: "region:\(bundle):\(part.name)", name: part.name, kind: .region,
                                                      shortcut: GlobalCommands.spoken("kb:control+command+\(i + 1)"))) {
                script.handler(gesture)
            })
        }
        return out
    }

    // MARK: Waypoint's commands

    /// Commands that have a key with a modifier in this keyboard style and here, as the key list shows them: what a
    /// bare key does in a list or a page is not offered. A command with no key is left out, as running it needs one.
    private static func waypointCommands() -> [Candidate] {
        var owners: [ScriptableObject] = []
        if let pid = API.focusPid { owners.append(AppModuleHandler.shared.appModule(for: pid)) }
        if let d = API.focusTreeInterceptor { owners.append(d) }
        if let f = API.focusObject { owners.append(f); owners.append(contentsOf: API.focusAncestors) }
        owners.append(contentsOf: GlobalPluginHandler.shared.plugins)
        owners.append(GlobalCommands.shared)
        let layout = "kb(\(config.keyboard.layout)):"
        var seenBriefs = Set<String>()
        var out: [Candidate] = []
        for owner in owners {
            for (id, s) in owner.allBindings where !id.hasPrefix("kb(") || id.hasPrefix(layout) {
                let plain = id.replacingOccurrences(of: layout, with: "kb:")
                guard AnywhereRanking.isChord(plain), let gesture = KeyboardGesture(identifier: plain),
                      s.name != "anywhere", !s.name.hasPrefix("test_"), !s.name.hasPrefix("panes_part"), !s.description.isEmpty,
                      ScriptHandler.findScript(for: gesture) === s, seenBriefs.insert(s.brief.lowercased()).inserted else { continue }
                out.append(Candidate(entry: AnywhereEntry(id: "cmd:" + s.name, name: s.brief, kind: .command,
                                                          shortcut: GlobalCommands.spoken(plain), place: s.categoryName)) {
                    ScriptHandler.queueScript(s, gesture: gesture)
                })
            }
        }
        return out
    }
}

/// VO-Command-A: the Anywhere list. Free in both keyboard styles (checked against the VoiceOver key chords, the letter
/// jumps and the web search keys, 8 Nov 2026), so it can be rebound in the keyboard commands editor if it clashes.
final class AnywherePlugin: GlobalPlugin {
    required init() {
        super.init()
        script("anywhere", String(localized: "Anywhere: type to find an app, a menu command, an action or a Waypoint command, and run it", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:turnover+command+a"], category: "Waypoint") { _ in Anywhere.open() }
    }
}
