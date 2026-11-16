// SPDX-License-Identifier: GPL-3.0-or-later
// Text rescue: a private, memory-only copy of the long text in each field, and a key (TurnOver Control Z) that puts it
// back when an app has wiped the field. Written 16 Nov 2026 after GitHub Copilot's composer (bundle com.github.githubapp)
// came back holding only its first sentence after the model picker was opened and closed; its own draft store had
// stopped saving, so a long message could not be recovered.
//
// Privacy: the copies live in this process's memory only. They are never written to disk, never logged (the log gets
// character counts, as elsewhere), and never taken from a password field.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

/// The decisions, pure.
nonisolated public enum TextRescueLogic {
    /// Text shorter than this is never worth keeping: it is typed again faster than it is asked for back.
    public static let minimumLength = 20
    /// The most that is read from a field (characters). A bigger field, a book in a word processor, is left alone.
    public static let readLimit = 100_000
    /// How many fields keep a copy; the oldest goes first.
    public static let maxFields = 8

    /// What is kept for one field. `current` is the last text seen. `rescued` is the longer text `current` replaced
    /// when the field suddenly lost most of it.
    public struct Copy: Equatable {
        public var current: String
        public var rescued: String?
        public init(current: String, rescued: String? = nil) { self.current = current; self.rescued = rescued }
    }

    /// A field worth keeping a copy of: a text field or text area, never a password.
    public static func isEligible(axRole: String, subrole: String?) -> Bool {
        guard ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(axRole) else { return false }
        return axRole != "AXSecureTextField" && subrole != "AXSecureTextField"
    }

    /// The copy after the field was seen holding `new`. The rule: typing and small edits just move `current` along. A
    /// drop to under half of what `current` held (and `current` was at least `minimumLength`) is the loss to undo:
    /// the longer text is frozen as `rescued`, and `current` follows the new, short text from there. A later freeze
    /// replaces `rescued` unless that is more than four times longer: a long message lost, then a short reply typed and
    /// sent, must not bury the long one.
    public static func observe(_ copy: Copy?, new: String) -> Copy {
        guard var c = copy else { return Copy(current: new) }
        let before = c.current.count
        if before >= minimumLength, new.count * 2 < before, !(c.rescued.map { $0.count > before * 4 } ?? false) {
            c.rescued = c.current
        }
        c.current = new
        return c
    }

    /// What the key does with the field as it is now.
    public enum Restore: Equatable {
        case nothing
        case alreadyBack
        case put(String)
    }
    public static func restoreAction(current: String, rescued: String?) -> Restore {
        guard let rescued, !rescued.trimmed.isEmpty else { return .nothing }
        if current.contains(rescued.trimmed) { return .alreadyBack }
        return .put(restoredText(current: current, rescued: rescued))
    }

    /// The text the field should hold: the rescued copy in place of what is left of it (the first sentence of it, or
    /// nothing), or, when the field holds something else, that first and the rescued copy after it, so nothing typed
    /// since is lost to the restore.
    public static func restoredText(current: String, rescued: String) -> String {
        let now = current.trimmed
        if now.isEmpty || rescued.hasPrefix(now) { return rescued }
        return now + "\n\n" + rescued
    }

    /// Whether the field now holds what was put in. Web fields change line endings and edges, and some trim a little:
    /// equal once those are normalized, or within five percent in length.
    public static func matches(expected: String, actual: String) -> Bool {
        let a = actual.trimmed.replacingOccurrences(of: "\r\n", with: "\n"), e = expected.trimmed.replacingOccurrences(of: "\r\n", with: "\n")
        if a == e { return true }
        return !e.isEmpty && abs(a.count - e.count) * 20 <= e.count && a.hasPrefix(String(e.prefix(minimumLength)))
    }
}

private extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The copies, on the main thread. The field is read off the main thread (a long text is a slow question to an app);
/// the answer comes back here and is applied only if no later read has been applied first.
public enum TextRescue {
    private struct Entry {
        let element: AXUIElement
        let pid: pid_t
        var copy: TextRescueLogic.Copy?
        var readScheduled = false
        var applied: UInt64 = 0
    }
    /// Oldest first.
    private static var entries: [Entry] = []
    private static var ticket: UInt64 = 0
    /// Value changes come three to a key in a web field: at most one read in this long.
    private static let readInterval: TimeInterval = 0.3

    private static func eligible(_ field: EditableText) -> Bool {
        field.role != .passwordEdit && TextRescueLogic.isEligible(axRole: field.axRole, subrole: field.element.string(kAXSubroleAttribute))
    }

    /// The field's slot, made if new and moved to the newest end; the oldest field goes when there are too many,
    /// one holding a rescued copy last.
    private static func slot(for element: AXUIElement) -> Int {
        var entry = Entry(element: element, pid: element.pid)
        if let i = entries.firstIndex(where: { CFEqual($0.element, element) }) { entry = entries.remove(at: i) }
        entries.append(entry)
        while entries.count > TextRescueLogic.maxFields {
            entries.remove(at: entries.dropLast().firstIndex { $0.copy?.rescued == nil } ?? 0)
        }
        return entries.count - 1
    }
    private static func index(of element: AXUIElement) -> Int? { entries.firstIndex { CFEqual($0.element, element) } }

    /// The field's text changed (an event, several to a key): read it soon, not at once.
    static func noteChange(_ field: EditableText) {
        guard eligible(field) else { return }
        let i = slot(for: field.element)
        guard !entries[i].readScheduled else { return }
        entries[i].readScheduled = true
        let element = field.element
        onMain(after: readInterval) { read(element) }
    }

    /// The keyboard came to the field or left it: read it now. The loss to undo happens while it is elsewhere.
    static func noteFocus(_ field: EditableText) {
        guard eligible(field) else { return }
        _ = slot(for: field.element)
        read(field.element)
    }

    private static func read(_ element: AXUIElement) {
        guard let i = index(of: element) else { return }
        entries[i].readScheduled = false
        ticket += 1
        let mine = ticket
        DispatchQueue.global(qos: .utility).async {
            let text = value(of: element)
            onMain { apply(text, to: element, ticket: mine) }
        }
    }

    /// The field's whole text, or nil if it has none, is too long, or does not answer.
    nonisolated static func value(of element: AXUIElement) -> String? {
        if let n = element.int(kAXNumberOfCharactersAttribute), n > TextRescueLogic.readLimit { return nil }
        guard let v = element.string(kAXValueAttribute), v.count <= TextRescueLogic.readLimit else { return nil }
        return v
    }

    private static func apply(_ text: String?, to element: AXUIElement, ticket: UInt64) {
        guard let i = index(of: element), ticket > entries[i].applied else { return }
        entries[i].applied = ticket
        guard let text else { return }
        record(text, at: i)
    }

    /// Note what the field holds, now.
    static func record(_ text: String, for element: AXUIElement) {
        guard let i = index(of: element) else { return }
        record(text, at: i)
    }
    private static func record(_ text: String, at i: Int) {
        let before = entries[i].copy
        let after = TextRescueLogic.observe(before, new: text)
        entries[i].copy = after
        if after.rescued != before?.rescued, let kept = after.rescued {
            Log.io("text rescue: a field's text fell from \(before?.current.count ?? 0) to \(text.count) characters; \(kept.count) characters kept in memory")
        }
    }

    /// The copy to put back into this field: its own, or, if the app has made the field again (the old element no
    /// longer exists), the newest of the same application's.
    static func lostText(for field: EditableText) -> String? {
        if let own = entries.first(where: { CFEqual($0.element, field.element) })?.copy?.rescued { return own }
        for e in entries.reversed() where e.pid == field.pid && !CFEqual(e.element, field.element) && e.element.attrError(kAXRoleAttribute).1 == .invalidUIElement {
            if let c = e.copy, let text = c.rescued ?? (c.current.count >= TextRescueLogic.minimumLength ? c.current : nil) { return text }
        }
        return nil
    }

    // MARK: Writing the text back

    /// Put `text` in place of the field's whole text, then check by reading it back; `done` gets what the field holds
    /// afterwards, or nil if nothing worked. Web fields (a React text area) are given the text as a paste, which the
    /// page sees as typing; setting their value would leave the page's own copy of it unchanged and send the old
    /// text. Other fields take the value directly, and a paste if they will not.
    static func write(_ text: String, into field: EditableText, done: @escaping @MainActor (String?) -> Void) {
        let element = field.element
        func direct(_ next: @escaping @MainActor () -> Void) {
            guard element.set(kAXValueAttribute, text as CFString) == .success else { next(); return }
            verify(text, in: element, attempts: 2) { actual in if let actual { done(actual) } else { next() } }
        }
        func paste(_ next: @escaping @MainActor () -> Void) {
            pasteText(text, into: element) { ok in
                guard ok else { next(); return }
                verify(text, in: element, attempts: 3) { actual in if let actual { done(actual) } else { next() } }
            }
        }
        if field.isInWebContent { paste { direct { done(nil) } } } else { direct { paste { done(nil) } } }
    }

    /// The field's text if it holds `expected`, looked at again for a slow field, else nil.
    private static func verify(_ expected: String, in element: AXUIElement, attempts: Int, then: @escaping @MainActor (String?) -> Void) {
        onMain(after: 0.2) {
            if let actual = element.string(kAXValueAttribute), TextRescueLogic.matches(expected: expected, actual: actual) { then(actual); return }
            if attempts > 1 { verify(expected, in: element, attempts: attempts - 1, then: then) } else { then(nil) }
        }
    }

    /// Select all and paste, the clipboard put back after. The keys that ran the command may still be down: the
    /// paste goes a moment later, to the field the keyboard is still in (as ReadWhileTyping's does).
    private static func pasteText(_ text: String, into element: AXUIElement, then: @escaping @MainActor (Bool) -> Void) {
        let board = NSPasteboard.general
        // Not over a password a manager has put there (marked concealed or transient): putting it back would undo the
        // manager's clearing of it.
        let marked: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        if (board.types ?? []).contains(where: { marked.contains($0.rawValue) }) {
            Log.io("text rescue: not pasted (the clipboard holds a concealed item)")
            then(false)
            return
        }
        onMain(after: 0.25) {
            guard let now = API.focusObject, CFEqual(element, now.element) else { then(false); return }
            KeyboardGesture(identifier: "kb:command+a")?.send()
            onMain(after: 0.15) {
                let saved = board.pasteboardItems?.map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } } ?? []
                board.clearContents()
                // Marked transient, so clipboard history apps leave it out.
                board.setString(text, forType: .string)
                board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
                let ours = board.changeCount
                KeyboardGesture(identifier: "kb:command+v")?.send()
                onMain(after: 1.0) {
                    // Put back only if nothing else has been copied since (a slow app's paste reads it by then).
                    guard board.changeCount == ours else { return }
                    board.clearContents()
                    let items = saved.map { pairs -> NSPasteboardItem in let i = NSPasteboardItem(); for (t, d) in pairs { i.setData(d, forType: t) }; return i }
                    if !items.isEmpty { board.writeObjects(items) }
                }
                then(true)
            }
        }
    }
}

extension EditableText {
    /// TurnOver Control Z: put back the text the field lost. Pressed again, it says the text is there; nothing is
    /// used up.
    func putBackLostText() {
        let none = String(localized: "no lost text for this field", comment: "Spoken message")
        guard role != .passwordEdit, TextRescueLogic.isEligible(axRole: axRole, subrole: element.string(kAXSubroleAttribute)) else { Speech.speakMessage(none); return }
        let current = element.string(kAXValueAttribute) ?? ""
        TextRescue.record(current, for: element)
        let lost = TextRescue.lostText(for: self)
        switch TextRescueLogic.restoreAction(current: current, rescued: lost) {
        case .nothing:
            Speech.speakMessage(none)
        case .alreadyBack:
            Speech.speakMessage(String(localized: "the text is already back, \(lost?.count ?? 0) characters", comment: "Spoken message: %lld is how many characters"))
        case .put(let text):
            Log.io("text rescue: putting back \(text.count) characters (\(isInWebContent ? "web field" : "field"))")
            let element = element
            TextRescue.write(text, into: self) { actual in
                guard let actual else {
                    Log.io("text rescue: the field did not take the text")
                    Speech.speakMessage(String(localized: "couldn't put the text back", comment: "Spoken message"))
                    return
                }
                TextRescue.record(actual, for: element)
                Speech.speakMessage(String(localized: "text put back, \(text.count) characters", comment: "Spoken message: %lld is how many characters"))
            }
        }
    }
}
