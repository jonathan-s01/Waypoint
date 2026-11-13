// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint: put the reading cursor where the mouse pointer is, without clicking.
// Hold the TurnOver key (or the review layer's keys, or keys the person chose) and click: the click is held back from
// the app, the cursor goes to what is under the pointer and says it, and the review layer reads on from there.
// The key command for the same thing without a click is VO-Shift-F5 (cursorToMouse).
import Foundation
import AppKit
import ApplicationServices

/// Which clicks are the cursor's. Pure, so it can be tested.
nonisolated public enum PointerPlaceLogic {
    /// `flags` carries the device-dependent modifier bits of the click. The TurnOver key always counts; the review
    /// layer's hold keys count while the layer is on; `extraHold` is whatever the person added (0: none).
    public static func captures(flags: UInt, turnOverHeld: Bool, layerHold: UInt, extraHold: UInt) -> Bool {
        if turnOverHeld { return true }
        if layerHold != 0, flags & layerHold == layerHold { return true }
        if extraHold != 0, flags & extraHold == extraHold { return true }
        return false
    }

    /// Whether the click is the second reader's: the layer's own keys held, or Right Option with the TurnOver key (as
    /// for its commands). Any other click that places is the keyboard's reading.
    public static func isSecond(flags: UInt, turnOverHeld: Bool, layerHold: UInt) -> Bool {
        let held = flags & ReviewLayerLogic.Device.all
        if layerHold != 0, held & layerHold == layerHold { return true }
        return turnOverHeld && held & ReviewLayerLogic.Device.rightOption != 0 && held & ReviewLayerLogic.Device.leftOption == 0
    }
}

enum PointerPlace {
    static let enabledKey = "waypoint.pointerPlace", holdKey = "waypoint.pointerPlace.hold"

    private struct Settings {
        var enabled: Bool
        var extraHold: UInt
        var layerHold: UInt
    }

    /// The tap's source is the main run loop, so the tap and the commands share the main thread.
    private static var settings = Settings(
        enabled: UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true,
        extraHold: (UserDefaults.standard.object(forKey: holdKey) as? NSNumber)?.uintValue ?? 0,
        layerHold: 0)

    static var enabled: Bool { settings.enabled }

    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?
    /// A click that was held back goes on being held back (its drag and release) however the keys change meanwhile.
    private static var swallowing = false

    // MARK: Lifecycle

    /// The tap is up while Waypoint reads and the feature is on. It watches only presses, drags and releases, never moves.
    static func refresh() {
        var s = settings
        s.layerHold = ReviewLayer.enabled ? ReviewLayer.chord.hold : 0
        settings = s
        if s.enabled, Core.active { start() } else { stop() }
    }

    private static func start() {
        if tap == nil {
            let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged]
            var mask: CGEventMask = 0
            for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
            let callback: CGEventTapCallBack = { _, type, event, _ in
                // The tap's source is the main run loop, so this runs on the main thread.
                let hold = MainActor.assumeIsolated { PointerPlace.handle(type, event) }
                return hold ? nil : Unmanaged.passUnretained(event)
            }
            guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: nil) else {
                Log.warning("pointer place: no event tap (Accessibility or Input Monitoring not granted?)")
                return
            }
            tap = t
            source = CFMachPortCreateRunLoopSource(nil, t, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            Log.info("pointer place: ready")
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private static func stop() {
        swallowing = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    // MARK: The tap

    /// True when the event is the cursor's and must not reach the app.
    private static func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            swallowing = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .leftMouseDown, .rightMouseDown:
            // TurnOver's own clicks (VO-Shift-Space) are not the person's.
            if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return false }
            let s = settings
            let flags = UInt(event.flags.rawValue), turnOverHeld = KeyboardGesture.turnOverHeld?() ?? false
            guard s.enabled,
                  PointerPlaceLogic.captures(flags: flags, turnOverHeld: turnOverHeld, layerHold: s.layerHold, extraHold: s.extraHold) else { return false }
            swallowing = true
            let p = event.location
            let second = PointerPlaceLogic.isSecond(flags: flags, turnOverHeld: turnOverHeld, layerHold: s.layerHold)
            onMain { place(at: p, second: second) }
            return true
        case .leftMouseDragged, .rightMouseDragged:
            return swallowing
        case .leftMouseUp, .rightMouseUp:
            let held = swallowing
            swallowing = false
            return held
        default:
            return false
        }
    }

    // MARK: Placing

    /// The cursor to what is at `p` (the screen's top-left coordinates, as accessibility has them), said: the keyboard's
    /// reading, or the second reader's (which leaves the keyboard's cursor and focus alone).
    static func place(at p: CGPoint, second: Bool = false) {
        guard let e = VoiceOverKeysPlugin.element(at: p) else {
            Log.io("pointer place: nothing at (\(Int(p.x)), \(Int(p.y)))")
            Speech.speakMessage(String(localized: "nothing under the pointer", comment: "Spoken message"))
            return
        }
        Log.io("pointer place: \(e.role) at (\(Int(p.x)), \(Int(p.y))) for the \(second ? "second" : "first") reader")
        Speech.cancel()
        if second { ReviewLayer.place(e, at: p) }
        else { ObjectNavigator.shared.placeReading(on: e, at: p) }
    }

    // MARK: The keys

    static func toggleEnabled() {
        var s = settings
        s.enabled.toggle()
        settings = s
        UserDefaults.standard.set(s.enabled, forKey: enabledKey)
        refresh()
        Speech.speakMessage(s.enabled ? String(localized: "click to place the cursor on", comment: "Spoken message") : String(localized: "click to place the cursor off", comment: "Spoken message"))
    }

    /// Takes the modifier keys held at the next key press as extra keys to hold while clicking.
    static func captureHold() {
        TurnOverMenu.captureKey(prompt: String(localized: "Hold the keys to hold while clicking to place the cursor, then press any letter", comment: "Spoken message: waiting for a key chord")) { g in
            let bits = UInt(g.flags.rawValue) & ReviewLayerLogic.Device.all
            guard bits != 0 else {
                Speech.speakMessage(String(localized: "No modifier key was held; nothing changed", comment: "Spoken message"))
                return
            }
            setHold(bits)
            Speech.speakMessage(String(localized: "saved", comment: "Spoken message"))
        }
    }

    static func setHold(_ bits: UInt) {
        var s = settings
        s.extraHold = bits
        settings = s
        UserDefaults.standard.set(NSNumber(value: bits), forKey: holdKey)
        Log.io("pointer place: extra hold keys \(bits)")
    }

    static func resetHold() {
        setHold(0)
        Speech.speakMessage(String(localized: "click to place the cursor: only the TurnOver key and the review layer's keys", comment: "Spoken message"))
    }
}

final class PointerPlacePlugin: GlobalPlugin {
    required init() {
        super.init()
        let category = "Waypoint"
        script("pointerPlaceEnable", String(localized: "Turns on or off placing the cursor by clicking with the TurnOver key or the review layer's keys held (the click is not sent to the app)", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            PointerPlace.toggleEnabled()
        }
        script("pointerPlaceSetHold", String(localized: "Chooses extra keys to hold while clicking to place the cursor without clicking", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            PointerPlace.captureHold()
        }
        script("pointerPlaceResetKeys", String(localized: "Removes the extra keys for placing the cursor by clicking: only the TurnOver key and the review layer's keys remain", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            PointerPlace.resetHold()
        }
    }
}
