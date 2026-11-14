// SPDX-License-Identifier: GPL-3.0-or-later
// What a text field says it changed. WebKit, Chromium and Electron fields send AXValueChanged with the text inserted or
// deleted and how (typing, a paste, a deletion), a few milliseconds after the key (measured 13 Nov 2026 in GitHub
// Copilot, Teams, Chrome, Safari pages and Outlook for Mac: every typed character, 16 to 20 ms after its key, where
// the field's text and caret settled 80 to 300 ms after it and, in GitHub Copilot's chat box, a character behind).
// NVDA acts on the application's own insert and remove news in the same way. The typed word is told from that news
// when it agrees with the letters typed, and the deleted character from it, so neither depends on a caret that lags.
// An application that sends none leaves the field to be read, as before.
import Foundation

public enum TextNews {
    /// A character that is not part of a word was inserted: the word before it, as the news built it (nil when an
    /// edit in it was missed, or one that cannot be followed came).
    public struct Boundary: Equatable {
        public let at: Date
        public let text: String
        public let word: String?
    }
    private struct Deletion { let at: Date; let text: String }

    /// WebKit's AXTextEditType (and Chromium's, which follows it).
    private enum EditType { static let deletion = 1, insertion = 2, typing = 3, attributes = 7 }

    private static var pid: pid_t = 0
    /// The word being typed, from the inserts and deletes seen since it began; clean while none was missed.
    private static var word = ""
    private static var clean = true
    private static var boundaries: [Boundary] = []
    private static var deletions: [Deletion] = []
    private static var lastEditAt = Date.distantPast
    private static let expiry: TimeInterval = 3
    private static let keep = 16

    /// Edits came from this process lately: its fields send the news worth waiting for.
    public static func isLive(pid: pid_t, now: Date = Date()) -> Bool {
        pid == self.pid && now.timeIntervalSince(lastEditAt) < expiry
    }

    /// The word is no longer known: the focus moved, or a key that is not typing came (the caret may be in a word).
    /// The next ending key starts it afresh.
    public static func reset() {
        word = ""
        clean = false
        boundaries.removeAll()
        deletions.removeAll()
    }

    public struct State { fileprivate let word: String, clean: Bool, boundaries: [Boundary] }
    /// What is known now, to put back when a reset came that the news was not part of (a Backspace's caret read).
    public static func snapshot() -> State { State(word: word, clean: clean, boundaries: boundaries) }
    public static func restore(_ s: State) { word = s.word; clean = s.clean; boundaries = s.boundaries }

    /// An AXValueChanged's detail (AXTextChangeValues: the text, AXTextEditType) from `pid`.
    public static func record(info: [String: Any]?, pid: pid_t, at: Date = Date()) {
        guard let changes = info?["AXTextChangeValues"] as? [[String: Any]] else { return }
        for c in changes {
            guard let text = c["AXTextChangeValue"] as? String, let type = (c["AXTextEditType"] as? NSNumber)?.intValue else { continue }
            apply(type: type, text: text, pid: pid, at: at)
        }
    }

    public static func apply(type: Int, text: String, pid: pid_t, at: Date = Date()) {
        if pid != self.pid { self.pid = pid; reset() }
        if type == EditType.attributes { return }
        lastEditAt = at
        switch type {
        case EditType.deletion:
            deletions.append(Deletion(at: at, text: text))
            if deletions.count > keep { deletions.removeFirst() }
            if text.count == 1, clean, !word.isEmpty { word.removeLast() } else { word = ""; clean = false }
        case EditType.insertion, EditType.typing:
            if text.count == 1, let c = text.first {
                if isInWord(c) { if clean { word.append(c) } }
                else {
                    boundaries.append(Boundary(at: at, text: text, word: clean ? word : nil))
                    if boundaries.count > keep { boundaries.removeFirst() }
                    word = ""; clean = true
                }
            } else { word = ""; clean = false }   // a placeholder, a paste, a correction: not followed
        default:
            word = ""; clean = false
        }
    }

    private static func isInWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }

    /// The word the news says `ch` ended, once it has: the oldest ending of that character whose word agrees with
    /// what was typed (all of it, or its end when a Backspace went into it), and everything before it dropped, so an
    /// ending nothing asked for (a second space) is not taken for the next.
    public static func takeBoundary(for ch: Character, typed: String, edited: Bool, now: Date = Date()) -> String? {
        boundaries.removeAll { now.timeIntervalSince($0.at) > expiry }
        func ends(_ t: String) -> Bool {
            guard let c = t.first else { return false }
            return c == ch || (ch.isNewline && c.isNewline) || (ch == "\"" && "“”„".contains(c))
        }
        guard let i = boundaries.firstIndex(where: { b in
            guard !typed.isEmpty, ends(b.text), let w = b.word, !w.isEmpty else { return false }
            return edited ? w.hasSuffix(typed) : w == typed
        }) else { return nil }
        let w = boundaries[i].word
        boundaries.removeSubrange(0...i)
        return w
    }

    /// The text of the oldest deletion since `time`, once it has come.
    public static func takeDeletion(since time: Date) -> String? {
        guard let i = deletions.firstIndex(where: { $0.at >= time }) else { return nil }
        let t = deletions[i].text
        deletions.removeSubrange(0...i)
        return t
    }
}
