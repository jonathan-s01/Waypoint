// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's skim mode (plan 4.16): in a list of messages, files, mail or results, Down and Up go from item to item
// saying only its key words, quickly, with a small tick between; Return says the item in full and ends the mode.
//
// While the mode is on the plain arrows, Return and Escape are claimed one by one (as read while typing does it):
// the mode ends by itself when the focus or the app changes, a menu opens, the setting is turned off, or five minutes
// pass with no key. There is no timer that goes on by itself: every item is a key press.
//
// What is cut from an item, and the decisions about keys, are pure and in SkimText.swift (tested in SkimTests).
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

/// The mode itself: on or off, the list, and where the last key left the review cursor.
@MainActor
enum SkimMode {
    static let settingKey = "waypoint.skim"

    /// The feature: on by default, so the toggle key works. The mode is only on after the key is pressed.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    private(set) static var isOn = false
    private static var items: [AXUIElement] = []
    private static var index: Int?
    private static var kind: SkimText.Kind = .generic
    private static var focusElement: AXUIElement?
    private static var appPid: pid_t = 0
    private static var lastUsed = Date.distantPast
    // The speech rate is raised for an item and put back a moment after the last one (the voice has no rate for one
    // utterance here). The number says which raise a pending put-back belongs to.
    private static var rateRaised = false
    private static var rateGeneration = 0

    /// Roles of a list that skim reads item by item.
    private static let listRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser"]

    // MARK: State

    private static func situation() -> SkimLogic.Situation {
        let sameFocus: Bool
        if let f = focusElement, let now = API.focusObject { sameFocus = CFEqual(f, now.element) } else { sameFocus = true }
        return SkimLogic.Situation(
            settingEnabled: enabled,
            isOn: isOn,
            sameApp: NSWorkspace.shared.frontmostApplication?.processIdentifier == appPid,
            sameFocus: sameFocus,
            menuOpen: AXHandler.shared.isMenuOpen,
            idleSeconds: Date().timeIntervalSince(lastUsed))
    }

    /// Whether the mode may go on; if not, it ends here and says so, so the key that follows goes to the app.
    static func stillValid() -> Bool {
        guard isOn else { return false }
        if let why = SkimLogic.offReason(situation()) {
            Log.io("skim: off (\(why))")
            turnOff()
            return false
        }
        return true
    }

    static func handle(_ event: Event) {
        guard isOn else { return }
        switch event.kind {
        case .gainFocus:
            if let f = focusElement, event.obj.isSameElement(as: f) { return }
            Log.io("skim: off (the focus moved)")
            turnOff()
        case .foreground, .menuStart, .appModuleLoseFocus:
            Log.io("skim: off (\(event.kind.rawValue))")
            turnOff()
        default:
            break
        }
    }

    /// Ends the mode without a word or a sound (the plugin closing).
    static func reset() {
        restoreRate()
        isOn = false; items = []; index = nil; focusElement = nil
    }

    // MARK: On and off

    static func toggle() {
        guard enabled else {
            Speech.speakMessage(String(localized: "skim is off; turn it on with the skim enable command in the key list", comment: "Spoken message"))
            return
        }
        if isOn { turnOff() } else { turnOn() }
    }

    static func toggleEnabled() {
        enabled.toggle()
        if !enabled, isOn { turnOff(speaking: false) }
        Speech.speakMessage(enabled ? String(localized: "skim enabled", comment: "Spoken message") : String(localized: "skim disabled", comment: "Spoken message"))
    }

    private static func turnOn() {
        guard let start = ObjectNavigator.shared.element, let list = container(from: start) else {
            Speech.speakMessage(String(localized: "nothing to skim here", comment: "Spoken message"))
            return
        }
        let deadline = Date().addingTimeInterval(1.0)
        let all = listItems(list, deadline: deadline)
        guard Date() <= deadline else {
            Speech.speakMessage(String(localized: "this list is too big to skim", comment: "Spoken message"))
            return
        }
        guard !all.isEmpty else {
            Speech.speakMessage(String(localized: "empty", comment: "Spoken message"))
            return
        }
        items = all
        index = all.firstIndex { contains($0, start) }
        appPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? start.pid
        kind = SkimText.kind(bundleID: NSRunningApplication(processIdentifier: appPid)?.bundleIdentifier)
        focusElement = API.focusObject?.element
        lastUsed = Date()
        isOn = true
        Log.io("skim: on, \(all.count) items, \(kind.rawValue)")
        tone(on: true)
        Speech.speakMessage(String(localized: "skim on", comment: "Spoken message") + ", " + Phrases.items(all.count))
    }

    private static func turnOff(speaking: Bool = true) {
        guard isOn else { return }
        reset()
        guard speaking else { return }
        tone(on: false)
        Speech.speakMessage(String(localized: "skim off", comment: "Spoken message"))
    }

    private static func tone(on: Bool) {
        let (first, second) = on ? (700.0, 1050.0) : (1050.0, 700.0)
        Tones.beep(first, 30, volume: 0.15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { Tones.beep(second, 40, volume: 0.15) }
    }

    // MARK: The list

    /// The list to skim: the held list, the list the cursor is in, or the nearest group around it. Never the whole
    /// window: skimming that would be skimming every control.
    private static func container(from start: AXUIElement) -> AXUIElement? {
        if ObjectNavigator.shared.isHolding, let held = ObjectNavigator.shared.heldList { return held }
        var x: AXUIElement? = start
        var hops = 0
        while let e = x, hops < 60 {
            let role = e.role
            if role == "AXWindow" || role == "AXSheet" || role == "?" { return nil }
            if listRoles.contains(role) || ObjectNavigator.isGroup(e) { return e }
            x = e.element(kAXParentAttribute)
            hops += 1
        }
        return nil
    }

    private static func listItems(_ list: AXUIElement, deadline: Date) -> [AXUIElement] {
        if let held = ObjectNavigator.shared.heldList, held.isSame(list) {
            let rows = list.elements(kAXRowsAttribute)
            return rows.isEmpty ? list.elements(kAXChildrenAttribute) : rows
        }
        return ObjectNavigator.groupItems(list, stoppingWhen: { Date() > deadline })
    }

    /// Whether `start` is the item or inside it.
    private static func contains(_ item: AXUIElement, _ start: AXUIElement) -> Bool {
        var x: AXUIElement? = start
        var hops = 0
        while let e = x, hops < 40 {
            if e.isSame(item) { return true }
            x = e.element(kAXParentAttribute)
            hops += 1
        }
        return false
    }

    /// What the item says: its name, else its text, else its value.
    private static func fullText(of item: AXUIElement) -> String {
        let o = ObjectFactory.make(item)
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var t = o.name
        if blank(t) { t = ElementMatcher.text(of: item) }
        if blank(t) { t = o.value ?? "" }
        if blank(t) { t = ObjectNavigator.words(item) }
        return t
    }

    // MARK: Moving

    /// Up and Down.
    static func move(forward: Bool) {
        lastUsed = Date()
        guard let next = SkimLogic.step(from: index, count: items.count, forward: forward) else {
            Tones.edge()
            Speech.speakMessage(forward ? String(localized: "bottom", comment: "Spoken message") : String(localized: "top", comment: "Spoken message"))
            return
        }
        let item = items[next]
        guard item.role != "?" else {
            Speech.speakMessage(String(localized: "the list changed", comment: "Spoken message"))
            turnOff()
            return
        }
        index = next
        ObjectNavigator.shared.place(item)
        let words = SkimText.keyWords(fullText(of: item), kind: kind)
        Tones.beep(1500, 10, volume: 0.1)
        raiseRate()
        Speech.speakText(words.isEmpty ? String(localized: "blank", comment: "Spoken message") : words)
    }

    /// Return: the item in full, at the user's own rate, the review cursor left on it, the mode off.
    static func readFull() {
        let item = index.map { items[$0] }
        reset()
        tone(on: false)
        guard let item, item.role != "?" else {
            ObjectNavigator.shared.reportCurrent()
            return
        }
        ObjectNavigator.shared.moveTo(item)
    }

    /// Escape.
    static func escape() {
        turnOff()
    }

    // MARK: Speed

    private static func raiseRate() {
        guard let player = Speech.player else { return }
        player.rate = SkimText.fasterRate(from: config.speech.rate)
        rateRaised = true
        rateGeneration += 1
        let mine = rateGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if mine == rateGeneration { restoreRate() }
        }
    }

    private static func restoreRate() {
        guard rateRaised else { return }
        rateRaised = false
        rateGeneration += 1
        Speech.player?.rate = config.speech.rate
    }
}

/// The commands, in the key list under Waypoint. The arrows, Return and Escape are not commands: they are claimed
/// one by one, and only while the mode is on.
final class SkimModePlugin: GlobalPlugin {
    private var moves: [SkimLogic.Move: Script] = [:]

    required init() {
        super.init()
        let category = "Waypoint"
        script("skimEnable", String(localized: "Turns the skim feature on or off", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            SkimMode.toggleEnabled()
        }
        script("skim", String(localized: "In a list of messages, files or results, switches Up and Down to skimming the items by their key words, quickly, and back; Return reads the item in full", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+n"], category: category) { _ in
            SkimMode.toggle()
        }

        let moveDescription = String(localized: "An arrow key, Return or Escape, while skimming", comment: "A command, as the key list and keyboard help say it")
        func make(_ move: SkimLogic.Move, _ run: @escaping () -> Void) {
            moves[move] = Script(name: "skimMove", description: moveDescription, category: category, owner: self) { _ in run() }
        }
        make(.previous) { SkimMode.move(forward: false) }
        make(.next) { SkimMode.move(forward: true) }
        make(.readFull) { SkimMode.readFull() }
        make(.off) { SkimMode.escape() }
    }

    public override func script(for gesture: KeyboardGesture) -> Script? {
        if let own = super.script(for: gesture) { return own }
        // Cheapest tests first: nothing here costs anything while the mode is off.
        guard SkimMode.isOn, let move = SkimLogic.move(forKey: gesture.keyName, modifiers: gesture.modifiers) else { return nil }
        guard SkimMode.stillValid() else { return nil }
        return moves[move]
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        SkimMode.handle(event)
        next()
    }

    override func terminate() {
        SkimMode.reset()
    }
}
