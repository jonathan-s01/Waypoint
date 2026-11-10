import AppKit
import ApplicationServices

// The launcher (Waypoint, Nov 2026): hold Right Command and press a letter to open an app, run a shell command, open a
// URL or file, or run any Waypoint command; hold Right Command and Right Option for a second table of keys. What each
// key does is data (LauncherStore.swift, launcher.json); this file finds the binding for a key press and does it.
//
// How a key is taken: the plugin's `script(for:)` answers for a chord with a binding, as the review layer's does. The
// key-down is then a taken key, and the keyboard tap swallows the matching key-up by itself. The lookup runs on the main
// thread, where the table lives, so the keyboard thread reads nothing of the launcher's. A chord with no binding
// (an unmapped letter, extra modifier keys) finds no script and goes through unchanged. While Waypoint is handed to
// VoiceOver the tap lets every key pass and the plugin answers nobody either (Core.active).

/// What a binding does, apart from deciding which one: the real one opens apps and runs commands; tests give their own.
public protocol LauncherExecutor: AnyObject {
    func openApp(bundle: String, name: String)
    func runShell(_ command: String, timeout: Double, label: String)
    func open(_ target: String, label: String)
    func runCommand(_ name: String, gesture: KeyboardGesture)
}

public enum Launcher {
    static let enabledKey = "waypoint.launcher.enabled"
    static let hold1Key = "waypoint.launcher.hold1", hold2Key = "waypoint.launcher.hold2"

    /// On unless switched off: it is a held chord, so it cannot get stuck.
    public static var enabled: Bool = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: enabledKey)
            if !enabled { stopRepeating("the launcher was switched off") }
        }
    }

    public static var holds: LauncherLogic.Holds = {
        let d = UserDefaults.standard, std = LauncherLogic.Holds.standard
        func bits(_ k: String, _ fallback: UInt) -> UInt { d.object(forKey: k).flatMap { ($0 as? NSNumber)?.uintValue } ?? fallback }
        return .init(hold1: bits(hold1Key, std.hold1), hold2: bits(hold2Key, std.hold2))
    }()

    public static let store = LauncherStore(url: AppPaths.file("launcher.json"))
    /// What runs a binding; tests put their own here.
    public static var executor: LauncherExecutor = LauncherActions.shared

    // MARK: Which key

    /// The question every key asks, so it must be cheap: a key without the chord costs one flag test and a compare.
    public static func decision(for g: KeyboardGesture, store: LauncherStore? = nil, holds: LauncherLogic.Holds? = nil, enabled: Bool? = nil) -> LauncherLogic.Match? {
        guard enabled ?? Launcher.enabled else { return nil }
        let h = holds ?? Launcher.holds
        let flags = UInt(g.flags.rawValue), turnOver = g.modifiers.contains(.turnover)
        guard LauncherLogic.layer(flags: flags, holds: h, turnOverKey: turnOver) != nil else { return nil }
        let s = store ?? Launcher.store
        s.reloadIfChanged()
        return LauncherLogic.match(flags: flags, keyName: g.keyName, turnOverKey: turnOver, holds: h, table: s.table)
    }

    /// True when the key is a launcher key that leaves speech playing (the volume keys); any other key cuts speech.
    public static func keepsSpeech(_ g: KeyboardGesture, store: LauncherStore? = nil, holds: LauncherLogic.Holds? = nil, enabled: Bool? = nil) -> Bool {
        decision(for: g, store: store, holds: holds, enabled: enabled)?.binding.keepSpeech ?? false
    }

    // MARK: Running a key

    /// The script for a taken key. A key held down repeats: it stays taken, and does not run again here (a binding
    /// with a repeat rate is repeated by the repeater, on its own clock, until the key is let go).
    public static func run(_ g: KeyboardGesture, store: LauncherStore? = nil, holds: LauncherLogic.Holds? = nil, enabled: Bool? = nil, executor: LauncherExecutor? = nil, repeater: LauncherRepeater? = nil) {
        guard !g.isRepeat, let match = decision(for: g, store: store, holds: holds, enabled: enabled) else { return }
        Log.io("launcher: layer \(match.layer) \(match.binding.key) → \(match.binding.kind.rawValue) \(match.binding.label)")
        let exec = executor ?? Launcher.executor
        dispatch(match.binding, executor: exec, gesture: g)
        if LauncherLogic.repeatTiming(for: match.binding) != nil {
            let chord = UInt(g.flags.rawValue) & LauncherLogic.Device.all
            (repeater ?? LauncherRepeater.shared).begin(keyCode: g.keyCode, chord: chord, binding: match.binding) {
                dispatch(match.binding, executor: exec, gesture: g)
            }
        }
    }

    /// Stops any key repeating (the launcher switched off, the keyboard's tap restarted).
    public static func stopRepeating(_ why: String) {
        LauncherRepeater.shared.stop(why)
    }

    public static func dispatch(_ b: LauncherLogic.Binding, executor: LauncherExecutor, gesture: KeyboardGesture) {
        switch b.kind {
        case .app: executor.openApp(bundle: b.bundle, name: b.name)
        case .shell: executor.runShell(b.target, timeout: LauncherLogic.timeout(for: b), label: b.name)
        case .open: executor.open(b.target, label: b.name)
        case .command: executor.runCommand(b.target, gesture: gesture)
        }
    }

    // MARK: Commands

    static func toggleEnabled() {
        enabled.toggle()
        Speech.speakMessage(enabled ? String(localized: "launcher enabled", comment: "Spoken message") : String(localized: "launcher disabled", comment: "Spoken message"))
    }

    static func capture(layer: Int) {
        let prompt = layer == 2
            ? String(localized: "Hold the keys that switch launcher layer 2 on, then press any letter", comment: "Spoken message: waiting for a key chord")
            : String(localized: "Hold the keys that switch the launcher on, then press any letter", comment: "Spoken message: waiting for a key chord")
        TurnOverMenu.captureKey(prompt: prompt) { g in
            let bits = UInt(g.flags.rawValue) & LauncherLogic.Device.all
            guard bits != 0 else {
                Speech.speakMessage(String(localized: "No modifier key was held; nothing changed", comment: "Spoken message"))
                return
            }
            guard LauncherLogic.isUsableHold(bits) else {
                Speech.speakMessage(String(localized: "Hold Command, Option or Control, with or without Shift; nothing changed", comment: "Spoken message: the launcher cannot be switched on by Shift alone"))
                return
            }
            var h = holds
            if layer == 2 { h.hold2 = bits } else { h.hold1 = bits }
            guard h.hold1 != h.hold2 else {
                Speech.speakMessage(String(localized: "Those keys are already the other layer's; nothing changed", comment: "Spoken message"))
                return
            }
            setHolds(h)
            Speech.speakMessage(String(localized: "saved", comment: "Spoken message"))
        }
    }

    public static func setHolds(_ h: LauncherLogic.Holds) {
        stopRepeating("the held keys changed")
        holds = h
        let d = UserDefaults.standard
        d.set(NSNumber(value: h.hold1), forKey: hold1Key)
        d.set(NSNumber(value: h.hold2), forKey: hold2Key)
        Log.io("launcher: hold 1 \(h.hold1), hold 2 \(h.hold2)")
    }

    static func resetKeys() {
        setHolds(.standard)
        Speech.speakMessage(String(localized: "launcher keys back to Right Command, and Right Command with Right Option", comment: "Spoken message"))
    }

    static func reload() {
        stopRepeating("the file was read again")
        store.reload()
        switch store.status {
        case .corrupt:
            Speech.speakMessage(String(localized: "The launcher file could not be read; the default keys are in use, and the file is untouched", comment: "Spoken message"))
        case .ok, .seeded, .newer:
            let n = store.table.layer1.count + store.table.layer2.count
            let skipped = store.skipped.count
            var said = String(localized: "launcher reloaded, \(String(n)) keys", comment: "Spoken message: how many keys the launcher has now")
            if skipped > 0 { said += ", " + String(localized: "\(String(skipped)) entries skipped, see the log", comment: "Spoken message: entries in the launcher file that could not be used") }
            Speech.speakMessage(said)
        }
    }

    /// The keys, as a list to move through; choosing one runs it.
    static func list() {
        var items: [MenuItem] = []
        for layer in [1, 2] {
            let hold = LauncherLogic.holdName(layer == 2 ? holds.hold2 : holds.hold1)
            for b in store.table.bindings(layer: layer) {
                let title = "\(hold) \(b.key), \(b.label)"
                items.append(MenuItem(verbatim: title, .action { dispatch(b, executor: executor, gesture: KeyboardGesture(identifier: "kb:turnover+space")!) }, hint: b.kind == .app ? nil : b.kind.rawValue))
            }
        }
        if items.isEmpty { Speech.speakMessage(String(localized: "The launcher has no keys", comment: "Spoken message")); return }
        Log.io("launcher: list of \(items.count) keys")
        TurnOverMenu.shared.openList(verbatim: String(localized: "Launcher", comment: "A list's title"), items: items)
    }
}

// MARK: The real actions

/// Opens apps, runs commands and so on, for real.
final class LauncherActions: LauncherExecutor {
    static let shared = LauncherActions()

    func openApp(bundle: String, name: String) {
        let wanted = name.isEmpty ? bundle : name
        guard let app = LauncherApps.resolve(bundle: bundle, name: name) else {
            Log.info("launcher: \(wanted) is not installed")
            Speech.speakMessage(String(localized: "\(wanted) is not installed", comment: "An app is not installed: %@ is the app"))
            return
        }
        let shown = name.isEmpty ? app.displayName : name
        guard let running = LauncherApps.running(at: app.url) else {
            Speech.speakMessage(String(localized: "Opening \(shown)", comment: "Spoken message: an app is being opened, %@ is its name"))
            launch(app.url, shown: shown)
            return
        }
        let pid = running.processIdentifier
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            cycleWindow(pid: pid, shown: shown)
            return
        }
        Speech.speakMessage(shown)
        if AXUIElementCreateApplication(pid).elements(kAXWindowsAttribute).isEmpty {
            launch(app.url, shown: shown)   // no window to come forward: opening it again makes one, as clicking its Dock icon does
        } else {
            ApplicationChooser.switchTo(.init(pid: pid, name: shown, windows: []), window: nil)
        }
    }

    private func launch(_ url: URL, shown: String) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let why = error?.localizedDescription else { return }
            onMain {
                Log.warning("launcher: \(shown) did not open: \(why)")
                Speech.speakMessage(String(localized: "could not open \(shown): \(why)", comment: "An app could not open: the app, then why"))
            }
        }
    }

    /// The app is in front already: bring its back window forward, as Command Grave Accent does. One window, or none:
    /// nothing moves, and the app's name is said so the key is known to have worked.
    private func cycleWindow(pid: pid_t, shown: String) {
        let ax = AXUIElementCreateApplication(pid)
        let windows = ax.elements(kAXWindowsAttribute).filter { w in
            let minimized = (w.attr(kAXMinimizedAttribute) as? NSNumber)?.boolValue ?? false
            let subrole = w.string(kAXSubroleAttribute)
            return !minimized && (subrole == nil || subrole == kAXStandardWindowSubrole as String || subrole == "AXDialog")
        }
        let focused = ax.element(kAXFocusedWindowAttribute) ?? ax.element(kAXMainWindowAttribute)
        let current = focused.flatMap { f in windows.firstIndex { CFEqual($0, f) } }
        guard let next = LauncherLogic.nextWindowIndex(count: windows.count, current: current) else {
            Speech.speakMessage(shown)
            return
        }
        Log.io("launcher: \(shown) is in front; window \(next + 1) of \(windows.count)")
        ApplicationChooser.switchTo(.init(pid: pid, name: shown, windows: []), window: windows[next])
    }

    func runShell(_ command: String, timeout: Double, label: String) {
        let shown = label.isEmpty ? String(localized: "command", comment: "What a launcher shell command is called when it has no name") : label
        Log.io("launcher: shell command for \(shown), up to \(Int(timeout)) s")
        LauncherShell.run(command, timeout: timeout) { result in
            onMain {
                switch result {
                case .success:
                    Log.io("launcher: \(shown) finished")
                case .failed(let status):
                    Log.warning("launcher: \(shown) exited with \(status)")
                    Speech.speakMessage(String(localized: "\(shown) failed, exit status \(String(status))", comment: "Spoken message: a launcher shell command failed; the name, then its exit status"))
                case .timedOut:
                    Log.warning("launcher: \(shown) did not finish in \(Int(timeout)) s and was stopped")
                    Speech.speakMessage(String(localized: "\(shown) took too long and was stopped", comment: "Spoken message: a launcher shell command ran past its time limit"))
                case .couldNotStart(let why):
                    Log.warning("launcher: \(shown) could not start: \(why)")
                    Speech.speakMessage(String(localized: "\(shown) could not start", comment: "Spoken message: a launcher shell command could not be run"))
                }
            }
        }
    }

    func open(_ target: String, label: String) {
        let text = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = label.isEmpty ? text : label
        guard let url = LauncherApps.url(for: text) else {
            Speech.speakMessage(String(localized: "\(shown) was not found", comment: "Spoken message: a launcher file or folder is not there; %@ names it"))
            Log.info("launcher: \(text) was not found")
            return
        }
        Speech.speakMessage(String(localized: "Opening \(shown)", comment: "Spoken message: something is being opened, %@ is its name"))
        if !NSWorkspace.shared.open(url) {
            Speech.speakMessage(String(localized: "could not open \(shown)", comment: "Spoken message: something could not be opened"))
        }
    }

    func runCommand(_ name: String, gesture: KeyboardGesture) {
        // The launcher's own key could run itself forever.
        guard !name.hasPrefix("launcherKey"), let script = ScriptHandler.findScript(named: name) else {
            Log.info("launcher: no command named \(name) here")
            Speech.speakMessage(String(localized: "No command named \(name)", comment: "Spoken message: a launcher key names a command that does not exist here"))
            return
        }
        script.handler(gesture)
    }
}

/// Finding apps and things to open.
enum LauncherApps {
    struct Resolved { let url: URL; let displayName: String }

    /// By bundle identifier, else by name among the running apps and the usual folders.
    static func resolve(bundle: String, name: String) -> Resolved? {
        let fm = FileManager.default
        if !bundle.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return Resolved(url: url, displayName: url.deletingPathExtension().lastPathComponent)
        }
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.caseInsensitiveCompare(wanted) == .orderedSame && $0.bundleURL != nil }), let url = app.bundleURL {
            return Resolved(url: url, displayName: wanted)
        }
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        for folder in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", home] {
            let path = folder + "/" + (wanted.hasSuffix(".app") ? wanted : wanted + ".app")
            if fm.fileExists(atPath: path) { return Resolved(url: URL(fileURLWithPath: path), displayName: wanted) }
        }
        return nil
    }

    static func running(at url: URL) -> NSRunningApplication? {
        let target = url.standardizedFileURL
        return NSWorkspace.shared.runningApplications.first { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == target }
    }

    /// A URL as written, or a path (with ~) that exists.
    static func url(for text: String) -> URL? {
        if text.contains("://") || text.lowercased().hasPrefix("mailto:") || text.lowercased().hasPrefix("tel:") { return URL(string: text) }
        let path = (text as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}

/// A shell command, run off the main thread with a time limit.
nonisolated enum LauncherShell {
    enum Result: Sendable, Equatable {
        case success
        case failed(Int32)
        case timedOut
        case couldNotStart(String)
    }

    /// Runs `/bin/zsh -c command` on a background queue and calls back there. Its output is not kept (a command that
    /// prints a lot must not fill a pipe nobody reads). A command still running at the limit is asked to stop, then killed.
    static func run(_ command: String, timeout: Double, completion: @escaping @Sendable (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // An app has the short PATH the system gives apps: add where Homebrew's tools are.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
            process.environment = env
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do { try process.run() } catch { completion(.couldNotStart(error.localizedDescription)); return }
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
                completion(.timedOut)
                return
            }
            completion(process.terminationStatus == 0 ? .success : .failed(process.terminationStatus))
        }
    }
}

// MARK: The plugin

/// The launcher's commands, in the key list under Waypoint. Its keys are found by the chord, not listed one by one.
final class LauncherPlugin: GlobalPlugin {
    private var launcherKey: Script!

    required init() {
        super.init()
        _ = Launcher.store   // reads (or creates) the file now, so a problem with it is in the log from the start
        let category = "Waypoint"
        launcherKey = Script(name: "launcherKey", description: String(localized: "A key of the launcher: opens an app or runs an action chosen for the letter", comment: "A command, as the key list and keyboard help say it"), category: category, owner: self) { g in
            Launcher.run(g)
        }
        script("launcherEnable", String(localized: "Turns the launcher (hold Right Command and press a letter to open an app) on or off", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            Launcher.toggleEnabled()
        }
        script("launcherSetHold1", String(localized: "Chooses the keys held for launcher layer 1 (now Right Command)", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            Launcher.capture(layer: 1)
        }
        script("launcherSetHold2", String(localized: "Chooses the keys held for launcher layer 2 (now Right Command and Right Option)", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            Launcher.capture(layer: 2)
        }
        script("launcherResetKeys", String(localized: "Puts the launcher's held keys back to Right Command, and Right Command with Right Option", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            Launcher.resetKeys()
        }
        script("launcherReload", String(localized: "Reads the launcher's file again after it was edited by hand", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            Launcher.reload()
        }
        script("launcherList", String(localized: "Lists the launcher's keys; choosing one runs it", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            Launcher.list()
        }
    }

    public override func script(for gesture: KeyboardGesture) -> Script? {
        if let own = super.script(for: gesture) { return own }
        guard Core.active else { return nil }
        return Launcher.decision(for: gesture) == nil ? nil : launcherKey
    }
}
