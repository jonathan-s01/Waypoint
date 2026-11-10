// SPDX-License-Identifier: GPL-3.0-or-later
// The launcher: which key presses are its own, what its table and file do, and what each kind of binding asks for. The
// opening of apps, the shell and the commands are a recorder here, so no test launches anything. Whether a key sounds
// right, and an app really coming forward, are tried by ear (Launcher.swift).
import Foundation
import CoreGraphics
import TurnOverCore

private typealias Device = LauncherLogic.Device
private typealias Binding = LauncherLogic.Binding

private let rightCommand = Device.rightCommand, rightOption = Device.rightOption

/// A key press with the held modifier keys as the keyboard reports them (the device bits, and Command's generic one).
private func press(_ key: String, held: UInt, turnOver: Bool = false, repeating: Bool = false) -> KeyboardGesture {
    var mods: Modifiers = []
    if held & (Device.leftCommand | Device.rightCommand) != 0 { mods.insert(.command) }
    if held & (Device.leftOption | Device.rightOption) != 0 { mods.insert(.option) }
    if held & (Device.leftShift | Device.rightShift) != 0 { mods.insert(.shift) }
    if held & (Device.leftControl | Device.rightControl) != 0 { mods.insert(.control) }
    if turnOver { mods.insert(.turnover) }
    return KeyboardGesture(keyCode: KeyNames.code(for: key)!, modifiers: mods, characters: key, timestamp: 0, isRepeat: repeating, flags: CGEventFlags(rawValue: UInt64(held)))
}

private func scratchDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID())", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

/// Records what a binding asks for instead of doing it.
private final class Recorder: LauncherExecutor {
    var calls: [String] = []
    func openApp(bundle: String, name: String) { calls.append("app \(bundle)|\(name)") }
    func runShell(_ command: String, timeout: Double, label: String) { calls.append("shell \(command)|\(Int(timeout))|\(label)") }
    func open(_ target: String, label: String) { calls.append("open \(target)|\(label)") }
    func runCommand(_ name: String, gesture: KeyboardGesture) { calls.append("command \(name)") }
}

private let everyKind = LauncherLogic.Table(
    layer1: [
        Binding(key: "g", kind: .app, name: "Google Chrome", bundle: "com.google.Chrome"),
        Binding(key: "u", kind: .open, name: "Docs", target: "https://example.com/a b?c=1"),
    ],
    layer2: [
        Binding(key: "d", kind: .shell, name: "Backup", target: "echo \"hi\" && ls ~", timeout: 12),
        Binding(key: "r", kind: .command, target: "reviewLayerEnable"),
        Binding(key: "g", kind: .app, name: "Safari"),
    ])

func launcherTests() {
    // MARK: The table

    test("launcher: the shipped layer 1 has the eleven apps, each with a bundle identifier, and the volume keys; layer 2 is empty") {
        let t = LauncherLogic.Table.defaults
        expect(t.layer1.map(\.key), ["g", "h", "o", "m", "s", "f", "i", "x", "z", "c", "t", "=", "-"])
        check(t.layer2.isEmpty, "layer 2 starts empty")
        let apps = t.layer1.filter { $0.kind == .app }
        expect(apps.count, 11)
        check(apps.allSatisfy { $0.isValid && !$0.bundle.isEmpty && !$0.name.isEmpty }, "every default app has a name and a bundle")
        expect(t.binding(layer: 1, key: "=")?.kind, .command)
        expect(t.binding(layer: 1, key: "=")?.target, "volumeUp")
        expect(t.binding(layer: 1, key: "-")?.target, "volumeDown")
        for key in ["=", "-"] {
            expect(t.binding(layer: 1, key: key)?.repeatDelay, 1.0)
            expect(t.binding(layer: 1, key: key)?.repeatRate, 15.0)
        }
        check(apps.allSatisfy { $0.repeatRate == nil }, "no app repeats")
        expect(t.binding(layer: 1, key: "g")?.bundle, "com.google.Chrome")
        expect(t.binding(layer: 1, key: "c")?.name, "Colour Contrast Analyser")
        expect(t.binding(layer: 1, key: "t")?.bundle, "com.apple.TextEdit")
    }
    test("launcher: a binding is found by its key and layer, whatever the key's case") {
        let t = everyKind
        expect(t.binding(layer: 1, key: "G")?.name, "Google Chrome")
        expect(t.binding(layer: 2, key: "g")?.name, "Safari")
        check(t.binding(layer: 1, key: "d") == nil, "d is layer 2's")
        check(t.binding(layer: 2, key: "u") == nil, "u is layer 1's")
        check(t.binding(layer: 1, key: "nonsense") == nil, "not a key")
    }
    test("launcher: key names are the key list's, and a modifier key is no binding's key") {
        expect(LauncherLogic.normalizeKey(" G "), "g")
        expect(LauncherLogic.normalizeKey("Return"), "enter")
        expect(LauncherLogic.normalizeKey("UpArrow"), "upArrow")
        expect(LauncherLogic.normalizeKey("7"), "7")
        check(LauncherLogic.normalizeKey("") == nil, "empty")
        check(LauncherLogic.normalizeKey("rightCommand") == nil, "a modifier key")
        check(LauncherLogic.normalizeKey("shift") == nil, "a modifier key")
        check(LauncherLogic.normalizeKey("zzz") == nil, "no such key")
    }
    test("launcher: setting a key adds it or replaces the one on that key; removing takes it out") {
        var t = LauncherLogic.Table.defaults
        t.set(Binding(key: "G", kind: .shell, target: "true"), layer: 1)
        expect(t.layer1.count, 13)
        expect(t.binding(layer: 1, key: "g")?.kind, .shell)
        t.set(Binding(key: "w", kind: .app, name: "Word"), layer: 2)
        expect(t.layer2.map(\.key), ["w"])
        check(t.remove(key: "g", layer: 1), "removed")
        check(!t.remove(key: "g", layer: 1), "nothing left to remove")
        check(t.binding(layer: 1, key: "g") == nil, "gone")
        expect(t.layer1.count, 12)
    }
    test("launcher: a binding with nothing to run is not valid, and a key with one is not the launcher's") {
        check(!Binding(key: "a", kind: .app).isValid, "an app needs a name or a bundle")
        check(Binding(key: "a", kind: .app, name: "Pages").isValid, "a name is enough")
        check(Binding(key: "a", kind: .app, bundle: "com.apple.Pages").isValid, "a bundle is enough")
        check(!Binding(key: "a", kind: .shell, target: "  ").isValid, "an empty command")
        check(!Binding(key: "a", kind: .open).isValid, "nothing to open")
        check(!Binding(key: "a", kind: .command).isValid, "no command")
        let t = LauncherLogic.Table(layer1: [Binding(key: "a", kind: .shell)])
        check(LauncherLogic.match(flags: rightCommand, keyName: "a", turnOverKey: false, holds: .standard, table: t) == nil, "it would run nothing, so the key goes through")
    }

    // MARK: The file

    test("launcher file: every kind of binding comes back from its JSON as it was, and unknown fields do no harm") {
        let loaded = LauncherLogic.decode(LauncherLogic.encode(everyKind))
        expect(loaded.outcome, .ok)
        expect(loaded.table, everyKind)
        check(loaded.skipped.isEmpty, "nothing skipped")
        let withExtras = """
        {"version": 1, "future": {"a": [1, 2]}, "layer1": [{"key": "g", "kind": "app", "name": "Safari", "colour": "red", "bundle": "com.apple.Safari"}], "layer2": []}
        """
        let extra = LauncherLogic.decode(Data(withExtras.utf8))
        expect(extra.outcome, .ok)
        expect(extra.table.layer1, [Binding(key: "g", kind: .app, name: "Safari", bundle: "com.apple.Safari")])
    }
    test("launcher file: the defaults come back from their own JSON") {
        let loaded = LauncherLogic.decode(LauncherLogic.encode(.defaults))
        expect(loaded.outcome, .ok)
        expect(loaded.table, .defaults)
    }
    test("launcher file: a bad entry is skipped and named, the others load, a missing layer is empty") {
        let json = """
        {"version": 1, "layer1": [
            {"key": "g", "kind": "app", "name": "Safari"},
            {"key": "shift", "kind": "app", "name": "Nope"},
            {"key": "h", "kind": "teleport", "target": "x"},
            {"key": "j", "kind": "shell"},
            {"key": "G", "kind": "app", "name": "Twice"},
            "not an object",
            {"kind": "app", "name": "No key"},
            {"key": "k", "kind": "Open", "target": "~/Documents", "extra": true}
        ]}
        """
        let loaded = LauncherLogic.decode(Data(json.utf8))
        expect(loaded.outcome, .ok)
        expect(loaded.table.layer1.map(\.key), ["g", "k"])
        expect(loaded.table.layer1[0].name, "Safari")
        expect(loaded.table.layer1[1].kind, .open)
        expect(loaded.skipped.count, 6)
        check(loaded.table.layer2.isEmpty, "layer 2 is empty")
    }
    test("launcher file: a file that is not the launcher's is corrupt, and a newer version is read as far as it goes") {
        for bad in ["", "not json", "[]", "{}", "{\"version\": 1}", "{\"layer1\": []}", "{\"version\": 0, \"layer1\": []}", "{\"version\": 1, \"layer1\": 5}", "{\"version\": 1, \"layer2\": {}}"] {
            let r = LauncherLogic.decode(Data(bad.utf8))
            if case .corrupt = r.outcome { continue }
            check(false, "\(bad) should be corrupt, got \(r.outcome)")
        }
        let newer = LauncherLogic.decode(Data("{\"version\": 7, \"layer1\": [{\"key\": \"g\", \"kind\": \"app\", \"name\": \"Safari\"}]}".utf8))
        expect(newer.outcome, .newer(7))
        expect(newer.table.layer1.count, 1)
    }
    test("launcher store: no file means the defaults are written to it, and read back") {
        let dir = scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("launcher.json")
        let store = LauncherStore(url: url)
        expect(store.status, .seeded)
        expect(store.table, .defaults)
        check(FileManager.default.fileExists(atPath: url.path), "the file was made")
        let again = LauncherStore(url: url)
        expect(again.status, .ok)
        expect(again.table, .defaults)
        check(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path), "nothing was replaced, so no backup")
    }
    test("launcher store: a corrupt file gives the defaults, is copied aside, and is not touched") {
        let dir = scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("launcher.json")
        let broken = "{ \"version\": 1, \"layer1\": [ {\"key\": \"g\" "   // cut off, as a bad hand edit leaves it
        try? broken.write(to: url, atomically: true, encoding: .utf8)
        let store = LauncherStore(url: url)
        guard case .corrupt = store.status else { return check(false, "status \(store.status)") }
        expect(store.table, .defaults)
        expect(text(url), broken, "the file itself is as the user left it")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let copies = names.filter { $0.hasPrefix("launcher.json.corrupt-") }
        expect(copies.count, 1, "one copy kept")
        expect(copies.first.map { text(dir.appendingPathComponent($0)) } ?? "", broken, "the copy is the same")
    }
    test("launcher store: saving after a corrupt file keeps that file as .bak first") {
        let dir = scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("launcher.json")
        try? "garbage".write(to: url, atomically: true, encoding: .utf8)
        let store = LauncherStore(url: url)
        check(store.set(Binding(key: "w", kind: .app, name: "Word"), layer: 2), "saved")
        expect(text(url.appendingPathExtension("bak")), "garbage", "the corrupt file was kept")
        let after = LauncherStore(url: url)
        expect(after.status, .ok)
        expect(after.table.binding(layer: 2, key: "w")?.name, "Word")
        expect(after.table.layer1, LauncherLogic.Table.defaults.layer1)
    }
    test("launcher store: every save keeps the file it replaces, and edits and removals persist") {
        let dir = scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("launcher.json")
        let store = LauncherStore(url: url)
        let seeded = text(url)
        store.set(Binding(key: "u", kind: .open, target: "https://example.com"), layer: 1)
        expect(text(url.appendingPathExtension("bak")), seeded, "the seeded file is the backup")
        store.remove(key: "g", layer: 1)
        let reread = LauncherStore(url: url)
        check(reread.table.binding(layer: 1, key: "u") != nil, "the added key persists")
        check(reread.table.binding(layer: 1, key: "g") == nil, "the removed key stays removed")
        store.resetToDefaults()
        expect(LauncherStore(url: url).table, .defaults)
    }
    test("launcher store: a hand edit is picked up when the file changes, and a broken one falls back") {
        let dir = scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("launcher.json")
        let store = LauncherStore(url: url)
        store.reloadIfChanged()
        expect(store.table, .defaults, "unchanged file, unchanged table")
        let edited = LauncherLogic.Table(layer1: [Binding(key: "q", kind: .command, target: "launcherList")])
        try? LauncherLogic.encode(edited).write(to: url)
        store.reloadIfChanged()
        expect(store.table, edited)
        try? Data("oops, not json at all".utf8).write(to: url)
        store.reloadIfChanged()
        expect(store.table, .defaults)
        guard case .corrupt = store.status else { return check(false, "status \(store.status)") }
        check(store.reload() == false, "a reload says the defaults are in use")
    }

    // MARK: The chord

    test("launcher chord: Right Command alone is layer 1, and Right Command with Right Option is layer 2") {
        expect(LauncherLogic.layer(flags: rightCommand, holds: .standard, turnOverKey: false), 1)
        expect(LauncherLogic.layer(flags: rightCommand | rightOption, holds: .standard, turnOverKey: false), 2)
    }
    test("launcher chord: any other modifier with them, or other modifiers alone, is not the launcher's") {
        let h = LauncherLogic.Holds.standard
        for extra in [Device.leftShift, Device.rightShift, Device.leftControl, Device.rightControl, Device.leftCommand, Device.leftOption] {
            check(LauncherLogic.layer(flags: rightCommand | extra, holds: h, turnOverKey: false) == nil, "Right Command with \(LauncherLogic.holdName(extra))")
            check(LauncherLogic.layer(flags: rightCommand | rightOption | extra, holds: h, turnOverKey: false) == nil, "both with \(LauncherLogic.holdName(extra))")
        }
        for alone in [0, Device.leftCommand, Device.rightOption, Device.leftOption, Device.rightShift, Device.leftCommand | rightOption] {
            check(LauncherLogic.layer(flags: alone, holds: h, turnOverKey: false) == nil, "\(LauncherLogic.holdName(alone))")
        }
        check(LauncherLogic.layer(flags: rightCommand, holds: h, turnOverKey: true) == nil, "a TurnOver key held is a Waypoint command")
        // Flags that are not modifier keys (Caps Lock, fn, the generic Command bit) do not change the chord.
        expect(LauncherLogic.layer(flags: rightCommand | 0x100000 | 0x10000 | 0x800000, holds: h, turnOverKey: false), 1)
    }
    test("launcher chord: a mapped letter is taken, an unmapped one and a chord with another modifier go through") {
        let store = LauncherStore(url: scratchDirectory().appendingPathComponent("launcher.json"))
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let hit = Launcher.decision(for: press("g", held: rightCommand | 0x100000), store: store, holds: .standard, enabled: true)
        expect(hit?.layer, 1)
        expect(hit?.binding.bundle, "com.google.Chrome")
        check(Launcher.decision(for: press("q", held: rightCommand | 0x100000), store: store, holds: .standard, enabled: true) == nil, "q has no binding")
        check(Launcher.decision(for: press("g", held: 0), store: store, holds: .standard, enabled: true) == nil, "a plain g")
        check(Launcher.decision(for: press("g", held: Device.leftCommand), store: store, holds: .standard, enabled: true) == nil, "Left Command G is Copilot's, not the launcher's")
        check(Launcher.decision(for: press("g", held: rightCommand | Device.rightShift), store: store, holds: .standard, enabled: true) == nil, "with Shift")
        check(Launcher.decision(for: press("g", held: rightCommand | Device.leftControl), store: store, holds: .standard, enabled: true) == nil, "with Control")
        check(Launcher.decision(for: press("g", held: rightCommand | Device.leftOption), store: store, holds: .standard, enabled: true) == nil, "with Left Option")
        check(Launcher.decision(for: press("g", held: rightCommand, turnOver: true), store: store, holds: .standard, enabled: true) == nil, "with a TurnOver key")
        check(Launcher.decision(for: press("g", held: rightCommand), store: store, holds: .standard, enabled: false) == nil, "switched off")
        check(Launcher.decision(for: press("rightCommand", held: rightCommand), store: store, holds: .standard, enabled: true) == nil, "pressing Right Command itself")
    }
    test("launcher chord: Right Command with Right Option picks layer 2, and never also runs layer 1") {
        let dir = scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LauncherStore(url: dir.appendingPathComponent("launcher.json"))
        // Layer 2 is empty: layer 1's g must not answer to the two-key chord.
        check(Launcher.decision(for: press("g", held: rightCommand | rightOption), store: store, holds: .standard, enabled: true) == nil, "empty layer 2 passes the key through")
        store.set(Binding(key: "g", kind: .shell, target: "echo two"), layer: 2)
        let both = Launcher.decision(for: press("g", held: rightCommand | rightOption), store: store, holds: .standard, enabled: true)
        expect(both?.layer, 2)
        expect(both?.binding.kind, .shell)
        let one = Launcher.decision(for: press("g", held: rightCommand), store: store, holds: .standard, enabled: true)
        expect(one?.layer, 1)
        expect(one?.binding.kind, .app)
        let recorder = Recorder()
        Launcher.run(press("g", held: rightCommand | rightOption), store: store, holds: .standard, enabled: true, executor: recorder)
        expect(recorder.calls, ["shell echo two|30|"], "only layer 2 ran")
    }
    test("launcher chord: a key held down stays taken, and runs once") {
        let dir = scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LauncherStore(url: dir.appendingPathComponent("launcher.json"))
        let recorder = Recorder()
        let down = press("t", held: rightCommand)
        let again = press("t", held: rightCommand, repeating: true)
        check(Launcher.decision(for: down, store: store, holds: .standard, enabled: true) != nil, "the key-down is taken")
        check(Launcher.decision(for: again, store: store, holds: .standard, enabled: true) != nil, "its repeats are taken too, so they never type")
        Launcher.run(down, store: store, holds: .standard, enabled: true, executor: recorder)
        Launcher.run(again, store: store, holds: .standard, enabled: true, executor: recorder)
        Launcher.run(again, store: store, holds: .standard, enabled: true, executor: recorder)
        expect(recorder.calls, ["app com.apple.TextEdit|TextEdit"])
    }
    test("launcher chord: the held keys can be changed, and the old ones stop working") {
        let dir = scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LauncherStore(url: dir.appendingPathComponent("launcher.json"))
        let moved = LauncherLogic.Holds(hold1: Device.rightControl | Device.rightOption, hold2: Device.rightControl | Device.rightOption | Device.rightShift)
        let now = Launcher.decision(for: press("g", held: moved.hold1), store: store, holds: moved, enabled: true)
        expect(now?.layer, 1)
        check(Launcher.decision(for: press("g", held: rightCommand), store: store, holds: moved, enabled: true) == nil, "Right Command is free again")
        check(Launcher.decision(for: press("g", held: moved.hold2), store: store, holds: moved, enabled: true) == nil, "layer 2 is empty")
        store.set(Binding(key: "g", kind: .open, target: "/"), layer: 2)
        expect(Launcher.decision(for: press("g", held: moved.hold2), store: store, holds: moved, enabled: true)?.layer, 2)
        let same = LauncherLogic.Holds(hold1: rightCommand, hold2: rightCommand)
        expect(LauncherLogic.layer(flags: rightCommand, holds: same, turnOverKey: false), 2, "equal holds: layer 2 first, never both")
        let none = LauncherLogic.Holds(hold1: 0, hold2: 0)
        check(LauncherLogic.layer(flags: 0, holds: none, turnOverKey: false) == nil, "a hold of nothing never matches")
    }
    test("launcher chord: a hold needs Command, Option or Control; Shift alone would take every capital") {
        check(LauncherLogic.isUsableHold(rightCommand), "Right Command")
        check(LauncherLogic.isUsableHold(Device.leftOption | Device.rightShift), "Option with Shift")
        check(LauncherLogic.isUsableHold(Device.rightControl), "Control")
        check(!LauncherLogic.isUsableHold(Device.leftShift), "Shift alone")
        check(!LauncherLogic.isUsableHold(Device.leftShift | Device.rightShift), "both Shifts")
        check(!LauncherLogic.isUsableHold(0), "nothing")
    }
    test("launcher chord: the held keys are named in words") {
        expect(LauncherLogic.holdName(rightCommand), "Right Command")
        expect(LauncherLogic.holdName(rightCommand | rightOption), "Right Option and Right Command")
        expect(LauncherLogic.holdName(Device.leftControl | Device.rightOption | Device.rightShift), "Left Control, Right Option and Right Shift")
        expect(LauncherLogic.holdName(0), "no keys")
    }

    // MARK: What a binding does

    test("launcher actions: each kind asks the executor for its own thing") {
        let recorder = Recorder()
        let g = press("g", held: rightCommand)
        for b in everyKind.layer1 + everyKind.layer2 { Launcher.dispatch(b, executor: recorder, gesture: g) }
        expect(recorder.calls, [
            "app com.google.Chrome|Google Chrome",
            "open https://example.com/a b?c=1|Docs",
            "shell echo \"hi\" && ls ~|12|Backup",
            "command reviewLayerEnable",
            "app |Safari",
        ])
    }
    test("launcher actions: a shell command's time limit is its own, else 30 seconds, and never beyond five minutes") {
        expect(LauncherLogic.timeout(for: Binding(key: "a", kind: .shell, target: "x")), 30)
        expect(LauncherLogic.timeout(for: Binding(key: "a", kind: .shell, target: "x", timeout: 5)), 5)
        expect(LauncherLogic.timeout(for: Binding(key: "a", kind: .shell, target: "x", timeout: 100_000)), 300)
        expect(LauncherLogic.timeout(for: Binding(key: "a", kind: .shell, target: "x", timeout: 0)), 30)
        expect(LauncherLogic.timeout(for: Binding(key: "a", kind: .shell, target: "x", timeout: -4)), 30)
    }
    test("launcher actions: an app in front has its back window brought forward, one at a time, round") {
        check(LauncherLogic.nextWindowIndex(count: 0, current: nil) == nil, "no windows")
        check(LauncherLogic.nextWindowIndex(count: 1, current: 0) == nil, "one window: nothing to do")
        expect(LauncherLogic.nextWindowIndex(count: 2, current: 0), 1)
        expect(LauncherLogic.nextWindowIndex(count: 4, current: 0), 3, "the back window")
        expect(LauncherLogic.nextWindowIndex(count: 4, current: 3), 0, "front again when the back one is in front already")
        expect(LauncherLogic.nextWindowIndex(count: 3, current: nil), 2, "when the front window is not known")
    }
    test("launcher settings: the window's fields make a binding, or none when it could not run") {
        let app = LauncherSettings.binding(from: ["key": "G", "kind": "app", "name": " Safari ", "bundle": "", "target": ""])
        expect(app, Binding(key: "g", kind: .app, name: "Safari"))
        let shell = LauncherSettings.binding(from: ["key": "d", "kind": "shell", "target": "ls  -l", "timeout": 9])
        expect(shell?.timeout, 9)
        expect(shell?.target, "ls  -l")
        check(LauncherSettings.binding(from: ["key": "d", "kind": "shell", "target": "   "]) == nil, "empty command")
        check(LauncherSettings.binding(from: ["key": "shift", "kind": "app", "name": "x"]) == nil, "not a letter key")
        check(LauncherSettings.binding(from: ["key": "d", "kind": "dance", "target": "x"]) == nil, "unknown kind")
        check(LauncherSettings.binding(from: ["kind": "app", "name": "x"]) == nil, "no key")
    }
}
