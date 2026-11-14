// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint off and on: Right Option + Right Shift + / (Waypoint, not in upstream TurnOver).
//
// Off means no screen reader: Waypoint is silent and its keys are released, and VoiceOver is NOT started. That is
// the difference from Command Control Period, which quits and hands the Mac to VoiceOver (kept as the way out).
// The state is saved, so Waypoint stays off through a restart, a login or a crash and relaunch. A deliberate quit
// clears it (the app asks for that in main.swift), so opening Waypoint again always starts it on.
//
// While off, nothing may start VoiceOver: the hand-over functions in HandOver and the lead watcher ask `isPaused`.
// A listen of its own (a small event tap on a thread of its own) hears the chord whether the reader is on or off.
import Foundation
import CoreGraphics

nonisolated public enum WaypointPause {
    public static let defaultsKey = "waypoint.paused"
    private static let flag = Locked(UserDefaults.standard.bool(forKey: defaultsKey))

    /// Waypoint is off by its own key. Read from any thread.
    public static var isPaused: Bool { flag.value }

    /// Off or on, remembered across restarts.
    public static func set(_ paused: Bool) {
        flag.value = paused
        UserDefaults.standard.set(paused, forKey: defaultsKey)
    }

    // MARK: The chord

    public static let slashKeyCode: Int64 = 44
    // The device-dependent modifier bits (IOKit's NX_DEVICE*KEYMASK): left and right of each key are told apart here.
    private static let rightOption: UInt64 = 0x40
    private static let rightShift: UInt64 = 0x04
    private static let otherModifiers: UInt64 = 0x01 | 0x02 | 0x08 | 0x10 | 0x20 | 0x2000   // left Control, Shift, Command, Option; right Command, Control

    /// Right Option and Right Shift held with the slash key, and no other modifier (Fn and Caps Lock do not count).
    public static func isChord(keyCode: Int64, rawFlags: UInt64) -> Bool {
        keyCode == slashKeyCode
            && rawFlags & rightOption != 0 && rawFlags & rightShift != 0
            && rawFlags & otherModifiers == 0
    }

    // MARK: Hearing it

    private static let toggle = Locked<(@MainActor () -> Void)?>(nil)
    private static let tap = Locked<CFMachPort?>(nil)
    private static let swallowingKeyUp = Locked(false)

    /// Starts listening; calling it again does nothing once it runs. Needs the same Accessibility and Input Monitoring
    /// permission as the reader's keys: without it the tap is not made, and the next call tries again.
    public static func listen(_ onToggle: @escaping @MainActor () -> Void) {
        toggle.value = onToggle
        guard tap.value == nil else { return }
        let thread = Thread {
            guard tap.value == nil else { return }
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
            guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: tapCallback,
                                               userInfo: nil) else {
                Log.error("waypoint off/on: could not create the key tap (Accessibility or Input Monitoring not granted?)")
                return
            }
            tap.value = port
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            Log.info("waypoint off/on: listening for Right Option + Right Shift + /")
            CFRunLoopRun()
        }
        thread.name = "waypoint.pause-chord"
        thread.start()
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, _ in WaypointPause.handle(type, event) }

    private static func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = tap.value { CGEvent.tapEnable(tap: port, enable: true) }
        case .keyDown:
            guard isChord(keyCode: event.getIntegerValueField(.keyboardEventKeycode), rawFlags: event.flags.rawValue) else { break }
            swallowingKeyUp.value = true
            // Held down, it repeats: one press is one change.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, let action = toggle.value { onMain { action() } }
            return nil
        case .keyUp:
            if event.getIntegerValueField(.keyboardEventKeycode) == slashKeyCode, swallowingKeyUp.value {
                swallowingKeyUp.value = false
                return nil
            }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: The sound

    /// Two tones as skim mode has: rising for on, falling for off.
    @MainActor public static func tone(on: Bool) {
        let (first, second) = on ? (700.0, 1050.0) : (1050.0, 700.0)
        Tones.beep(first, 30, volume: 0.15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { Tones.beep(second, 40, volume: 0.15) }
    }
}
