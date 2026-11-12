import Foundation
import CoreGraphics

// Hold to repeat for launcher keys (Waypoint, Nov 2026). A binding with a repeat rate runs once as its key goes down; if
// the key is still held after the delay it runs again at that rate. The operating system's own key repeat is not used:
// it is swallowed with the key, and its speed is the user's typing setting, not the binding's.
//
// How it cannot get stuck: every tick of the timer (20 ms, on the main thread) first asks the hardware whether the key
// and exactly the chord's modifier keys are still down, and whether the launcher is still on and Waypoint is not
// handed over. Any "no" stops the timer. A hold is also stopped after a minute whatever happens, a new press replaces
// the old one, and the keyboard tap's restart stops it too (Launcher.stopRepeating). The hardware state
// (.hidSystemState) is the keys as the keyboard reports them, which a tap that swallows an event does not change.

/// The held key and the chord that is held with it, as the hardware says; tests give their own.
public struct LauncherRepeatHooks {
    public var now: () -> Double
    public var keyDown: (Int64) -> Bool
    public var heldModifiers: () -> UInt
    public var allowed: () -> Bool
    /// Starts calling the handler every tick, until `stopTimer`.
    public var startTimer: (@escaping () -> Void) -> Void
    public var stopTimer: () -> Void

    public init(now: @escaping () -> Double, keyDown: @escaping (Int64) -> Bool, heldModifiers: @escaping () -> UInt, allowed: @escaping () -> Bool,
                startTimer: @escaping (@escaping () -> Void) -> Void, stopTimer: @escaping () -> Void) {
        self.now = now; self.keyDown = keyDown; self.heldModifiers = heldModifiers; self.allowed = allowed
        self.startTimer = startTimer; self.stopTimer = stopTimer
    }
}

public final class LauncherRepeater {
    /// How often a held key is looked at, in seconds: how soon a release is noticed.
    public static let tickInterval: Double = 0.02
    /// No hold lasts longer than this: a last defence against a timer nothing else stopped.
    public static let longestHold: Double = 60

    /// The modifier keys' key codes, by the device bit each sets in the flags.
    public static let modifierKeys: [(bit: UInt, code: Int64)] = [
        (LauncherLogic.Device.leftControl, 59), (LauncherLogic.Device.leftShift, 56), (LauncherLogic.Device.rightShift, 60),
        (LauncherLogic.Device.leftCommand, 55), (LauncherLogic.Device.rightCommand, 54),
        (LauncherLogic.Device.leftOption, 58), (LauncherLogic.Device.rightOption, 61), (LauncherLogic.Device.rightControl, 62),
    ]

    private struct Hold {
        let keyCode: Int64
        let chord: UInt
        let startedAt: Double
        let interval: Double
        var nextFire: Double
        let fire: () -> Void
    }

    private let hooks: LauncherRepeatHooks
    private var hold: Hold?
    public private(set) var timerRunning = false

    public init(hooks: LauncherRepeatHooks) { self.hooks = hooks }

    public var isRepeating: Bool { hold != nil }

    /// Starts watching a key that was just pressed and already ran once. Returns false (and watches nothing) for a
    /// binding with no repeat rate.
    @discardableResult
    public func begin(keyCode: Int64, chord: UInt, binding: LauncherLogic.Binding, fire: @escaping () -> Void) -> Bool {
        stop("another key")
        guard let timing = LauncherLogic.repeatTiming(for: binding) else { return false }
        let now = hooks.now()
        hold = Hold(keyCode: keyCode, chord: chord, startedAt: now, interval: timing.interval, nextFire: now + timing.delay, fire: fire)
        timerRunning = true
        hooks.startTimer { [weak self] in self?.tick() }
        return true
    }

    /// One look at the held key: stops if anything changed, runs the action again when it is due.
    public func tick() {
        guard let h = hold else {
            if timerRunning { timerRunning = false; hooks.stopTimer() }
            return
        }
        let now = hooks.now()
        if !hooks.allowed() { stop("the launcher is off, or Waypoint is handed over"); return }
        if now - h.startedAt > Self.longestHold { stop("held for \(Int(Self.longestHold)) s"); return }
        if !hooks.keyDown(h.keyCode) { stop("the key was let go"); return }
        if hooks.heldModifiers() != h.chord { stop("the modifier keys changed"); return }
        guard now >= h.nextFire else { return }
        // The next run is one interval after this one was due, so the rate holds; a late tick drops what it missed.
        hold?.nextFire = max(h.nextFire + h.interval, now)
        h.fire()
    }

    public func stop(_ why: String) {
        if hold != nil { Log.io("launcher: repeat stopped, \(why)") }
        hold = nil
        if timerRunning { timerRunning = false; hooks.stopTimer() }
    }
}

extension LauncherRepeater {
    /// The one that watches the real keyboard, on a timer on the main thread.
    static let shared = LauncherRepeater(hooks: live)

    static let live: LauncherRepeatHooks = {
        let timer = Box<DispatchSourceTimer?>(nil)
        return LauncherRepeatHooks(
            now: { ProcessInfo.processInfo.systemUptime },
            keyDown: { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) },
            // The flags carry the side-specific device bits. Per-key state does not: with Right Command held, the system
            // reports key code 55 (Left Command) as down and 54 as up (observed on macOS 27, 12 Nov 2026).
            heldModifiers: { UInt(CGEventSource.flagsState(.hidSystemState).rawValue) & LauncherLogic.Device.all },
            allowed: { Launcher.enabled && Core.active },
            startTimer: { handler in
                timer.value?.cancel()
                let t = DispatchSource.makeTimerSource(queue: .main)
                t.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .milliseconds(2))
                t.setEventHandler { MainActor.assumeIsolated(handler) }
                timer.value = t
                t.resume()
            },
            stopTimer: { timer.value?.cancel(); timer.value = nil }
        )
    }()

    /// A value only the main thread touches (the live timer), held where a closure can reach it.
    private final class Box<T> { var value: T; init(_ v: T) { value = v } }
}
