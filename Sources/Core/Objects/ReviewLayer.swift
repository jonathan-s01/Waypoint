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
        /// Right Option and a digit with the chord held: the second reader to that area (0 is the global one).
        case area(Int)
    }

    static let arrows: Set<String> = ["leftArrow", "rightArrow", "upArrow", "downArrow"]
    static let positionKeys: Set<String> = ["home", "end", "pageUp", "pageDown"]

    /// What a key means to the layer, nil when it is not the layer's (it goes to the application as it is).
    /// `armed`: the layer is armed or latched, so the plain keys count and the ordinary Shift and Option are the
    /// reverse and word keys. `flags` are the event's raw flags.
    public static func decide(flags: UInt, keyName: String, chord: Chord, armed: Bool, turnOverKey: Bool) -> Decision? {
        guard !turnOverKey else { return nil }
        // Right Option is a command key, not the layer's: a digit with it and the chord is an area jump, whatever
        // the "word" key has been set to.
        if !armed, let n = Int(keyName), keyName.count == 1 {
            let held = flags & Device.all
            if chord.hold != 0, chord.hold & Device.rightOption == 0, held & chord.hold == chord.hold, held & Device.rightOption != 0,
               held & ~(chord.hold | chord.reverse | chord.word | Device.rightOption) == 0, held & chord.reverse == 0 { return .area(n) }
        }
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

    /// Whether a command key (Waypoint's own commands, such as the areas and the tools) is meant for the second reader.
    /// Left Option and Right Option do not share a meaning: Left Option is the keyboard's (and half of the layer's chord),
    /// Right Option is the command key. Right Option with the TurnOver key, Left Option not held, or with the chord held,
    /// is the second reader; Left Option with the TurnOver key, and Right Option alone, are the keyboard's.
    public static func isSecond(flags: UInt, chord: Chord, turnOverKey: Bool) -> Bool {
        let held = flags & Device.all
        guard held & Device.rightOption != 0 else { return false }
        if turnOverKey { return held & Device.leftOption == 0 }
        return chord.hold != 0 && chord.hold & Device.rightOption == 0 && held & chord.hold == chord.hold
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
    /// The second reader's own copies of the pages the keyboard reads in browse mode, so the two keep separate places
    /// and modes: neither is in the browse handler's list (which is the keyboard's), and a copy's place is not
    /// remembered as the page's. A copy hears nothing of the page changing; it is read again when the layer returns
    /// after a pause, as the window documents are.
    private static var copies: [BrowseModeDocument] = []
    /// The document the second reader was put in on purpose (an area jump): it stays there, whatever the keyboard does and
    /// whichever app is in front, until the reset key. Without one it follows the focus, as it always did.
    private static var pinned: BrowseModeDocument?

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

    /// Whether a command key was pressed for the second reader (see ReviewLayerLogic.isSecond).
    static func isSecond(_ g: KeyboardGesture) -> Bool {
        enabled && ReviewLayerLogic.isSecond(flags: UInt(g.flags.rawValue), chord: chord, turnOverKey: g.modifiers.contains(.turnover))
    }

    /// The reset key: the second reader goes back to following the keyboard.
    static func unpin() {
        pinned = nil; syncedFocus = nil; syncedDocument = nil; messageStart = nil
        Speech.speakMessage(String(localized: "second reader back with the keyboard", comment: "Spoken message: the review layer follows the keyboard's focus again"))
    }

    /// The window the second reader is reading, for the area commands: the pinned one, or the one the keyboard is in.
    static func windowAndPid() -> (window: AXUIElement, pid: pid_t)? {
        guard let doc = document() else { return nil }
        let root = doc.webArea
        guard let window = root.role == "AXWindow" ? root : root.element(kAXWindowAttribute) else { return nil }
        return (window, root.pid)
    }

    /// The element under the second reader's cursor, for "the area you are in".
    static func cursorElement() -> AXUIElement? { document()?.elementAtPosition() }

    /// The second reader to an element, on purpose: it keeps the place and says what is there. The keyboard's focus
    /// does not move. `area`: in a chat, to the newest message inside that frame rather than its top.
    @discardableResult
    static func jump(to e: AXUIElement, area: CGRect? = nil) -> Bool {
        guard let doc = document() else { Tones.edge(); return false }
        var at = doc.buffer.offset(of: e)
        if at == nil {
            doc.rebuildKeepingPlace(anchor: e)
            at = doc.buffer.offset(of: e)
        }
        guard var offset = at else {
            Speech.speakMessage(String(localized: "that part is not in what the second reader can read", comment: "Spoken message: the review layer cannot go to the part"))
            return false
        }
        doc.position = offset
        if let area, doc.buffer.text.length > 0, let m = doc.lastMessageStart(before: doc.buffer.text.length - 1), m > offset {
            doc.position = m
            if let at = doc.elementAtPosition(), let f = TurnOverObject.frame(at), area.contains(CGPoint(x: f.midX, y: f.midY)) { offset = m }
            else { doc.position = offset }
        }
        pinned = doc
        placedAt = Date(); lastUsed = Date()
        doc.speakQuickNavText(at: offset, link: false)
        return true
    }

    static func reset() { pinned = nil; for c in copies { c.cancelBuffer() }; copies = []; armed = false; latched = false; syncedFocus = nil; messageStart = nil; syncedDocument = nil; windowDocuments = [] }

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
            guard which != .hold || bits & ReviewLayerLogic.Device.rightOption == 0 else {
                Speech.speakMessage(String(localized: "Right Option is the command key for the second reader; choose other keys to hold", comment: "Spoken message"))
                return
            }
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

    static let resetScript = "reviewLayerReset"
    static let resetDefaultKey = "kb:turnover+option+command+shift+/"

    /// Takes the next key as the one that puts the second reader back with the keyboard, and takes the old one away:
    /// the standard one is TurnOver's own and stays unless it is given up here.
    static func captureResetKey() {
        TurnOverMenu.captureKey(prompt: String(localized: "Press the key that puts the second reader back with the keyboard", comment: "Spoken message: waiting for a key")) { g in
            if UserGestures.isProtected(g) {
                Speech.speakMessage(String(localized: "\(g.displayName) is one of TurnOver's essential keys and can't be changed", comment: "Spoken message: %@ is the command"))
                return
            }
            clearResetKey()
            UserGestures.set(g, to: .script(resetScript))
            let id = UserGestures.storedIdentifier(of: g)
            if id != UserGestures.normal(resetDefaultKey) {
                config.keyboard.userGestures[UserGestures.normal(resetDefaultKey)] = UserGestures.Target.removed.stored
                config.save()
            }
            Speech.speakMessage(String(localized: "\(UserGestures.spoken(id)) now puts the second reader back with the keyboard", comment: "Spoken message: %@ is the key"))
        }
    }

    /// Back to the standard reset key: any key chosen for it, and any removal of the standard one, go.
    private static func clearResetKey() {
        for (id, target) in config.keyboard.userGestures where target == "script:" + resetScript { config.keyboard.userGestures[id] = nil }
        if config.keyboard.userGestures[UserGestures.normal(resetDefaultKey)] == UserGestures.Target.removed.stored { config.keyboard.userGestures[UserGestures.normal(resetDefaultKey)] = nil }
        config.save()
    }

    static func resetChord() {
        setChord(.standard)
        clearResetKey()
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
        case .area(let n):
            AreaMenu.command(number: n, second: true)
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
        // Tab is the keyboard's Tab for the second reader: the next part of the window in an app with a panes recipe,
        // else the next link or control; the real focus stays where it is.
        if id.hasSuffix("tab") {
            if let pid = windowAndPid()?.pid ?? API.focusPid, let view = PanesView.current(pid: pid) {
                view.stepSecond(forward: id == "kb:tab")
                return
            }
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

    /// Where an element (or the nearest parent the document has) is in the document, the character under `point` when
    /// it is a text area's own text.
    static func offset(of e: AXUIElement, at point: CGPoint, in doc: BrowseModeDocument) -> Int? {
        var candidate: AXUIElement? = e
        var hops = 0
        while let c = candidate, hops < 4 {
            if var at = doc.buffer.offset(of: c) {
                if hops == 0, let inside = characterOffset(in: doc, of: c, segmentStart: at, point: point) { at = inside }
                return at
            }
            candidate = c.element(kAXParentAttribute)
            hops += 1
        }
        return nil
    }

    /// The second reader to an element under the pointer (a click that only places the cursor): it keeps the place,
    /// says what is there, and the keyboard's focus does not move. `pin: false` (VO-Shift-F5) only sets the position.
    /// A place the pinned document has not got is looked for in the document of the keyboard's window, then by reading
    /// the window again.
    static func place(_ e: AXUIElement, at point: CGPoint, pin: Bool = true) {
        guard enabled else { return }
        var doc = document()
        var at = doc.flatMap { offset(of: e, at: point, in: $0) }
        if at == nil, pinned != nil {
            pinned = nil
            doc = document()
            at = doc.flatMap { offset(of: e, at: point, in: $0) }
        }
        if at == nil, let d = doc {
            d.rebuildKeepingPlace(anchor: e)
            at = offset(of: e, at: point, in: d)
        }
        guard let doc, let at else {
            Log.io("review layer: the pointer's item (\(e.role)) is not in the document being read")
            if pin { Speech.speakMessage(String(localized: "that part is not in what the second reader can read", comment: "Spoken message: the review layer cannot go to the part")) }
            return
        }
        doc.position = at
        placedAt = Date()
        lastUsed = Date()
        Log.io("review layer: position placed by the pointer on \(e.role) (offset \(at))")
        guard pin else { return }
        pinned = doc
        doc.speakQuickNavText(at: at, link: false)
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

    /// The second reader's own document over the page the keyboard reads in browse mode, made once per page.
    @discardableResult
    static func ownCopy(of d: BrowseModeDocument) -> BrowseModeDocument {
        copies.removeAll { !$0.isAlive }
        if let c = copies.first(where: { $0.webArea.isSame(d.webArea) }) { return c }
        let c = BrowseModeDocument(webArea: d.webArea)
        c.remembersPlace = false
        copies.append(c)
        if copies.count > 6 { let old = copies.removeFirst(); old.cancelBuffer(); windowDocuments.remove(ObjectIdentifier(old)) }
        windowDocuments.insert(ObjectIdentifier(c))
        Log.io("review layer: its own copy of the page in pid \(d.webArea.pid)")
        return c
    }

    /// Reading the page ahead for the second reader, once the keyboard has settled in it, so its first key finds it read.
    static func prepare(for d: BrowseModeDocument) {
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard enabled, API.focusTreeInterceptor === d, d.isAlive else { return }
            ownCopy(of: d)
        }
    }

    /// The page's reading document (a chat in a browser), or one over the focused window (a native app), made once.
    static func document() -> BrowseModeDocument? {
        if let p = pinned {
            if p.isAlive, !p.buffer.lines.isEmpty {
                if windowDocuments.contains(ObjectIdentifier(p)), Date().timeIntervalSince(lastUsed) > 4, Date().timeIntervalSince(p.buffer.builtAt) > 4 { p.rebuildKeepingPlace() }
                return p
            }
            pinned = nil
        }
        let doc: BrowseModeDocument
        if let page = API.focusTreeInterceptor, page.isAlive {
            let d = ownCopy(of: page)
            if d.buffer.lines.isEmpty {
                if d.buffer.isLoading { Speech.speakMessage(String(localized: "second reader loading", comment: "Spoken message: the review layer is still reading the page")) }
                return nil
            }
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
        script(ReviewLayer.resetScript, String(localized: "Puts the second reader back with the keyboard: it follows the focus again, in this app and window (it stays where an area jump put it until then)", comment: "A command, as the key list and keyboard help say it"),
               gestures: [ReviewLayer.resetDefaultKey], category: category) { _ in
            ReviewLayer.unpin()
        }
        script("reviewLayerSetResetKey", String(localized: "Chooses the key that puts the second reader back with the keyboard (now Caps Lock, Option, Command, Shift and slash)", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            ReviewLayer.captureResetKey()
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
