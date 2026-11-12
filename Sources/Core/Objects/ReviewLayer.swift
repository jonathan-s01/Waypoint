import AppKit
import ApplicationServices

// The review layer (plan 4.7, replacing the sticky "read while typing" mode): a second reader, in browse mode, driven
// by a held chord, while the keyboard stays where it is. Hold Left Option and Right Shift and press H: the review
// cursor goes to the next heading, as in browse mode, and the field keeps the keyboard. The letters, the arrows
// (Right Option with them: by word), Home, End and Page keys are the document's own commands, found by the same
// scripts and the same keys, so changing one changes both. Left Shift reverses a letter; with an arrow it is passed
// to the field as Shift, so the chord selects text in the field as usual (and with Right Option, by word).
//
// Without the chord nothing here runs: the cost to any other key is one flag test. A tap of the arm command (VO-Option-R)
// makes the next key a layer key, two taps latch the layer on until the command is pressed again. All the chord keys
// can be changed: "review layer hold keys" and its two companions take the keys held at the next key press.

/// The decisions, pure: which keys the layer takes and what each means.
nonisolated public enum ReviewLayerLogic {

    /// The modifier keys as the keyboard reports them in an event's flags (the device-dependent bits).
    public enum Device {
        public static let leftControl: UInt = 0x1, leftShift: UInt = 0x2, rightShift: UInt = 0x4
        public static let leftCommand: UInt = 0x8, rightCommand: UInt = 0x10
        public static let leftOption: UInt = 0x20, rightOption: UInt = 0x40, rightControl: UInt = 0x2000
        public static let all: UInt = leftControl | leftShift | rightShift | leftCommand | rightCommand | leftOption | rightOption | rightControl
    }
    /// The generic flags, which the armed layer reads (it has no particular key to hold).
    public enum Generic {
        public static let shift: UInt = 0x20000, control: UInt = 0x40000, option: UInt = 0x80000, command: UInt = 0x100000
    }

    public struct Chord: Equatable, Sendable {
        /// All of these keys held: the layer is on for the key pressed.
        public var hold: UInt
        /// Held too: the key reversed (Shift H, the previous heading), or for an arrow, selecting.
        public var reverse: UInt
        /// Held too: with an arrow, by word.
        public var word: UInt
        public init(hold: UInt, reverse: UInt, word: UInt) { self.hold = hold; self.reverse = reverse; self.word = word }
        public static let standard = Chord(hold: Device.leftOption | Device.rightShift, reverse: Device.leftShift, word: Device.rightOption)
    }

    public enum Decision: Equatable, Sendable {
        /// A key of the document's own, by its identifier ("kb:h", "kb:shift+h", "kb:option+leftArrow").
        case review(String)
        /// Handed to the field as this key (Shift or Option Shift and an arrow): it selects there.
        case select(String)
        /// Enter: press what the review cursor is on.
        case activate
        /// Escape while the layer is armed or latched: the layer ends.
        case off
    }

    static let arrows: Set<String> = ["leftArrow", "rightArrow", "upArrow", "downArrow"]
    static let positionKeys: Set<String> = ["home", "end", "pageUp", "pageDown"]

    /// What a key means to the layer, nil when it is not the layer's (it goes to the application as it is).
    /// `armed`: the layer is armed or latched, so the plain keys count and the ordinary Shift and Option are the
    /// reverse and word keys. `flags` are the event's raw flags.
    public static func decide(flags: UInt, keyName: String, chord: Chord, armed: Bool, turnOverKey: Bool) -> Decision? {
        guard !turnOverKey else { return nil }
        let shift: Bool, option: Bool
        if armed {
            guard flags & (Generic.control | Generic.command) == 0 else { return nil }
            shift = flags & Generic.shift != 0
            option = flags & Generic.option != 0
        } else {
            let held = flags & Device.all
            guard chord.hold != 0, held & chord.hold == chord.hold else { return nil }
            // Any other modifier (Control, Command, a second Shift) means this is some other command.
            guard held & ~(chord.hold | chord.reverse | chord.word) == 0 else { return nil }
            shift = chord.reverse != 0 && held & chord.reverse == chord.reverse
            option = chord.word != 0 && held & chord.word == chord.word
        }
        if armed, keyName == "escape", !shift, !option { return .off }
        if arrows.contains(keyName) {
            let mods = (option ? "option+" : "") + (shift ? "shift+" : "")
            return shift ? .select("kb:" + mods + keyName) : .review("kb:" + mods + keyName)
        }
        if positionKeys.contains(keyName) { return shift || option ? nil : .review("kb:" + keyName) }
        if keyName == "enter" || keyName == "numpadEnter" { return shift || option ? nil : .activate }
        // Tab moves the review cursor to the next link or control; Left Shift reverses it. The real focus does not move.
        if keyName == "tab" { return option ? nil : .review(shift ? "kb:shift+tab" : "kb:tab") }
        // Letters and digits as the document's quick keys; the comma is its container key.
        if keyName.count == 1, let c = keyName.first, (c.isLetter && c.isASCII) || c.isNumber || c == "," {
            return .review("kb:" + (shift ? "shift+" : "") + keyName)
        }
        return nil
    }

    /// The document's scripts the layer may run. A script that sends the key on to the application (Tab, Escape, Enter
    /// when nothing is under the cursor) would type into the field, so it is not among them.
    public static func isAllowed(script name: String) -> Bool {
        ["moveBy", "next", "previous", "vo_next", "vo_previous", "startOf", "endOf", "topOf", "bottomOf", "pastEnd", "sayAll"].contains { name.hasPrefix($0) }
    }

    /// How long an armed layer waits for its key, and a latched one stays without a key.
    public static let armLimit: TimeInterval = 5
    public static let idleLimit: TimeInterval = 300
}

/// The layer itself.
@MainActor
enum ReviewLayer {
    static let enabledKey = "waypoint.reviewLayer"
    static let holdKey = "waypoint.reviewLayer.hold", reverseKey = "waypoint.reviewLayer.reverse", wordKey = "waypoint.reviewLayer.word"

    /// On unless switched off: it is a held chord, so it cannot get stuck.
    static var enabled: Bool = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: enabledKey) }
    }

    static var chord: ReviewLayerLogic.Chord = {
        let d = UserDefaults.standard, std = ReviewLayerLogic.Chord.standard
        func bits(_ k: String, _ fallback: UInt) -> UInt { d.object(forKey: k).flatMap { ($0 as? NSNumber)?.uintValue } ?? fallback }
        return .init(hold: bits(holdKey, std.hold), reverse: bits(reverseKey, std.reverse), word: bits(wordKey, std.word))
    }()

    private(set) static var armed = false
    private(set) static var latched = false
    private static var armedAt = Date.distantPast
    private(set) static var lastUsed = Date.distantPast
    private static var syncedFocus: AXUIElement?
    private static var placedAt = Date.distantPast
    private static var syncedDocument: ObjectIdentifier?
    /// Where the latest message began when the review last started from a field; a later one has arrived when it moves.
    private static var messageStart: Int?
    private static var windowDocuments: Set<ObjectIdentifier> = []

    // MARK: Which keys

    /// The question every key asks, so it must be cheap: no layer, no chord, a single flag test.
    static func decision(for g: KeyboardGesture) -> ReviewLayerLogic.Decision? {
        guard enabled else { return nil }
        let on = isArmedOrLatched
        let raw = UInt(g.flags.rawValue)
        if !on, raw & chord.hold != chord.hold { return nil }
        guard on || chord.hold != 0 else { return nil }
        return ReviewLayerLogic.decide(flags: raw, keyName: g.keyName, chord: chord, armed: on, turnOverKey: g.modifiers.contains(.turnover))
    }

    /// Armed (for one key) or latched, and still valid: a lapsed one ends here, silently.
    static var isArmedOrLatched: Bool {
        guard armed || latched else { return false }
        if armed, Date().timeIntervalSince(armedAt) > ReviewLayerLogic.armLimit { armed = false }
        if latched, Date().timeIntervalSince(lastUsed) > ReviewLayerLogic.idleLimit { Log.io("review layer: latch ended (idle)"); latched = false }
        if (armed || latched), AXHandler.shared.isMenuOpen { Log.io("review layer: ended (a menu is open)"); armed = false; latched = false }
        return armed || latched
    }

    // MARK: Arming

    /// The arm command: once, the next key; twice, the layer stays on; again when it is on, off.
    static func armCommand() {
        enabled = true
        if latched { end(speaking: true); return }
        if armed, ScriptHandler.lastScriptRepeatCount >= 1 {
            armed = false; latched = true; lastUsed = Date()
            tone(on: true)
            Speech.speakMessage(String(localized: "review layer on", comment: "Spoken message"))
            return
        }
        armed = true; armedAt = Date()
        Tones.beep(880, 35, volume: 0.18)
        Speech.speakMessage(String(localized: "review", comment: "Spoken message: the next key reads around instead of typing"))
    }

    static func end(speaking: Bool) {
        let was = armed || latched
        armed = false; latched = false
        guard was, speaking else { return }
        tone(on: false)
        Speech.speakMessage(String(localized: "review layer off", comment: "Spoken message"))
    }

    static func handle(_ event: Event) {
        guard armed || latched else { return }
        switch event.kind {
        case .foreground, .menuStart, .appModuleLoseFocus:
            Log.io("review layer: ended (\(event.kind.rawValue))")
            end(speaking: latched)
        default:
            break
        }
    }

    static func reset() { armed = false; latched = false; syncedFocus = nil; messageStart = nil; syncedDocument = nil; windowDocuments = [] }

    static func toggleEnabled() {
        enabled.toggle()
        if !enabled { end(speaking: false) }
        PointerPlace.refresh()
        Speech.speakMessage(enabled ? String(localized: "review layer enabled", comment: "Spoken message") : String(localized: "review layer disabled", comment: "Spoken message"))
    }

    private static func tone(on: Bool) {
        let (first, second) = on ? (880.0, 1320.0) : (1320.0, 880.0)
        Tones.beep(first, 35, volume: 0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { Tones.beep(second, 45, volume: 0.18) }
    }

    // MARK: The keys, remapped

    enum Which { case hold, reverse, word }

    /// Takes the modifier keys held at the next key press as this part of the chord.
    static func capture(_ which: Which) {
        let prompt: String
        switch which {
        case .hold: prompt = String(localized: "Hold the keys that switch the review layer on, then press any letter", comment: "Spoken message: waiting for a key chord")
        case .reverse: prompt = String(localized: "Hold the key that reverses a review key, then press any letter", comment: "Spoken message: waiting for a key")
        case .word: prompt = String(localized: "Hold the key that moves by word, then press any letter", comment: "Spoken message: waiting for a key")
        }
        TurnOverMenu.captureKey(prompt: prompt) { g in
            let bits = UInt(g.flags.rawValue) & ReviewLayerLogic.Device.all
            guard bits != 0 else {
                Speech.speakMessage(String(localized: "No modifier key was held; nothing changed", comment: "Spoken message"))
                return
            }
            var c = chord
            switch which {
            case .hold: c.hold = bits
            case .reverse: c.reverse = bits
            case .word: c.word = bits
            }
            guard c.hold & (c.reverse | c.word) == 0 else {
                Speech.speakMessage(String(localized: "Those keys are already part of the other chord; nothing changed", comment: "Spoken message"))
                return
            }
            setChord(c)
            Speech.speakMessage(String(localized: "saved", comment: "Spoken message"))
        }
    }

    static func setChord(_ c: ReviewLayerLogic.Chord) {
        chord = c
        let d = UserDefaults.standard
        d.set(NSNumber(value: c.hold), forKey: holdKey)
        d.set(NSNumber(value: c.reverse), forKey: reverseKey)
        d.set(NSNumber(value: c.word), forKey: wordKey)
        PointerPlace.refresh()
        Log.io("review layer: chord hold \(c.hold) reverse \(c.reverse) word \(c.word)")
    }

    static func resetChord() {
        setChord(.standard)
        Speech.speakMessage(String(localized: "review layer keys back to Left Option and Right Shift", comment: "Spoken message"))
    }

    // MARK: Running a key

    static func run(_ g: KeyboardGesture) {
        guard let decision = decision(for: g) else { return }
        let wasArmed = armed
        if wasArmed { armed = false }
        lastUsed = Date()
        switch decision {
        case .off:
            end(speaking: true)
        case .select(let id):
            // Shift and the arrow as the field would have them without the chord.
            KeyboardGesture(identifier: id)?.send()
        case .activate:
            activateHere()
        case .review(let id):
            review(id)
        }
    }

    private static func review(_ id: String) {
        guard let base = KeyboardGesture(identifier: id) else { return }
        // The user's own keys first, as everywhere (a key taken away is not the layer's either).
        switch UserGestures.lookup(base) {
        case .script(let s)?: s.handler(base); return
        case .removed?: return
        case nil: break
        }
        // Tab moves the review cursor to the next link or control; the real focus stays where it is.
        if id.hasSuffix("tab") {
            guard let doc = document() else { Tones.edge(); return }
            doc.reviewTab(forward: id == "kb:tab")
            return
        }
        guard let doc = document() else { fallback(id); return }
        guard let script = doc.layerScript(for: base), ReviewLayerLogic.isAllowed(script: script.name) else {
            Log.io("review layer: \(id) has no review command")
            return
        }
        let saved = doc.singleLetterNavigation
        doc.singleLetterNavigation = true   // a script with the letters off would send the key on, into the field
        defer { doc.singleLetterNavigation = saved }
        script.handler(base)
    }

    /// Enter: press what the review cursor is on, through accessibility, never as a key sent on to the field.
    private static func activateHere() {
        guard let doc = document(), let e = doc.elementAtPosition(), doc.press(nearestTo: e) else {
            Tones.edge()
            return
        }
    }

    /// No reading document (a native control with nothing to read): the object review, Up and Down by item, Left and
    /// Right by word; the other keys have nothing to do here.
    private static func fallback(_ id: String) {
        switch id {
        case "kb:upArrow": ReadWhileTyping.moveItem(forward: false)
        case "kb:downArrow": ReadWhileTyping.moveItem(forward: true)
        case "kb:leftArrow", "kb:option+leftArrow": ReadWhileTyping.moveSide(forward: false)
        case "kb:rightArrow", "kb:option+rightArrow": ReadWhileTyping.moveSide(forward: true)
        default: Tones.edge()
        }
    }

    /// The reading position to an element (the pointer's: a click that only places the cursor), so the layer's keys
    /// read on from there. Nothing happens where the element is not in the document being read.
    static func place(_ e: AXUIElement, at point: CGPoint) {
        guard enabled, let doc = document() else { return }
        var candidate: AXUIElement? = e
        var hops = 0
        while let c = candidate, hops < 4 {
            if var at = doc.buffer.offset(of: c) {
                if hops == 0, let inside = characterOffset(in: doc, of: c, segmentStart: at, point: point) { at = inside }
                doc.position = at
                placedAt = Date()
                lastUsed = Date()
                Log.io("review layer: position placed by the pointer on \(c.role) (offset \(at))")
                return
            }
            candidate = c.element(kAXParentAttribute)
            hops += 1
        }
        Log.io("review layer: the pointer's item (\(e.role)) is not in the document being read")
    }

    /// In a text area, the character under the pointer, only when the document's text there is the field's own text.
    private static func characterOffset(in doc: BrowseModeDocument, of e: AXUIElement, segmentStart: Int, point: CGPoint) -> Int? {
        guard let value = e.string(kAXValueAttribute) as NSString?, value.length > 0 else { return nil }
        var pt = point
        guard let v = AXValueCreate(.cgPoint, &pt), let r = e.param("AXRangeForPosition", v),
              let range = cfRange(r), range.location >= 0, range.location < value.length else { return nil }
        let text = doc.buffer.text
        let n = min(12, value.length - range.location)
        let candidate = segmentStart + range.location
        guard n > 0, candidate + n <= text.length,
              text.substring(with: NSRange(location: candidate, length: n)) == value.substring(with: NSRange(location: range.location, length: n)) else { return nil }
        return candidate
    }

    /// The element's place in the document, or its nearest parent's (a focused cell inside a row the reader has as one item).
    private static func offsetNear(_ e: AXUIElement, in doc: BrowseModeDocument) -> Int? {
        var candidate: AXUIElement? = e
        var hops = 0
        while let c = candidate, hops < 4 {
            if let at = doc.buffer.offset(of: c) { return at }
            candidate = c.element(kAXParentAttribute)
            hops += 1
        }
        return nil
    }

    // MARK: The document it reads

    /// The page's reading document (a chat in a browser), or one over the focused window (a native app), made once.
    static func document() -> BrowseModeDocument? {
        let doc: BrowseModeDocument
        if let d = API.focusTreeInterceptor, d.isAlive, !d.buffer.lines.isEmpty {
            doc = d
        } else {
            guard let focus = API.focusObject else { return nil }
            let window = focus.element.element(kAXWindowAttribute)
                ?? AXUIElementCreateApplication(focus.pid).element(kAXFocusedWindowAttribute)
            guard let window else { return nil }
            let d = BrowseModeHandler.shared.document(root: window)
            guard d.isAlive else { return nil }
            let id = ObjectIdentifier(d)
            // A window changes under the reader and tells the copy nothing: read it again when the layer starts
            // to be used after a pause, keeping the place.
            if !windowDocuments.contains(id) { windowDocuments.insert(id) }
            else if Date().timeIntervalSince(lastUsed) > 4, Date().timeIntervalSince(d.buffer.builtAt) > 4 {
                let t0 = Date()
                d.rebuildKeepingPlace()
                Log.io("review layer: window read again in \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(d.buffer.lines.count) lines")
            }
            doc = d
        }
        guard !doc.buffer.lines.isEmpty else { return nil }
        // A new field: reading starts there. Within the same field the cursor stays where it was left.
        if let focus = API.focusObject {
            let sameDoc = syncedDocument == ObjectIdentifier(doc)
            // A focus that moved just after the cursor was put somewhere on purpose (a click placing it) follows it.
            let justPlaced = Date().timeIntervalSince(placedAt) < 2
            let isField = ["AXTextField", "AXTextArea", "AXComboBox"].contains(focus.element.role)
            if !sameDoc || (syncedFocus.map({ !CFEqual($0, focus.element) }) ?? true) && !justPlaced {
                syncedDocument = ObjectIdentifier(doc); syncedFocus = focus.element
                messageStart = nil
                if let at = offsetNear(focus.element, in: doc) {
                    doc.position = at
                    // From a field (a chat's message box) the layer starts at the latest message, not at the field.
                    if isField, let start = doc.lastMessageStart(before: at) {
                        doc.position = start
                        messageStart = start
                    }
                } else if Date().timeIntervalSince(doc.buffer.builtAt) > 1 {
                    // The focus is somewhere the copy of the window has not seen (a part that appeared, a new row).
                    doc.rebuildKeepingPlace(anchor: focus.element)
                    if let at = offsetNear(focus.element, in: doc) { doc.position = at }
                    else { Log.io("review layer: the focus (\(focus.element.role)) is not in the document being read") }
                }
            } else if let seen = messageStart, isField, let at = offsetNear(focus.element, in: doc),
                      let start = doc.lastMessageStart(before: at), start > seen {
                // A new message has arrived (or been sent): the review moves to it. Typing alone does not move it.
                messageStart = start
                doc.position = start
                Speech.speakMessage(String(localized: "new message", comment: "Spoken message: the review layer moved to a message that has just arrived"))
            }
        }
        return doc
    }
}

/// The layer's commands, in the key list under Waypoint. The layer's keys themselves are the document's, found by the
/// chord.
final class ReviewLayerPlugin: GlobalPlugin {
    private var layerKey: Script!

    required init() {
        super.init()
        let category = "Waypoint"
        layerKey = Script(name: "reviewLayerKey", description: String(localized: "A key of the review layer: reads around while the keyboard stays in the field", comment: "A command, as the key list and keyboard help say it"), category: category, owner: self) { g in
            ReviewLayer.run(g)
        }
        script("reviewLayerArm", String(localized: "Review layer: once, the next key reads around the field instead of typing; twice, the layer stays on until pressed again", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+r"], category: category) { _ in
            ReviewLayer.armCommand()
        }
        script("reviewLayerEnable", String(localized: "Turns the review layer (hold Left Option and Right Shift to read around a text field) on or off", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            ReviewLayer.toggleEnabled()
        }
        script("reviewLayerSetHold", String(localized: "Chooses the keys held to switch the review layer on (now Left Option and Right Shift)", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            ReviewLayer.capture(.hold)
        }
        script("reviewLayerSetReverse", String(localized: "Chooses the key that reverses a review layer key and selects with the arrows (now Left Shift)", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            ReviewLayer.capture(.reverse)
        }
        script("reviewLayerSetWord", String(localized: "Chooses the key that moves the review layer by word with the arrows (now Right Option)", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            ReviewLayer.capture(.word)
        }
        script("reviewLayerResetKeys", String(localized: "Puts the review layer's keys back to Left Option, Right Shift, Left Shift and Right Option", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            ReviewLayer.resetChord()
        }
    }

    public override func script(for gesture: KeyboardGesture) -> Script? {
        if let own = super.script(for: gesture) { return own }
        return ReviewLayer.decision(for: gesture) == nil ? nil : layerKey
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        ReviewLayer.handle(event)
        next()
    }

    override func terminate() { ReviewLayer.reset() }
}
