import AppKit
import ApplicationServices

// Reading around a text field (plan 4.7): the helpers the review layer (ReviewLayer.swift) uses, and the commands that
// act on what it has reviewed: say it, copy it, put it into the field (as it is or quoted). The review layer is the
// reader; this file holds the object-review fallback for a window with no reading document, the step through a text
// and the clean-up of text put into a field.

/// The decisions, pure.
nonisolated public enum ReadWhileTypingLogic {

    /// A field typed into, as a compose box is: not a password, not read only, not a terminal or a document.
    public static func isTextInput(axRole: String, subrole: String?, readOnly: Bool) -> Bool {
        guard axRole == "AXTextField" || axRole == "AXTextArea" else { return false }
        if subrole == "AXSecureTextField" { return false }
        return !readOnly
    }

    /// How long after the last review key the review commands (say, copy, put in) still apply.
    public static let recentLimit: TimeInterval = 300

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

@MainActor
enum ReadWhileTyping {
    /// "word" (the default) or "character": what Left and Right step by where there is no reading document.
    static let sideUnitKey = "waypoint.readWhileTyping.sideUnit"
    private static var sidesByCharacter: Bool { UserDefaults.standard.string(forKey: sideUnitKey) == "character" }

    // Where Left and Right are in the item the review cursor is on (object review only).
    private static var sideItem: AXUIElement?
    private static var sideRange: NSRange?

    private static func isTextInput(_ o: TurnOverObject) -> Bool {
        ReadWhileTypingLogic.isTextInput(axRole: o.axRole, subrole: o.axSubrole, readOnly: o.states.contains(.readOnly)) && !Speech.typingIntoSecretField
    }

    private static func isField(_ e: AXUIElement) -> Bool {
        guard let f = API.focusObject else { return false }
        return CFEqual(f.element, e)
    }

    // MARK: Object review (a window with no reading document)

    /// Up and Down.
    static func moveItem(forward: Bool) {
        sideItem = nil; sideRange = nil
        // The review cursor would put the keyboard on the control it lands on, as VoiceOver's does; here the keyboard
        // stays in the field, whatever the setting.
        let saved = config.general.focusFollowsCursor
        config.general.focusFollowsCursor = "off"
        defer { config.general.focusFollowsCursor = saved }
        if forward { ObjectNavigator.shared.next() } else { ObjectNavigator.shared.previous() }
    }

    /// Left and Right: by word (or character, with the setting) through the item the cursor is on.
    static func moveSide(forward: Bool) {
        let byWord = !sidesByCharacter
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

    static func reset() { sideItem = nil; sideRange = nil }

    // MARK: What was reviewed

    private static func reviewedText() -> String? {
        let text: String
        if let d = ReviewLayer.document() {
            guard let info = d.caretInfo() else { return nil }
            info.expand(.line)
            text = info.text
        } else {
            guard let item = ObjectNavigator.shared.reviewElement, !isField(item) else { return nil }
            text = ObjectNavigator.words(item)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// The review commands apply for a while after the layer was last used.
    private static func requireRecent() -> Bool {
        guard Date().timeIntervalSince(ReviewLayer.lastUsed) < ReadWhileTypingLogic.recentLimit else {
            Speech.speakMessage(String(localized: "nothing reviewed yet", comment: "Spoken message"))
            return false
        }
        return true
    }

    static func speakHere() {
        guard requireRecent() else { return }
        if let d = ReviewLayer.document() { d.speakUnit(.line) } else { ObjectNavigator.shared.reportCurrent() }
    }

    static func copyHere() {
        guard requireRecent() else { return }
        guard let text = reviewedText() else { Speech.speakMessage(String(localized: "nothing to copy", comment: "Spoken message")); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Speech.speakMessage(String(localized: "copied", comment: "Spoken message"), remember: false)
    }

    static func insertHere(quoted: Bool) {
        guard requireRecent() else { return }
        guard let focus = API.focusObject, isTextInput(focus) else {
            Speech.speakMessage(String(localized: "the keyboard is not in a text field", comment: "Spoken message"))
            return
        }
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
        let field = focus.element
        // The keys that ran this command may still be down: the paste is sent a moment later, to the field the
        // keyboard is still in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let now = API.focusObject, CFEqual(field, now.element) else { return }
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

/// The commands that act on what the review layer has reviewed, in the key list under Waypoint.
final class ReadWhileTypingPlugin: GlobalPlugin {
    required init() {
        super.init()
        let category = "Waypoint"
        script("readWhileTypingSpeak", String(localized: "After reading around a text field, says where the review cursor is", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+s"], category: category) { _ in
            ReadWhileTyping.speakHere()
        }
        script("readWhileTypingQuote", String(localized: "After reading around a text field, puts the reviewed text into the field as a quote", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+q"], category: category) { _ in
            ReadWhileTyping.insertHere(quoted: true)
        }
        script("readWhileTypingInsert", String(localized: "After reading around a text field, puts the reviewed text into the field as it is", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+i"], category: category) { _ in
            ReadWhileTyping.insertHere(quoted: false)
        }
        script("readWhileTypingCopy", String(localized: "After reading around a text field, copies the reviewed text", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+y"], category: category) { _ in
            ReadWhileTyping.copyHere()
        }
    }

    override func terminate() { ReadWhileTyping.reset() }
}
