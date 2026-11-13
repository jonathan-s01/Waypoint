// SPDX-License-Identifier: GPL-3.0-or-later
// Mouse tracking: what is under the mouse pointer is read as the pointer moves, and the cursor goes there (VoiceOver's
// cursor following the mouse pointer; NVDA+M). Off until the Mouse tracking setting is on, and only while TurnOver is
// the reader that speaks: where VoiceOver leads, its own pointer reading is the one heard. The keyboard focus is
// never moved by the pointer, the review cursor follows only if "mouse moves the cursor" is on, and a blank place
// (a window's background, a group with no name) is silent.
//
// The pointer is watched with a listen-only monitor of mouse-moved events: nothing is held back or changed, and the
// keyboard is never involved. A move asks for a look at most every tenth of a second, so a long sweep across a window
// says each item it crosses and the pointer coming to rest says where it ended. The look itself (the accessibility
// call for the element at a point) runs off the main thread, because an app that has stopped answering holds a call
// for as long as the messaging timeout (AGENTS.md).
import Foundation
import AppKit
import ApplicationServices

/// The choices of what to say, apart from every accessibility call so a test can drive them with plain values.
public struct PointerTracker<Hit: Equatable> {
    /// A pointer that has not travelled this far (in points) from where it was last looked at is resting, not moving:
    /// a trackpad brushed while typing or the tremor of a hand on a mouse says nothing.
    public static var minimumTravel: CGFloat { 6 }
    private var lookedAt: CGPoint?
    private var spoken: Hit?

    public init() {}

    /// Whether the pointer at `p` is worth a look.
    public func worthLooking(at p: CGPoint) -> Bool {
        guard let from = lookedAt else { return true }
        return hypot(p.x - from.x, p.y - from.y) >= Self.minimumTravel
    }

    public mutating func looked(at p: CGPoint) { lookedAt = p }

    public enum Outcome: Equatable { case say, blank, nothing }

    /// What a look found: whether to say it. The same item again is silent. A blank place (`nil`) is `.blank`, once,
    /// when the pointer came from an item (nothing is said for it); it is also forgotten, so coming back to the item
    /// says it again (as VoiceOver does).
    ///
    /// `insideSpoken`: the hit is a plain text or image inside the item last said (a conversation row, said whole, and
    /// then the line of text in it the pointer crosses). It says nothing, and the item said stays the one remembered,
    /// so the row is not said again when the pointer goes back to it.
    public mutating func answer(_ hit: Hit?, insideSpoken: Bool = false) -> Outcome {
        guard let hit else { let was = spoken != nil; spoken = nil; return was ? .blank : .nothing }
        guard hit != spoken else { return .nothing }
        if insideSpoken { return .nothing }
        spoken = hit
        return .say
    }

    /// A look that was given up on found nothing: where it was made is looked at again, not taken as seen.
    public mutating func forgetLook() { lookedAt = nil }

    public mutating func reset() { lookedAt = nil; spoken = nil }

    /// Whether the item last said is one of `items`.
    public func spokenIs(in items: [Hit]) -> Bool { spoken.map { items.contains($0) } ?? false }
}

/// Which look is out and which results still count, apart from every accessibility and main-thread call so a test can
/// drive it with plain values.
public struct LookState: Equatable {
    /// Bumped whenever a look still out must be dropped when it comes back.
    public private(set) var generation = 0
    /// The look last begun: a watchdog may give up only on its own look, never on a later one that is on its way (the
    /// first version did, and dropped good looks).
    public private(set) var lookID = 0
    public private(set) var inFlight = false

    public init() {}

    public mutating func begin() -> (generation: Int, id: Int) {
        inFlight = true
        lookID += 1
        return (generation, lookID)
    }

    public func accepts(generation g: Int) -> Bool { g == generation }

    /// A look came back: true if it is still wanted (and then nothing is out); a stale one is dropped.
    public mutating func arrived(generation g: Int) -> Bool {
        guard accepts(generation: g) else { return false }
        inFlight = false
        return true
    }

    /// The watchdog of look `id` fired: true if that look is still the one out, and it is left behind.
    public mutating func giveUp(onLookOf id: Int) -> Bool {
        guard id == lookID, inFlight else { return false }
        generation += 1
        inFlight = false
        return true
    }

    public mutating func stop() {
        generation += 1
        inFlight = false
    }
}

public enum MouseTracking {
    /// Tags the pointer's own speech, so a new item interrupts only that and not a notification, a focus change or typing.
    nonisolated static var speechSource: String { "mouse" }
    /// The longest between one look and the next while the pointer moves.
    nonisolated static var interval: TimeInterval { 0.1 }

    private struct Element: Equatable {
        let element: AXUIElement
        static func == (a: Element, b: Element) -> Bool { CFEqual(a.element, b.element) }
    }

    /// An element found on the lookup queue and handed to the main thread once. It is made inside the queue's block and
    /// read only after the hop to main, where the queue no longer touches it: one owner at a time. The reading (which
    /// holds the element too) is finished there, so main only says it.
    /// `label` is the role and the app's name for the log, read on the lookup queue: main asks the app nothing.
    private struct Found: @unchecked Sendable { let element: AXUIElement?; let blank: Bool; let reading: PointerReading?; let label: String; let ancestors: [AXUIElement] }
    /// What is kept back from the watchdog's time for the hop to main.
    nonisolated static var readMargin: TimeInterval { 0.15 }

    private static var monitor: Any?
    private static var tracker = PointerTracker<Element>()
    private static var lookScheduled = false
    private static var looks = LookState()
    private static var watchdog: DispatchWorkItem?
    private static var lastLookAt = Date.distantPast
    /// Replaced when a look is given up on: the app that held it may hold its thread for good, and the next look
    /// must not wait behind it.
    private static var queue = DispatchQueue(label: "turnover.mouse-tracking", qos: .userInteractive)
    /// How long a look may be out before the watchdog gives up on it.
    nonisolated static var watchdogAfter: TimeInterval { 1.0 }
    /// A look that took longer than this is written to the log (the role and the app, never the words).
    nonisolated static var slowLook: TimeInterval { 0.3 }

    public static var isOn: Bool { config.presentation.mouseTracking }

    /// Watches the pointer while the setting is on and TurnOver is reading, and stops the moment either is not so.
    public static func refresh() {
        let want = isOn && Core.active
        if want, monitor == nil { start() } else if !want, monitor != nil { stop() }
    }

    /// NVDA+M, and the menu: on or off, said.
    public static func toggle() {
        config.presentation.mouseTracking.toggle(); config.save()
        refresh()
        Speech.speakMessage(String(localized: "mouse tracking \(Phrases.onOff(isOn))", comment: "Mouse tracking turned on or off"))
    }

    private static func start() {
        tracker.reset()
        // Global: the pointer over other apps' windows. TurnOver's own are only menus and prompts, said as they open.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { event in
            // TurnOver's own synthetic moves (a click it makes for the person) are not the person's hand.
            if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
            onMain { moved() }
        }
        Log.info("mouse tracking: on")
    }

    private static func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        looks.stop()   // a look still out is dropped when it comes back
        watchdog?.cancel(); watchdog = nil
        lookScheduled = false
        tracker.reset()
        Log.info("mouse tracking: off")
    }

    private static func moved() {
        guard !lookScheduled else { return }   // the look already asked for reads the pointer where it is by then
        lookScheduled = true
        // At once when a tenth of a second has passed since the last look, and otherwise when it has.
        onMain(after: max(0, interval - Date().timeIntervalSince(lastLookAt))) { look() }
    }

    private static func look() {
        lookScheduled = false
        // The trackpad's explore is reading under the fingers; Say All is reading on, and the pointer is not what
        // the person is asking to be moved to.
        guard isOn, Core.active, !looks.inFlight, !Trackpad.controlOn, !SayAll.isRunning else { return }
        let p = pointer()
        guard tracker.worthLooking(at: p) else { return }
        tracker.looked(at: p)
        lastLookAt = Date()
        let (g, id) = looks.begin()
        let countsGroups = config.general.movesByGroups
        queue.async {
            let began = Date()
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) != .success { hit = nil }
            let blank = hit.map(isBlank) ?? true
            let label = describe(hit)
            var reading: PointerReading?
            if let hit, !blank {
                let deadline = began.addingTimeInterval(watchdogAfter - readMargin)
                reading = PointerReader.read(hit, deadline: deadline, countsGroups: countsGroups)
                if reading == nil { Log.warning("mouse tracking: the deadline was reached before reading (\(label))") }
                else if Date() > deadline { Log.warning("mouse tracking: the reading ended past its deadline (\(label))") }
            }
            let ancestors = hit.map { blank ? [] : parents(of: $0) } ?? []
            let found = Found(element: hit, blank: blank, reading: reading, label: label, ancestors: ancestors)
            let took = Date().timeIntervalSince(began)
            if took > slowLook { Log.warning("mouse tracking: the look took \(Int(took * 1000)) ms (\(label))") }
            onMain { arrived(found, generation: g) }
        }
        watchdog?.cancel(); watchdog = nil
        let item = DispatchWorkItem { MainActor.assumeIsolated { giveUp(onLookOf: id) } }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogAfter, execute: item)
    }

    /// The look `id` has not come back: leave it and its thread, and look again where the pointer is now. Last time
    /// the reading went on over everything else until the person clicked (a tester, 9 Nov 2026).
    private static func giveUp(onLookOf id: Int) {
        guard isOn, Core.active, looks.giveUp(onLookOf: id) else { return }
        Log.warning("mouse tracking: a look was out over \(Int(watchdogAfter * 1000)) ms; given up on")
        tracker.forgetLook()
        queue = DispatchQueue(label: "turnover.mouse-tracking", qos: .userInteractive)
        moved()
    }

    /// The few levels above a plain text or image, for the check that it is inside an item already said. Runs on the
    /// lookup queue; any other role has none, so only these can be silenced by a row around them.
    nonisolated static func parents(of e: AXUIElement) -> [AXUIElement] {
        guard ["AXStaticText", "AXImage"].contains(e.role) else { return [] }
        var up: [AXUIElement] = []
        var cur = e
        for _ in 0..<4 {
            guard let p = cur.element(kAXParentAttribute), p.string(kAXRoleAttribute) != "AXWindow" else { break }
            // Only a row or cell can be the item said whole: a named group around a page is said once and must not
            // silence every text in it.
            // And only one with words of its own: a GitHub chat cell said just "cell" (4 characters) and silenced the
            // message in it (13 Nov 2026, from the log).
            if ["AXRow", "AXCell"].contains(p.role),
               [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains(where: { !(p.string($0) ?? "").isEmpty }) { up.append(p) }
            cur = p
        }
        return up
    }

    /// What a look found, for the log: the role and the app, and not a word of what it says. Asks the app, so it runs
    /// on the lookup queue only.
    nonisolated static func describe(_ e: AXUIElement?) -> String {
        guard let e else { return "nothing" }
        let app = NSRunningApplication(processIdentifier: e.pid)?.bundleIdentifier ?? "pid \(e.pid)"
        return "\(e.role) in \(app)"
    }

    /// Where the pointer is, in the coordinates the accessibility calls use: from the top left of the main display, and
    /// the same on any other display (the system's own, not worked out from a screen's height).
    private static func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? VoiceOverKeysPlugin.mouseLocation() }

    /// Whether what is under the pointer is only the place behind the items: a window's background, or a group, scroll
    /// area or the like with no name and no words of its own (a chat app's layout is nests of them). Said, it would
    /// be "group" again and again as the pointer crosses the gaps. Runs on the lookup queue.
    nonisolated static func isBlank(_ e: AXUIElement) -> Bool {
        let role = e.role
        if role == "AXWindow" { return true }
        guard ObjectNavigator.layoutRoles.contains(role) else { return false }
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].allSatisfy { (e.string($0) ?? "").isEmpty }
    }

    private static func arrived(_ found: Found, generation g: Int) {
        guard looks.arrived(generation: g) else { return }
        watchdog?.cancel(); watchdog = nil
        // The pointer may have gone on (or come to rest somewhere else) while the look was out: the moves in that time
        // were not asked for, so its resting place is looked at now.
        defer { if isOn, Core.active, tracker.worthLooking(at: pointer()) { moved() } }
        guard isOn, Core.active else { return }
        let inside = found.ancestors.map { Element(element: $0) }
        let insideSpoken = tracker.spokenIs(in: inside)
        if insideSpoken { Log.io("mouse tracking: silent, inside the row just said (\(found.label))") }
        switch tracker.answer(found.blank ? nil : found.element.map { Element(element: $0) }, insideSpoken: insideSpoken) {
        case .nothing: break
        case .blank:
            Log.io("mouse tracking: blank place (\(found.label))")
            // No empty space sound: when on it made a lot of extra noise that was annoying (a tester, 10 Nov 2026).
        case .say:
            // As the trackpad's explore does: what was being said gives way, and the item is read. The focus stays where it is.
            guard let reading = found.reading else { tracker.forgetLook(); return }
            Log.io("mouse tracking: says \(found.label)")
            if config.presentation.mouseInterruptsSpeech { Speech.cancel() } else { Speech.cancel(source: Self.speechSource) }
            ObjectNavigator.shared.hover(reading, movingCursor: config.presentation.mouseMovesCursor)
        }
    }
}
