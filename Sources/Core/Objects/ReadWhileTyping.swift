import AppKit
import ApplicationServices

// Read while typing (plan 4.7). In a compose box, one command switches the plain arrow keys to TurnOver's review
// cursor, so the messages around the field can be read (Up and Down by message, Left and Right by word) while the
// keyboard focus never leaves the field and typing carries on as before. The same command switches them back.
//
// Safety first: the arrows are claimed only while the mode is on and the keyboard is still in the same text field of the
// same app; anything else (a focus change, a menu, another app, five quiet minutes) switches the mode off and says so.
// It is never on at start, and the whole feature is off until switched on with the "read while typing enable" command.

/// The decisions, pure: which keys are claimed in which state, and when the mode must end.
nonisolated public enum ReadWhileTypingLogic {

    public enum Move: Hashable, Sendable {
        case previousItem, nextItem, previousPart, nextPart
    }

    /// Plain Up, Down, Left and Right only: with any modifier (selecting with Shift, moving by word with Option,
    /// Command-arrows) the key still belongs to the field. Home and End are not taken: they are caret keys in a field.
    public static func move(forKey keyName: String, modifiers: Modifiers) -> Move? {
        guard modifiers.isEmpty else { return nil }
        switch keyName {
        case "upArrow": return .previousItem
        case "downArrow": return .nextItem
        case "leftArrow": return .previousPart
        case "rightArrow": return .nextPart
        default: return nil
        }
    }

    /// A field typed into, as a compose box is: not a password, not read only, not a terminal or a document.
    public static func isTextInput(axRole: String, subrole: String?, readOnly: Bool) -> Bool {
        guard axRole == "AXTextField" || axRole == "AXTextArea" else { return false }
        if subrole == "AXSecureTextField" { return false }
        return !readOnly
    }

    /// How long the mode stays on with no arrow and no typing before it ends by itself.
    public static let idleLimit: TimeInterval = 300

    /// What is true now, gathered by the caller.
    public struct Situation: Equatable, Sendable {
        public var settingEnabled: Bool
        public var isOn: Bool
        public var focusIsTextInput: Bool
        public var sameField: Bool
        public var sameApp: Bool
        public var menuOpen: Bool
        public var idleSeconds: TimeInterval
        public init(settingEnabled: Bool, isOn: Bool, focusIsTextInput: Bool, sameField: Bool, sameApp: Bool, menuOpen: Bool, idleSeconds: TimeInterval) {
            self.settingEnabled = settingEnabled; self.isOn = isOn; self.focusIsTextInput = focusIsTextInput
            self.sameField = sameField; self.sameApp = sameApp; self.menuOpen = menuOpen; self.idleSeconds = idleSeconds
        }
    }

    public enum OffReason: Equatable, Sendable {
        case settingOff, menuOpen, otherApp, leftField, notTextInput, idle
    }

    /// Why the mode must end now; nil while it may go on (and nil when it is not on).
    public static func offReason(_ s: Situation) -> OffReason? {
        guard s.isOn else { return nil }
        if !s.settingEnabled { return .settingOff }
        if s.menuOpen { return .menuOpen }
        if !s.sameApp { return .otherApp }
        if !s.sameField { return .leftField }
        if !s.focusIsTextInput { return .notTextInput }
        if s.idleSeconds > idleLimit { return .idle }
        return nil
    }

    /// The move a key makes: nil (the key goes to the field) unless the mode is on, valid, and the key is a plain arrow.
    public static func claim(keyName: String, modifiers: Modifiers, in s: Situation) -> Move? {
        guard s.isOn, offReason(s) == nil else { return nil }
        return move(forKey: keyName, modifiers: modifiers)
    }

    /// The next or previous word or character of an item's text, from the one last read (nil: from the start going
    /// forward, from the end going back). nil at the edge.
    public static func step(in text: String, from current: NSRange?, forward: Bool, byWord: Bool) -> NSRange? {
        let s = text as NSString
        let length = s.length
        guard length > 0 else { return nil }
        var boundary = forward ? 0 : length
        if let c = current, c.location >= 0, c.length >= 0, c.location + c.length <= length {
            boundary = forward ? c.location + c.length : c.location
        }
        if byWord {
            var found: NSRange?
            if forward {
                guard boundary < length else { return nil }
                s.enumerateSubstrings(in: NSRange(location: boundary, length: length - boundary), options: [.byWords, .substringNotRequired]) { _, range, _, stop in
                    found = range; stop.pointee = true
                }
            } else {
                guard boundary > 0 else { return nil }
                s.enumerateSubstrings(in: NSRange(location: 0, length: boundary), options: [.byWords, .reverse, .substringNotRequired]) { _, range, _, stop in
                    found = range; stop.pointee = true
                }
            }
            return found
        }
        if forward { return boundary < length ? s.rangeOfComposedCharacterSequence(at: boundary) : nil }
        return boundary > 0 ? s.rangeOfComposedCharacterSequence(at: boundary - 1) : nil
    }

    /// The most that is put into a field in one go.
    public static let insertLimit = 20_000

    /// Text for the field: no blank edges, and never a final new line (in a chat that would send it). Quoted, each
    /// line starts with "> ". Empty when there is nothing to put.
    public static func insertable(_ text: String, quoted: Bool) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > insertLimit { t = String(t.prefix(insertLimit)) }
        guard !t.isEmpty else { return "" }
        guard quoted else { return t }
        let lines = t.components(separatedBy: .newlines)
        return lines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }
}

/// The mode itself: on or off, and what it does to a key.
@MainActor
enum ReadWhileTyping {
    static let settingKey = "waypoint.readWhileTyping"
    /// "word" (the default) or "character": what Left and Right step by.
    static let sideUnitKey = "waypoint.readWhileTyping.sideUnit"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }
    private static var sidesByCharacter: Bool { UserDefaults.standard.string(forKey: sideUnitKey) == "character" }

    private(set) static var isOn = false
    private static var field: AXUIElement?
    private static var fieldPid: pid_t = 0
    private static var lastUsed = Date.distantPast
    // Where Left and Right are in the item the review cursor is on (object review only).
    private static var sideItem: AXUIElement?
    private static var sideRange: NSRange?

    // MARK: State

    private static func isTextInput(_ o: TurnOverObject) -> Bool {
        ReadWhileTypingLogic.isTextInput(axRole: o.axRole, subrole: o.axSubrole, readOnly: o.states.contains(.readOnly)) && !Speech.typingIntoSecretField
    }

    private static func situation() -> ReadWhileTypingLogic.Situation {
        let focus = API.focusObject
        let sameField: Bool
        if let f = field, let focus { sameField = CFEqual(f, focus.element) } else { sameField = false }
        return ReadWhileTypingLogic.Situation(
            settingEnabled: enabled,
            isOn: isOn,
            focusIsTextInput: focus.map(isTextInput) ?? false,
            sameField: sameField,
            sameApp: NSWorkspace.shared.frontmostApplication?.processIdentifier == fieldPid,
            menuOpen: AXHandler.shared.isMenuOpen,
            idleSeconds: Date().timeIntervalSince(lastUsed))
    }

    /// Whether the mode may go on; if not, it ends here and says so, so the key that follows goes to the field.
    static func stillValid() -> Bool {
        guard isOn else { return false }
        if let why = ReadWhileTypingLogic.offReason(situation()) {
            Log.io("read while typing: off (\(why))")
            turnOff()
            return false
        }
        return true
    }

    static func handle(_ event: Event) {
        guard isOn else { return }
        switch event.kind {
        case .typedCharacter:
            lastUsed = Date()
        case .gainFocus:
            if let f = field, !event.obj.isSameElement(as: f) { Log.io("read while typing: off (the focus moved)"); turnOff() }
        case .foreground, .menuStart, .appModuleLoseFocus:
            Log.io("read while typing: off (\(event.kind.rawValue))")
            turnOff()
        default:
            break
        }
    }

    /// Ends the mode without a word or a sound (the plugin closing).
    static func reset() {
        isOn = false; field = nil; sideItem = nil; sideRange = nil
    }

    // MARK: On and off

    static func toggle() {
        guard enabled else {
            Speech.speakMessage(String(localized: "read while typing is off; turn it on with the read while typing enable command in the key list", comment: "Spoken message"))
            return
        }
        if isOn { turnOff() } else { turnOn() }
    }

    static func toggleEnabled() {
        enabled.toggle()
        if !enabled, isOn { turnOff(speaking: false) }
        Speech.speakMessage(enabled ? String(localized: "read while typing enabled", comment: "Spoken message") : String(localized: "read while typing disabled", comment: "Spoken message"))
    }

    private static func turnOn() {
        guard let focus = API.focusObject, isTextInput(focus) else {
            Speech.speakMessage(String(localized: "read while typing works in a text field", comment: "Spoken message"))
            return
        }
        field = focus.element
        fieldPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        lastUsed = Date()
        sideItem = nil; sideRange = nil
        isOn = true
        // Reading starts at the field: Up goes to what is above it.
        ObjectNavigator.shared.place(focus.element)
        if let d = document(), let at = d.buffer.offset(of: focus.element) { d.position = at }
        tone(on: true)
        Speech.speakMessage(String(localized: "review on", comment: "Spoken message"))
    }

    private static func turnOff(speaking: Bool = true) {
        guard isOn else { return }
        // Back to the field, if the keyboard is still in it (a moved focus resets the cursor by itself).
        if let f = field, let focus = API.focusObject, CFEqual(f, focus.element) { ObjectNavigator.shared.place(f) }
        reset()
        guard speaking else { return }
        tone(on: false)
        Speech.speakMessage(String(localized: "review off", comment: "Spoken message"))
    }

    private static func tone(on: Bool) {
        let (first, second) = on ? (880.0, 1320.0) : (1320.0, 880.0)
        Tones.beep(first, 35, volume: 0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { Tones.beep(second, 45, volume: 0.18) }
    }

    // MARK: Moving

    /// The page's reading document, for a web app (a chat in a browser): its lines are the messages.
    private static func document() -> BrowseModeDocument? {
        guard let d = API.focusTreeInterceptor, d.isAlive, !d.buffer.lines.isEmpty else { return nil }
        return d
    }

    /// Up and Down.
    static func moveItem(forward: Bool) {
        lastUsed = Date()
        sideItem = nil; sideRange = nil
        if let d = document() { d.move(.line, forward ? 1 : -1); return }
        // The review cursor would put the keyboard on the control it lands on, as VoiceOver's does; here the keyboard
        // stays in the field, whatever the setting.
        let saved = config.general.focusFollowsCursor
        config.general.focusFollowsCursor = "off"
        defer { config.general.focusFollowsCursor = saved }
        if forward { ObjectNavigator.shared.next() } else { ObjectNavigator.shared.previous() }
    }

    /// Left and Right: by word (or character, with the setting) through the item the cursor is on.
    static func moveSide(forward: Bool) {
        lastUsed = Date()
        let byWord = !sidesByCharacter
        if let d = document() { d.move(byWord ? .word : .character, forward ? 1 : -1); return }
        guard let item = ObjectNavigator.shared.reviewElement, !isField(item) else { Tones.edge(); return }
        if let known = sideItem, CFEqual(known, item) {} else { sideItem = item; sideRange = nil }
        let text = ObjectNavigator.words(item)
        guard let range = ReadWhileTypingLogic.step(in: text, from: sideRange, forward: forward, byWord: byWord) else { Tones.edge(); return }
        sideRange = range
        let piece = (text as NSString).substring(with: range)
        if byWord { Speech.speakText(piece); return }
        if piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Speech.speakText(piece.contains(where: \.isNewline) ? String(localized: "new line", comment: "Spoken message") : String(localized: "space", comment: "Spoken message"))
        } else {
            Speech.speakText(piece, symbolLevel: .all)
        }
    }

    private static func isField(_ e: AXUIElement) -> Bool {
        guard let f = field else { return false }
        return CFEqual(f, e)
    }

    // MARK: What was reviewed

    private static func reviewedText() -> String? {
        let text: String
        if let d = document() {
            guard let info = d.caretInfo() else { return nil }
            info.expand(.line)
            text = info.text
        } else {
            guard let item = ObjectNavigator.shared.reviewElement, !isField(item) else { return nil }
            text = ObjectNavigator.words(item)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static func requireOn() -> Bool {
        guard isOn, stillValid() else {
            if !isOn { Speech.speakMessage(String(localized: "review is off", comment: "Spoken message")) }
            return false
        }
        lastUsed = Date()
        return true
    }

    static func speakHere() {
        guard requireOn() else { return }
        if let d = document() { d.speakUnit(.line) } else { ObjectNavigator.shared.reportCurrent() }
    }

    static func copyHere() {
        guard requireOn() else { return }
        guard let text = reviewedText() else { Speech.speakMessage(String(localized: "nothing to copy", comment: "Spoken message")); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Speech.speakMessage(String(localized: "copied", comment: "Spoken message"), remember: false)
    }

    static func insertHere(quoted: Bool) {
        guard requireOn() else { return }
        guard let text = reviewedText() else { Speech.speakMessage(String(localized: "nothing to put in", comment: "Spoken message")); return }
        let words = ReadWhileTypingLogic.insertable(text, quoted: quoted)
        guard !words.isEmpty else { return }
        let board = NSPasteboard.general
        // Not over a password a manager has put there (marked concealed or transient): putting it back would undo
        // the manager's clearing of it.
        let marked: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        if (board.types ?? []).contains(where: { marked.contains($0.rawValue) }) {
            Speech.speakMessage(String(localized: "not put in; the clipboard holds a concealed item", comment: "Spoken message"))
            return
        }
        // The keys that ran this command may still be down: the paste is sent a moment later, to the field the
        // keyboard is still in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard isOn, let f = field, let focus = API.focusObject, CFEqual(f, focus.element) else { return }
            let saved = board.pasteboardItems?.map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } } ?? []
            board.clearContents()
            // Marked transient, so clipboard history apps leave it out.
            board.setString(words, forType: .string)
            board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
            let ours = board.changeCount
            KeyboardGesture(identifier: "kb:command+v")?.send()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Put back only if nothing else has been copied since (a slow app's paste reads it by then).
                guard board.changeCount == ours else { return }
                board.clearContents()
                let items = saved.map { pairs -> NSPasteboardItem in let i = NSPasteboardItem(); for (t, d) in pairs { i.setData(d, forType: t) }; return i }
                if !items.isEmpty { board.writeObjects(items) }
            }
            Speech.speakMessage(quoted ? String(localized: "quoted", comment: "Spoken message") : String(localized: "put in", comment: "Spoken message"), remember: false)
        }
    }
}

/// The commands, in the key list under Waypoint. The arrows themselves are not commands: they are claimed one by one,
/// and only while the mode is on.
final class ReadWhileTypingPlugin: GlobalPlugin {
    private var moves: [ReadWhileTypingLogic.Move: Script] = [:]

    required init() {
        super.init()
        let category = "Waypoint"
        script("readWhileTypingEnable", String(localized: "Turns the read while typing feature on or off", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            ReadWhileTyping.toggleEnabled()
        }
        script("readWhileTyping", String(localized: "In a text field, switches the arrow keys to reading the messages and items around it, and back", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+r"], category: category) { _ in
            ReadWhileTyping.toggle()
        }
        script("readWhileTypingSpeak", String(localized: "While reading around a text field, says where the review cursor is", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+s"], category: category) { _ in
            ReadWhileTyping.speakHere()
        }
        script("readWhileTypingQuote", String(localized: "While reading around a text field, puts the reviewed text into the field as a quote", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+q"], category: category) { _ in
            ReadWhileTyping.insertHere(quoted: true)
        }
        script("readWhileTypingInsert", String(localized: "While reading around a text field, puts the reviewed text into the field as it is", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+i"], category: category) { _ in
            ReadWhileTyping.insertHere(quoted: false)
        }
        script("readWhileTypingCopy", String(localized: "While reading around a text field, copies the reviewed text", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+y"], category: category) { _ in
            ReadWhileTyping.copyHere()
        }

        let moveDescription = String(localized: "An arrow key, while reading around a text field", comment: "A command, as the key list and keyboard help say it")
        func make(_ move: ReadWhileTypingLogic.Move, _ run: @escaping () -> Void) {
            moves[move] = Script(name: "readWhileTypingMove", description: moveDescription, category: category, owner: self) { _ in run() }
        }
        make(.previousItem) { ReadWhileTyping.moveItem(forward: false) }
        make(.nextItem) { ReadWhileTyping.moveItem(forward: true) }
        make(.previousPart) { ReadWhileTyping.moveSide(forward: false) }
        make(.nextPart) { ReadWhileTyping.moveSide(forward: true) }
    }

    public override func script(for gesture: KeyboardGesture) -> Script? {
        if let own = super.script(for: gesture) { return own }
        // Cheapest tests first: nothing here costs anything while the mode is off.
        guard ReadWhileTyping.isOn, let move = ReadWhileTypingLogic.move(forKey: gesture.keyName, modifiers: gesture.modifiers) else { return nil }
        guard ReadWhileTyping.stillValid() else { return nil }
        return moves[move]
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        ReadWhileTyping.handle(event)
        next()
    }

    override func terminate() {
        ReadWhileTyping.reset()
    }
}
