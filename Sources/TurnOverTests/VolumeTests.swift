// SPDX-License-Identifier: GPL-3.0-or-later
// Volume up and down and the launcher's hold to repeat: the step's maths, which control is set, the mute rule, and when a
// held key repeats and stops. The audio system and the keyboard's state are fakes here, so a test never changes the
// real volume. That the TS4 (or any device) answers, and how smooth a held key sounds, are tried by ear (Volume.swift).
import Foundation
import CoreGraphics
import TurnOverCore

private typealias Binding = LauncherLogic.Binding
private typealias Device = LauncherLogic.Device

/// A sound device that keeps its controls in a dictionary.
private final class FakeAudio: VolumeBackend {
    var device: UInt32? = 7
    var values: [VolumeControl: Float] = [:]
    var settable: Set<VolumeControl> = []
    var refuse: Set<VolumeControl> = []
    var sets: [String] = []

    init(main: Float? = nil, left: Float? = nil, right: Float? = nil, mute: Float? = nil) {
        for (control, v) in [(VolumeControl.virtualMain, main), (.channel1, left), (.channel2, right), (.mute, mute)] {
            if let v { values[control] = v; settable.insert(control) }
        }
    }
    func outputDevice() -> UInt32? { device }
    func canSet(_ control: VolumeControl, on device: UInt32) -> Bool { settable.contains(control) }
    func get(_ control: VolumeControl, on device: UInt32) -> Float? { values[control] }
    func set(_ control: VolumeControl, _ value: Float, on device: UInt32) -> Bool {
        guard !refuse.contains(control) else { return false }
        values[control] = value
        sets.append("\(control) \(value)")
        return true
    }
}

/// A clock, a keyboard and a timer that the test moves by hand.
private final class FakeKeys {
    var time: Double = 100
    var keys: Set<Int64> = []
    var modifiers: UInt = 0
    var allowed = true
    var handler: (() -> Void)?
    var started = 0, stopped = 0

    lazy var hooks = LauncherRepeatHooks(
        now: { [unowned self] in time },
        keyDown: { [unowned self] in keys.contains($0) },
        heldModifiers: { [unowned self] in modifiers },
        allowed: { [unowned self] in allowed },
        startTimer: { [unowned self] h in handler = h; started += 1 },
        stopTimer: { [unowned self] in handler = nil; stopped += 1 })

    /// Moves the clock on in 20 ms ticks, as the live timer would call, and returns how many times the timer ran.
    func advance(_ seconds: Double) {
        let ticks = Int((seconds / LauncherRepeater.tickInterval).rounded())
        for _ in 0..<ticks {
            time += LauncherRepeater.tickInterval
            handler?()
        }
    }
}

private let volumeKeyCode = KeyNames.code(for: "=")!

/// Volumes are floats: equal to a millionth, not to the last bit.
private func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-6 }
private func expect(_ got: Float, _ want: Float, _ what: String = "", file: String = #fileID, line: Int = #line) {
    check(near(got, want), "\(what.isEmpty ? "" : what + ": ")got \(got), wanted \(want)", file: file, line: line)
}
private func expect(_ got: Float?, _ want: Float, _ what: String = "", file: String = #fileID, line: Int = #line) {
    check(got.map { near($0, want) } ?? false, "\(what.isEmpty ? "" : what + ": ")got \(String(describing: got)), wanted \(want)", file: file, line: line)
}
private func expect(_ got: VolumeLogic.Outcome, _ want: VolumeLogic.Outcome, _ what: String = "", file: String = #fileID, line: Int = #line) {
    var same = got == want
    if case .changed(let a, let b, let u) = got, case .changed(let c, let d, let v) = want { same = near(a, c) && near(b, d) && u == v }
    check(same, "\(what.isEmpty ? "" : what + ": ")got \(got), wanted \(want)", file: file, line: line)
}
private let rightCommand = Device.rightCommand

private func press(_ key: String, held: UInt, repeating: Bool = false) -> KeyboardGesture {
    var mods: Modifiers = []
    if held & (Device.leftCommand | Device.rightCommand) != 0 { mods.insert(.command) }
    return KeyboardGesture(keyCode: KeyNames.code(for: key)!, modifiers: mods, characters: key, timestamp: 0, isRepeat: repeating, flags: CGEventFlags(rawValue: UInt64(held)))
}

private final class Recorder: LauncherExecutor {
    var calls: [String] = []
    func openApp(bundle: String, name: String) { calls.append("app \(name)") }
    func runShell(_ command: String, timeout: Double, label: String) { calls.append("shell \(command)") }
    func open(_ target: String, label: String) { calls.append("open \(target)") }
    func runCommand(_ name: String, gesture: KeyboardGesture) { calls.append("command \(name)") }
}

private let volumeBinding = Binding(key: "=", kind: .command, name: "Volume up", target: "volumeUp", repeatDelay: 1.0, repeatRate: 15)

/// A pop that counts instead of sounding.
private final class FakePop: VolumeFeedbackPlayer {
    var plays = 0
    func play() { plays += 1 }
}

/// What the gate's clock and two switches say, moved by hand (read on one thread here).
nonisolated private final class FeedbackWorld: @unchecked Sendable {
    var time: TimeInterval = 500
    var on = true
    var systemOn = true
}

private func drainMain() {
    var done = false
    DispatchQueue.main.async { done = true }
    let until = Date().addingTimeInterval(1)
    while !done, Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

private func gate(_ pop: FakePop, _ world: FeedbackWorld) -> VolumeFeedbackGate {
    VolumeFeedbackGate(player: pop, clock: { world.time }, feedbackOn: { world.on }, systemFeedbackOn: { world.systemOn })
}

func volumeTests() {
    // MARK: The maths

    test("volume: a step up or down is added to what the device says now, within 0 to 1") {
        expect(VolumeLogic.stepped(0.5, up: true, step: 0.01), 0.51)
        expect(VolumeLogic.stepped(0.5, up: false, step: 0.01), 0.49)
        expect(VolumeLogic.stepped(0.995, up: true, step: 0.01), 1.0, "no further than the top")
        expect(VolumeLogic.stepped(0.004, up: false, step: 0.01), 0.0, "no further than the bottom")
        expect(VolumeLogic.stepped(.nan, up: true, step: 0.01), 0.01, "a value that is not a number counts as silence")
        expect(VolumeLogic.clamp(2), 1)
        expect(VolumeLogic.clamp(-1), 0)
    }
    test("volume: the step is kept within half a percent and a quarter, and is one percent when it is nothing usable") {
        expect(VolumeLogic.defaultStep, 0.01)
        expect(VolumeLogic.clampStep(nil), 0.01)
        expect(VolumeLogic.clampStep(.nan), 0.01)
        expect(VolumeLogic.clampStep(0), 0.005)
        expect(VolumeLogic.clampStep(-3), 0.005)
        expect(VolumeLogic.clampStep(0.002), 0.005)
        expect(VolumeLogic.clampStep(0.05), 0.05)
        expect(VolumeLogic.clampStep(9), 0.25)
    }
    test("volume: only raising the volume clears the mute") {
        check(VolumeLogic.shouldClearMute(raising: true, muted: true), "up from mute")
        check(!VolumeLogic.shouldClearMute(raising: false, muted: true), "down leaves it")
        check(!VolumeLogic.shouldClearMute(raising: true, muted: false), "nothing to clear")
    }

    // MARK: The device

    test("volume: the virtual main volume is read fresh and set one step on, every time") {
        let audio = FakeAudio(main: 0.40, left: 0.1, right: 0.1)
        expect(VolumeLogic.adjust(up: true, step: 0.01, backend: audio), .changed(from: 0.40, to: 0.41, unmuted: false))
        audio.values[.virtualMain] = 0.80   // someone else moved it: the next press starts from there
        expect(VolumeLogic.adjust(up: false, step: 0.01, backend: audio), .changed(from: 0.80, to: 0.79, unmuted: false))
        expect(audio.values[.channel1], 0.1, "the channels are left alone when the main volume works")
        expect(audio.sets.count, 2)
    }
    test("volume: raising it from mute also switches the mute off; lowering it does not") {
        let audio = FakeAudio(main: 0.0, mute: 1)
        expect(VolumeLogic.adjust(up: false, step: 0.01, backend: audio), .changed(from: 0, to: 0, unmuted: false))
        expect(audio.values[.mute], 1, "still muted after a press down")
        expect(VolumeLogic.adjust(up: true, step: 0.01, backend: audio), .changed(from: 0, to: 0.01, unmuted: true))
        expect(audio.values[.mute], 0)
        expect(VolumeLogic.adjust(up: true, step: 0.01, backend: audio), .changed(from: 0.01, to: 0.02, unmuted: false), "no second unmute")
    }
    test("volume: a device with no virtual main volume has its two channels set instead") {
        let audio = FakeAudio(left: 0.30, right: 0.50)
        expect(VolumeLogic.adjust(up: true, step: 0.05, backend: audio), .changed(from: 0.40, to: 0.45, unmuted: false))
        expect(audio.values[.channel1], 0.45)
        expect(audio.values[.channel2], 0.45)
        check(audio.values[.virtualMain] == nil, "the missing control is not made up")
    }
    test("volume: when the virtual main volume cannot be set, or is refused, the channels are used") {
        let locked = FakeAudio(main: 0.5, left: 0.2, right: 0.2)
        locked.settable.remove(.virtualMain)
        expect(VolumeLogic.adjust(up: true, step: 0.01, backend: locked), .changed(from: 0.2, to: 0.21, unmuted: false))
        expect(locked.values[.virtualMain], 0.5)
        let refusing = FakeAudio(main: 0.5, left: 0.2, right: 0.2)
        refusing.refuse = [.virtualMain]
        expect(VolumeLogic.adjust(up: false, step: 0.01, backend: refusing), .changed(from: 0.2, to: 0.19, unmuted: false))
    }
    test("volume: one channel is enough, and the mute is cleared on the fallback path too") {
        let audio = FakeAudio(left: 0.2, mute: 1)
        expect(VolumeLogic.adjust(up: true, step: 0.01, backend: audio), .changed(from: 0.2, to: 0.21, unmuted: true))
        expect(audio.values[.mute], 0)
    }
    test("volume: no device, no control, or a refusing control is reported, and nothing is set") {
        let none = FakeAudio(main: 0.5)
        none.device = nil
        expect(VolumeLogic.adjust(up: true, step: 0.01, backend: none), .noDevice)
        let bare = FakeAudio()
        expect(VolumeLogic.adjust(up: true, step: 0.01, backend: bare), .notAdjustable)
        let refusing = FakeAudio(main: 0.5)
        refusing.refuse = [.virtualMain]
        expect(VolumeLogic.adjust(up: true, step: 0.01, backend: refusing), .failed)
        check(none.sets.isEmpty && bare.sets.isEmpty && refusing.sets.isEmpty, "no change was made")
    }
    test("volume: a step outside the range is brought into it before it is used") {
        let audio = FakeAudio(main: 0.5)
        expect(VolumeLogic.adjust(up: true, step: 50, backend: audio), .changed(from: 0.5, to: 0.75, unmuted: false))
    }

    // MARK: Hold to repeat

    test("launcher repeat: the binding's rate and delay are kept within 1 to 30 a second and 0.2 to 5 seconds") {
        check(LauncherLogic.repeatTiming(for: Binding(key: "a", kind: .command, target: "x")) == nil, "no rate, no repeat")
        check(LauncherLogic.repeatTiming(for: Binding(key: "a", kind: .command, target: "x", repeatDelay: 1, repeatRate: 0)) == nil, "rate 0 is no repeat")
        check(LauncherLogic.repeatTiming(for: Binding(key: "a", kind: .command, target: "x", repeatRate: -5)) == nil, "a negative rate is no repeat")
        let normal = LauncherLogic.repeatTiming(for: volumeBinding)
        expect(normal?.delay, 1.0)
        expect(normal?.interval ?? 0, 1.0 / 15, "15 a second")
        expect(LauncherLogic.clampedRate(500), 30)
        expect(LauncherLogic.clampedRate(0.2), 1)
        expect(LauncherLogic.clampedDelay(0), 0.2)
        expect(LauncherLogic.clampedDelay(99), 5)
        expect(LauncherLogic.clampedDelay(nil), 1.0, "one second when there is none")
        expect(LauncherLogic.repeatTiming(for: Binding(key: "a", kind: .command, target: "x", repeatRate: 15))?.delay, 1.0, "the default delay")
    }
    test("launcher repeat: it runs again only after the delay, then at the rate, and stops when the key is let go") {
        let fake = FakeKeys(), repeater = LauncherRepeater(hooks: fake.hooks)
        var runs = 0
        fake.keys = [volumeKeyCode]; fake.modifiers = rightCommand
        check(repeater.begin(keyCode: volumeKeyCode, chord: rightCommand, binding: volumeBinding) { runs += 1 }, "watching")
        expect(runs, 0, "the first run is the press's own, not the repeater's")
        check(repeater.isRepeating && repeater.timerRunning, "timer on")
        fake.advance(0.96)
        expect(runs, 0, "nothing before the delay")
        fake.advance(0.06)
        expect(runs, 1, "the first repeat at the delay")
        fake.advance(1.0)
        check((15...17).contains(runs), "about 15 more in a second, got \(runs - 1)")
        fake.keys = []
        let before = runs
        fake.advance(0.02)
        expect(runs, before, "no run after the key went up")
        check(!repeater.isRepeating && !repeater.timerRunning, "stopped")
        expect(fake.stopped, 1)
        fake.advance(1)
        expect(runs, before, "and stays stopped")
    }
    test("launcher repeat: a key let go before the delay never repeats") {
        let fake = FakeKeys(), repeater = LauncherRepeater(hooks: fake.hooks)
        var runs = 0
        fake.keys = [volumeKeyCode]; fake.modifiers = rightCommand
        repeater.begin(keyCode: volumeKeyCode, chord: rightCommand, binding: volumeBinding) { runs += 1 }
        fake.advance(0.5)
        fake.keys = []
        fake.advance(3)
        expect(runs, 0)
        check(!repeater.timerRunning, "no timer left")
    }
    test("launcher repeat: it stops when a chord's modifier is let go, or another is added") {
        for change in [UInt(0), rightCommand | Device.leftShift, rightCommand | Device.rightOption] {
            let fake = FakeKeys(), repeater = LauncherRepeater(hooks: fake.hooks)
            var runs = 0
            fake.keys = [volumeKeyCode]; fake.modifiers = rightCommand
            repeater.begin(keyCode: volumeKeyCode, chord: rightCommand, binding: volumeBinding) { runs += 1 }
            fake.advance(1.5)
            check(runs > 0, "it was repeating")
            let before = runs
            fake.modifiers = change
            fake.advance(1)
            expect(runs, before, "no run after the modifiers became \(LauncherLogic.holdName(change))")
            check(!repeater.timerRunning, "stopped")
        }
    }
    test("launcher repeat: it stops when the launcher is switched off or Waypoint is handed over") {
        let fake = FakeKeys(), repeater = LauncherRepeater(hooks: fake.hooks)
        var runs = 0
        fake.keys = [volumeKeyCode]; fake.modifiers = rightCommand
        repeater.begin(keyCode: volumeKeyCode, chord: rightCommand, binding: volumeBinding) { runs += 1 }
        fake.advance(1.2)
        let before = runs
        fake.allowed = false
        fake.advance(1)
        expect(runs, before)
        check(!repeater.isRepeating && !repeater.timerRunning, "stopped")
    }
    test("launcher repeat: a binding with no rate starts nothing") {
        let fake = FakeKeys(), repeater = LauncherRepeater(hooks: fake.hooks)
        fake.keys = [volumeKeyCode]; fake.modifiers = rightCommand
        let plain = Binding(key: "=", kind: .command, target: "volumeUp")
        check(!repeater.begin(keyCode: volumeKeyCode, chord: rightCommand, binding: plain) { }, "refused")
        check(!repeater.isRepeating && !repeater.timerRunning, "no timer")
        expect(fake.started, 0)
    }
    test("launcher repeat: a new press replaces the old hold, and stop is safe any time") {
        let fake = FakeKeys(), repeater = LauncherRepeater(hooks: fake.hooks)
        var first = 0, second = 0
        fake.keys = [volumeKeyCode]; fake.modifiers = rightCommand
        repeater.begin(keyCode: volumeKeyCode, chord: rightCommand, binding: volumeBinding) { first += 1 }
        fake.advance(0.5)
        repeater.begin(keyCode: volumeKeyCode, chord: rightCommand, binding: volumeBinding) { second += 1 }
        fake.advance(0.7)
        expect(first, 0, "the old hold's delay is gone with it")
        expect(second, 0, "the new hold's delay starts at its own press")
        fake.advance(0.5)
        expect(first, 0)
        check(second > 0, "the new hold repeats")
        repeater.stop("test")
        repeater.stop("again")
        check(!repeater.timerRunning && fake.handler == nil, "nothing running")
        repeater.tick()
    }
    test("launcher repeat: no hold lasts more than a minute, whatever the keyboard says") {
        let fake = FakeKeys(), repeater = LauncherRepeater(hooks: fake.hooks)
        var runs = 0
        fake.keys = [volumeKeyCode]; fake.modifiers = rightCommand
        repeater.begin(keyCode: volumeKeyCode, chord: rightCommand, binding: Binding(key: "=", kind: .command, target: "volumeUp", repeatDelay: 0.2, repeatRate: 1)) { runs += 1 }
        fake.advance(LauncherRepeater.longestHold + 2)
        check(!repeater.isRepeating && !repeater.timerRunning, "stopped by the limit")
        check(runs >= 50 && runs <= 61, "ran at one a second until then, got \(runs)")
    }
    test("launcher repeat: the modifier keys' codes cover every device bit") {
        expect(LauncherRepeater.modifierKeys.reduce(0) { $0 | $1.bit }, Device.all)
        expect(Set(LauncherRepeater.modifierKeys.map(\.code)).count, LauncherRepeater.modifierKeys.count, "no code twice")
    }
    test("launcher repeat: a press of a rate binding runs it once and starts a hold; auto-repeat and plain bindings do not") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("volume-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LauncherStore(url: dir.appendingPathComponent("launcher.json"))
        store.set(Binding(key: "w", kind: .shell, target: "echo plain"), layer: 1)
        let fake = FakeKeys(), repeater = LauncherRepeater(hooks: fake.hooks), recorder = Recorder()
        fake.keys = [volumeKeyCode]; fake.modifiers = rightCommand

        Launcher.run(press("=", held: rightCommand, repeating: true), store: store, holds: .standard, enabled: true, executor: recorder, repeater: repeater)
        check(recorder.calls.isEmpty && !repeater.isRepeating, "the system's own key repeat does nothing")
        Launcher.run(press("w", held: rightCommand), store: store, holds: .standard, enabled: true, executor: recorder, repeater: repeater)
        expect(recorder.calls, ["shell echo plain"])
        check(!repeater.isRepeating, "a plain binding does not repeat")
        Launcher.run(press("=", held: rightCommand), store: store, holds: .standard, enabled: true, executor: recorder, repeater: repeater)
        expect(recorder.calls, ["shell echo plain", "command volumeUp"], "once at the press")
        check(repeater.isRepeating, "and now watching")
        fake.advance(1.0 + 0.5)
        check(recorder.calls.filter { $0 == "command volumeUp" }.count > 1, "repeated while held")
        fake.keys = []
        fake.advance(0.1)
        let count = recorder.calls.count
        fake.advance(2)
        expect(recorder.calls.count, count, "silent once let go")
        check(!repeater.timerRunning, "no timer left")
    }

    // MARK: The file

    test("launcher file: repeat rate and delay come back from the JSON; absent ones stay absent; wild ones are brought in range") {
        let table = LauncherLogic.Table(layer1: [
            volumeBinding,
            Binding(key: "-", kind: .command, target: "volumeDown", repeatRate: 8),
            Binding(key: "w", kind: .shell, target: "true"),
        ])
        let back = LauncherLogic.decode(LauncherLogic.encode(table))
        expect(back.outcome, .ok)
        expect(back.table.binding(layer: 1, key: "=")?.repeatRate, 15)
        expect(back.table.binding(layer: 1, key: "=")?.repeatDelay, 1.0)
        expect(back.table.binding(layer: 1, key: "-")?.repeatRate, 8)
        expect(back.table.binding(layer: 1, key: "-")?.repeatDelay, 1.0, "the default delay once there is a rate")
        check(back.table.binding(layer: 1, key: "w")?.repeatRate == nil && back.table.binding(layer: 1, key: "w")?.repeatDelay == nil, "none where there was none")
        let text = String(decoding: LauncherLogic.encode(table), as: UTF8.self)
        check(text.contains("repeatRate"), "written in the file")

        let hand = """
        {"version": 1, "layer1": [
          {"key": "=", "kind": "command", "target": "volumeUp", "repeatRate": 900, "repeatDelay": 0.01},
          {"key": "-", "kind": "command", "target": "volumeDown", "repeatDelay": 3},
          {"key": "w", "kind": "command", "target": "x", "repeatRate": "fast"},
          {"key": "q", "kind": "command", "target": "x", "repeatRate": 0}
        ], "layer2": []}
        """
        let loaded = LauncherLogic.decode(Data(hand.utf8))
        expect(loaded.outcome, .ok)
        expect(loaded.table.binding(layer: 1, key: "=")?.repeatRate, 30, "kept to 30 a second")
        expect(loaded.table.binding(layer: 1, key: "=")?.repeatDelay, 0.2, "kept to 0.2 seconds")
        check(loaded.table.binding(layer: 1, key: "-")?.repeatRate == nil, "a delay alone does not make it repeat")
        check(loaded.table.binding(layer: 1, key: "w")?.repeatRate == nil, "a rate that is not a number is no rate")
        check(loaded.table.binding(layer: 1, key: "q")?.repeatRate == nil, "rate 0 is no rate")
        check(loaded.table.binding(layer: 1, key: "q") != nil, "and the binding stays")
    }
    test("launcher settings: the window's repeat fields make a binding, kept in range, and a blank means none") {
        let b = LauncherSettings.binding(from: ["key": "=", "kind": "command", "target": "volumeUp", "repeatRate": 99, "repeatDelay": 9])
        expect(b?.repeatRate, 30)
        expect(b?.repeatDelay, 5)
        let none = LauncherSettings.binding(from: ["key": "=", "kind": "command", "target": "volumeUp"])
        check(none?.repeatRate == nil && none?.repeatDelay == nil, "absent")
        let defaulted = LauncherSettings.binding(from: ["key": "=", "kind": "command", "target": "volumeUp", "repeatRate": 10])
        expect(defaulted?.repeatDelay, 1.0)
        check(defaulted != nil, "kept")
    }

    // MARK: Speech kept

    test("keep speech: the shipped volume keys keep it, every other default key does not, and the file remembers") {
        let t = LauncherLogic.Table.defaults
        for key in ["=", "-"] { check(t.binding(layer: 1, key: key)?.keepSpeech == true, "\(key) keeps speech") }
        check(t.layer1.filter { $0.key != "=" && $0.key != "-" }.allSatisfy { !$0.keepSpeech }, "the apps cut speech as before")
        check(!Binding(key: "a", kind: .command, target: "x").keepSpeech, "off unless asked for")
        let table = LauncherLogic.Table(layer1: [Binding(key: "a", kind: .command, target: "x", keepSpeech: true), Binding(key: "b", kind: .command, target: "y")])
        let back = LauncherLogic.decode(LauncherLogic.encode(table))
        expect(back.outcome, .ok)
        check(back.table.binding(layer: 1, key: "a")?.keepSpeech == true, "kept through the JSON")
        check(back.table.binding(layer: 1, key: "b")?.keepSpeech == false, "absent means off")
        let text = String(decoding: LauncherLogic.encode(table), as: UTF8.self)
        check(text.components(separatedBy: "\"keepSpeech\"").count == 2, "written for the one binding only")
        let hand = LauncherLogic.decode(Data(#"{"version": 1, "layer1": [{"key": "a", "kind": "command", "target": "x", "keepSpeech": "yes"}], "layer2": []}"#.utf8))
        check(hand.table.binding(layer: 1, key: "a")?.keepSpeech == false, "something that is not a true or false is off")
        check(LauncherSettings.binding(from: ["key": "a", "kind": "command", "target": "x", "keepSpeech": true])?.keepSpeech == true, "from the window")
        check(LauncherSettings.binding(from: ["key": "a", "kind": "command", "target": "x"])?.keepSpeech == false, "off from the window by default")
    }
    test("keep speech: the launcher says so for a keepSpeech key in its chord only, and not when it is off") {
        let store = LauncherStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID())/launcher.json"))
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        store.set(Binding(key: "q", kind: .shell, target: "true"), layer: 1)
        @MainActor func keeps(_ g: KeyboardGesture, enabled: Bool = true) -> Bool { Launcher.keepsSpeech(g, store: store, holds: .standard, enabled: enabled) }
        check(keeps(press("=", held: rightCommand)), "volume up")
        check(keeps(press("-", held: rightCommand)), "volume down")
        check(keeps(press("=", held: rightCommand, repeating: true)), "the system's key repeat of it too")
        check(!keeps(press("q", held: rightCommand)), "an ordinary launcher key")
        check(!keeps(press("g", held: rightCommand)), "an app key")
        check(!keeps(press("=", held: 0)), "the key without the chord")
        check(!keeps(press("=", held: rightCommand | Device.leftShift)), "the chord with another modifier")
        check(!keeps(press("=", held: rightCommand), enabled: false), "the launcher off")
    }
    test("keep speech: a keepSpeech key does not cut speech, any other key still does") {
        let store = LauncherStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID())/launcher.json"))
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let savedKeep = InputManager.keepsSpeechForKey, savedObserver = InputManager.speechCutObserver
        let savedPass = InputManager.passNextKey, savedHelp = InputManager.isInputHelpActive, savedCapture = InputManager.captureNext
        var cuts = 0
        InputManager.keepsSpeechForKey = { Launcher.keepsSpeech($0, store: store, holds: .standard, enabled: true) }
        InputManager.speechCutObserver = { cuts += 1 }
        InputManager.passNextKey = false; InputManager.isInputHelpActive = false; InputManager.captureNext = nil
        defer {
            drainMain()
            InputManager.keepsSpeechForKey = savedKeep; InputManager.speechCutObserver = savedObserver
            InputManager.passNextKey = savedPass; InputManager.isInputHelpActive = savedHelp; InputManager.captureNext = savedCapture
        }
        _ = InputManager.handleKeyDown(press("=", held: rightCommand)); drainMain()
        expect(cuts, 0, "volume up leaves speech")
        _ = InputManager.handleKeyDown(press("-", held: rightCommand, repeating: true)); drainMain()
        expect(cuts, 0, "and so does the system's repeat of volume down")
        _ = InputManager.handleKeyDown(press("g", held: rightCommand)); drainMain()
        expect(cuts, 1, "an app key cuts speech as before")
        _ = InputManager.handleKeyDown(press("g", held: 0)); drainMain()
        expect(cuts, 2, "so does a plain key")
        _ = InputManager.handleKeyDown(press("=", held: 0)); drainMain()
        expect(cuts, 3, "and the equals key without the chord")
    }
    test("keep speech: a hold to repeat never cuts speech, at the press or at a tick") {
        var cuts = 0
        let savedObserver = InputManager.speechCutObserver
        InputManager.speechCutObserver = { cuts += 1 }
        defer { InputManager.speechCutObserver = savedObserver }
        let store = LauncherStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID())/launcher.json"))
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let fake = FakeKeys(), repeater = LauncherRepeater(hooks: fake.hooks), recorder = Recorder()
        fake.keys = [volumeKeyCode]; fake.modifiers = rightCommand
        Launcher.run(press("=", held: rightCommand), store: store, holds: .standard, enabled: true, executor: recorder, repeater: repeater)
        fake.advance(3)
        check(recorder.calls.filter { $0 == "command volumeUp" }.count > 10, "it repeated")
        drainMain()
        expect(cuts, 0, "the press and every tick left speech alone")
    }

    // MARK: The volume sound

    test("volume sound: the rules want both switches on and a real change") {
        let up = VolumeLogic.Outcome.changed(from: 0.5, to: 0.51, unmuted: false)
        func play(_ o: VolumeLogic.Outcome, on: Bool = true, system: Bool = true, now: TimeInterval = 10, last: TimeInterval? = nil) -> Bool {
            VolumeFeedbackLogic.shouldPlay(o, feedbackOn: on, systemFeedbackOn: system, now: now, lastPlayed: last)
        }
        check(play(up), "a change pops")
        check(!play(up, on: false), "Waypoint's switch off")
        check(!play(up, system: false), "the system's switch off")
        check(!play(.changed(from: 1, to: 1, unmuted: false)), "already at the top: nothing changed")
        check(!play(.changed(from: 0, to: 0, unmuted: false)), "already at the bottom")
        check(play(.changed(from: 0.5, to: 0.5, unmuted: true)), "raising from mute pops")
        check(play(.changed(from: 0, to: 0.01, unmuted: true)), "raising from mute at nothing pops")
        for o in [VolumeLogic.Outcome.noDevice, .notAdjustable, .failed] { check(!play(o), "\(o) is no change") }
    }
    test("volume sound: no more than about ten a second, from a held key's fifteen changes") {
        let pop = FakePop(), world = FeedbackWorld()
        let g = gate(pop, world)
        let up = VolumeLogic.Outcome.changed(from: 0.5, to: 0.51, unmuted: false)
        check(g.changed(up), "the first pops")
        world.time += 0.05
        check(!g.changed(up), "50 ms later it is skipped")
        world.time += 0.05
        check(g.changed(up), "100 ms after the pop, another")
        expect(pop.plays, 2)
        for _ in 0..<150 { world.time += 1.0 / 15; g.changed(up) }   // ten seconds of a held key
        check(pop.plays <= 2 + 100, "never above ten a second: \(pop.plays)")
        check(pop.plays >= 2 + 60, "and not far below: \(pop.plays)")
        world.time += 5
        check(g.changed(up), "a pop after a pause")
    }
    test("volume sound: a skipped change does not delay the next, and the switches are read each time") {
        let pop = FakePop(), world = FeedbackWorld()
        let g = gate(pop, world)
        let up = VolumeLogic.Outcome.changed(from: 0.5, to: 0.51, unmuted: false)
        world.on = false
        check(!g.changed(up), "Waypoint's switch off")
        expect(pop.plays, 0)
        world.on = true
        check(g.changed(up), "turned on: it pops at once, as nothing played before")
        world.systemOn = false
        world.time += 1
        check(!g.changed(up), "the system's switch turned off since")
        world.systemOn = true
        check(!g.changed(.changed(from: 1, to: 1, unmuted: false)), "no change, no pop")
        check(g.changed(up), "and it did not use up the time")
        expect(pop.plays, 2)
    }
    test("volume sound: the system's setting reads as on when it was never set, and Waypoint's own as on") {
        check(VolumeFeedback.systemEnabled == ((CFPreferencesCopyAppValue("com.apple.sound.beep.feedback" as CFString, kCFPreferencesAnyApplication) as? NSNumber)?.boolValue ?? true), "the system's setting is what the preference says, on when absent")
        check(VolumeFeedbackLogic.minimumInterval >= 0.1 - 1e-9, "at most ten a second")
        check(SystemVolumePop.file.path.hasSuffix("BezelServices.loginPlugin/Contents/Resources/volume.aiff"), "the system's own sound")
    }
}
