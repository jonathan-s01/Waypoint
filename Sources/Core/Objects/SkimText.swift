// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's skim mode (plan 4.16), the pure parts: what an item is cut down to, and which keys and states decide
// the mode. No application, no speech, no keyboard: all of it is tested (SkimTests).
//
// The text of an item arrives as the Mac says it: pieces joined by ", " ("Alice, Lunch tomorrow?, 3:45 PM, Hey are
// you free"). A piece that is only a role word ("message", "button", "row") or a date, a time or a state ("unread")
// is not what the item is about, so skimming leaves it out.
import Foundation

nonisolated public enum SkimText {

    /// What kind of items a list holds, which says what their key words are.
    public enum Kind: String, CaseIterable, Sendable {
        case message, file, email, result, code, generic
    }

    /// How many words of each part are kept.
    public static let genericWords = 5
    public static let bodyWords = 4
    public static let subjectWords = 5
    public static let senderWords = 3
    public static let nameWords = 6

    /// The key words of an item: short enough to hear many in a few seconds. Empty for blank text.
    public static func keyWords(_ text: String, kind: Kind = .generic) -> String {
        switch kind {
        case .message: return message(text)
        case .file: return file(text)
        case .email: return email(text)
        case .result: return result(text)
        case .code: return code(text)
        case .generic: return generic(text)
        }
    }

    /// The same words with what matters first: the pieces that are only a role word, a date, a time or a state move to
    /// the end, in their order, and nothing is dropped. Text that is already in that order, or has one piece, is
    /// returned as it is (trimmed). Not used by normal speech: it is a building block.
    public static func importantFirst(_ text: String) -> String {
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segs = segments(text)
        guard segs.count > 1 else { return plain }
        let important = segs.filter { !isRoleSegment($0) && !isMetadata($0) }
        let rest = segs.filter { isRoleSegment($0) || isMetadata($0) }
        guard !important.isEmpty, !rest.isEmpty else { return plain }
        // Already in order: every important piece comes before the first other piece.
        if let firstOther = segs.firstIndex(where: { isRoleSegment($0) || isMetadata($0) }),
           !segs[firstOther...].contains(where: { !isRoleSegment($0) && !isMetadata($0) }) { return plain }
        return (important + rest).joined(separator: ", ")
    }

    /// What kind of items an app's lists hold, from its bundle identifier.
    public static func kind(bundleID: String?) -> Kind {
        guard let id = bundleID?.lowercased() else { return .generic }
        let email: Set<String> = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.google.chrome.app.gmail"]
        let message: Set<String> = ["com.apple.mobilesms", "com.apple.ichat", "net.whatsapp.whatsapp", "com.tinyspeck.slackmacgap", "com.hnc.discord",
                                    "ru.keepcoder.telegram", "org.whispersystems.signal-desktop", "com.microsoft.teams", "com.microsoft.teams2"]
        let code: Set<String> = ["com.apple.dt.xcode", "com.microsoft.vscode", "com.sublimetext.4", "com.sublimetext.3", "com.panic.nova", "com.todesktop.230313mzl4w4u92"]
        if email.contains(id) { return .email }
        if message.contains(id) { return .message }
        if id == "com.apple.finder" { return .file }
        if code.contains(id) || id.hasPrefix("com.jetbrains.") { return .code }
        if id == "com.apple.spotlight" { return .result }
        return .generic
    }

    /// The speech rate for skimming: a good step above the user's own, never past the top of the scale.
    public static func fasterRate(from base: Float) -> Float {
        min(1.0, max(0.1, base) + 0.15)
    }

    // MARK: Pieces

    /// Invisible marks gone, runs of white space one space, no blank edges.
    public static func collapsed(_ s: String) -> String {
        let invisible: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x00AD, 0xFEFF, 0x2060, 0xFFFC]
        let kept = String(s.unicodeScalars.filter { !invisible.contains($0.value) && !(0x2066...0x2069).contains($0.value) })
        return kept.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The pieces of an item's text: split at new lines, ", ", " | " and bullets; none empty.
    public static func segments(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            var l = line
            for sep in [" | ", " \u{2022} ", " \u{00B7} "] { l = l.replacingOccurrences(of: sep, with: ", ") }
            for part in l.components(separatedBy: ", ") {
                let c = collapsed(part).trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
                if !c.isEmpty { out.append(c) }
            }
        }
        return out
    }

    /// Words that count: those with a letter or a digit in them (a lone dash is not a word).
    public static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    /// The first `limit` words, never cut inside a word, with no separator left dangling at the end.
    public static func firstWords(_ s: String, _ limit: Int) -> String {
        guard limit > 0 else { return "" }
        var out: [Substring] = []
        var counted = 0
        for token in s.split(whereSeparator: { $0.isWhitespace }) {
            if token.contains(where: { $0.isLetter || $0.isNumber }) {
                if counted == limit { break }
                counted += 1
            }
            out.append(token)
        }
        return out.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-\u{2013}\u{2014}|"))
    }

    /// A word as it is compared: lower case, no punctuation or space at the edges.
    static func key(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }

    // MARK: Which words say little

    /// A piece that only names what kind of thing the item is.
    static let roleSegments: Set<String> = [
        "message", "button", "row", "cell", "group", "text", "static text", "link", "image", "heading", "list", "item", "table", "outline",
        "text field", "text area", "search field", "checkbox", "check box", "radio button", "menu item", "menu button", "pop up button", "tab",
        "column", "scroll area", "toolbar", "web content", "search result",
    ]

    /// A word at the end of a piece that only names the control ("Save button").
    static let trailingRoleWords: Set<String> = ["button", "row", "cell", "link", "checkbox"]

    /// Words that start a piece and say nothing about it.
    static let leadingFiller: Set<String> = ["the", "a", "an", "unread", "read", "selected", "flagged", "from"]

    /// State and time pieces: they say when or how the item is, not what it is.
    static let metadataWords: Set<String> = [
        "unread", "read", "flagged", "selected", "attachment", "attachments", "has attachments", "vip", "replied", "forwarded", "pinned", "muted",
        "delivered", "today", "yesterday", "tomorrow", "just now", "now", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sun", "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat",
    ]

    static func isRoleSegment(_ s: String) -> Bool { roleSegments.contains(key(s)) }

    static func isMetadata(_ s: String) -> Bool {
        let k = key(s)
        if metadataWords.contains(k) { return true }
        let months = "(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*"
        let patterns = [
            "^\\d{1,2}:\\d{2}(:\\d{2})?\\s?(am|pm|a\\.m|p\\.m)?$",
            "^\\d{1,4}[/.-]\\d{1,2}[/.-]\\d{1,4}$",
            "^(19|20)\\d{2}$",
            "^\\d+\\s?(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|wk|week|weeks)( ago)?$",
            "^[\\d.,]+\\s?(bytes?|kb|mb|gb|tb)$",
            "^\(months)\\.? \\d{1,2}(,? \\d{4})?( at .*)?$",
            "^\\d{1,2} \(months)\\.?(,? \\d{4})?( at .*)?$",
            "^(today|yesterday|tomorrow|[a-z]+day) at .*$",
        ]
        return patterns.contains { k.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static func stripLeadingFiller(_ s: String) -> String {
        var words = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while words.count > 1, leadingFiller.contains(key(words[0])) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    static func stripTrailingRole(_ s: String) -> String {
        var words = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count > 1, let last = words.last, trailingRoleWords.contains(key(last)) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// The first `limit` words across pieces, the pieces kept apart by ", ".
    static func takeWords(_ segs: [String], limit: Int) -> String {
        var parts: [String] = []
        var left = limit
        for seg in segs where left > 0 {
            let n = wordCount(seg)
            guard n > 0 else { continue }
            if n <= left { parts.append(seg); left -= n } else { parts.append(firstWords(seg, left)); left = 0 }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: Kinds

    static func generic(_ text: String) -> String {
        let segs = segments(text)
        let kept = segs.filter { !isRoleSegment($0) }
        var source = (kept.isEmpty ? Array(segs.prefix(1)) : kept).map(stripTrailingRole)
        if let first = source.first { source[0] = stripLeadingFiller(first) }
        return takeWords(source, limit: genericWords)
    }

    /// The sender and the first words of what was said. "Alice: hello there" and "Alice, hello there" are the same.
    static func message(_ text: String) -> String {
        var segs = segments(text).filter { !isRoleSegment($0) }
        if let first = segs.first, let r = first.range(of: ": ") {
            let who = String(first[..<r.lowerBound]), rest = String(first[r.upperBound...])
            let n = wordCount(who)
            if n >= 1, n <= senderWords, !["re", "fw", "fwd"].contains(key(who)), wordCount(rest) > 0 { segs.replaceSubrange(0...0, with: [who, rest]) }
        }
        segs = segs.filter { !isMetadata($0) }
        guard let first = segs.first else { return "" }
        if segs.count > 1, wordCount(first) <= senderWords {
            let who = stripLeadingFiller(first)
            let body = takeWords(segs.dropFirst().map(stripTrailingRole), limit: bodyWords)
            return body.isEmpty ? who : who + ", " + body
        }
        return takeWords(segs.map(stripTrailingRole), limit: genericWords)
    }

    /// The sender and the subject, without "Re:", the date, the state or the preview.
    static func email(_ text: String) -> String {
        let segs = segments(text).filter { !isRoleSegment($0) && !isMetadata($0) }
        guard let first = segs.first else { return "" }
        guard segs.count > 1 else { return firstWords(stripLeadingFiller(first), genericWords) }
        let sender = firstWords(stripLeadingFiller(first), senderWords)
        let subject = firstWords(withoutReplyPrefix(segs[1]), subjectWords)
        return subject.isEmpty ? sender : sender + ", " + subject
    }

    static func withoutReplyPrefix(_ s: String) -> String {
        var t = s
        var again = true
        while again {
            again = false
            for p in ["re:", "fw:", "fwd:"] where t.lowercased().hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                again = true
                break
            }
        }
        return t
    }

    /// The name and the type: "report.pdf, PDF document, 2 MB" is "report, PDF"; "Documents, folder, 12 items" is
    /// "Documents, folder".
    static func file(_ text: String) -> String {
        let segs = segments(text).filter { !isRoleSegment($0) }
        guard let name = segs.first else { return "" }
        if let (stem, ext) = splitExtension(name) {
            let s = firstWords(stem, nameWords)
            return s.isEmpty ? ext.uppercased() : s + ", " + ext.uppercased()
        }
        let n = firstWords(name, nameWords)
        if let type = segs.dropFirst().first(where: { !isMetadata($0) && !$0.contains(where: \.isNumber) && wordCount($0) <= 3 }) { return n + ", " + type }
        return n
    }

    /// A name and its extension; nil when the last dot is no extension ("Mr. Smith", "Version 1.2", ".gitignore").
    static func splitExtension(_ name: String) -> (stem: String, ext: String)? {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return nil }
        let ext = String(name[name.index(after: dot)...]), stem = String(name[..<dot])
        guard (1...5).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }), ext.contains(where: \.isLetter),
              !stem.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (stem, ext)
    }

    /// The title of a search result, without its number or the site after a dash.
    static func result(_ text: String) -> String {
        let segs = segments(text).filter { !isRoleSegment($0) }
        guard let first = segs.first else { return "" }
        var title = first.replacingOccurrences(of: "^\\d{1,3}[.)]\\s+", with: "", options: .regularExpression)
        for sep in [" - ", " \u{2013} ", " \u{2014} "] {
            if let r = title.range(of: sep), !title[..<r.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty { title = String(title[..<r.lowerBound]) }
        }
        return firstWords(stripLeadingFiller(title), nameWords)
    }

    /// The start of the first line that has anything on it, without its indent or its comment mark.
    static func code(_ text: String) -> String {
        guard let line = text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        var s = line.trimmingCharacters(in: .whitespaces)
        var again = true
        while again {
            again = false
            for p in ["///", "//", "/*", "*/", "<!--", "# ", "-- ", "* ", ";; "] where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                again = true
                break
            }
        }
        return s.split(whereSeparator: { $0.isWhitespace }).prefix(genericWords).joined(separator: " ")
    }
}

/// The decisions, pure: which keys the mode claims, when it must end, and where Up and Down go.
nonisolated public enum SkimLogic {

    public enum Move: Hashable, Sendable {
        case previous, next, readFull, off
    }

    /// Plain Up, Down, Return and Escape only: with any modifier the key still belongs to the app.
    public static func move(forKey keyName: String, modifiers: Modifiers) -> Move? {
        guard modifiers.isEmpty else { return nil }
        switch keyName {
        case "upArrow": return .previous
        case "downArrow": return .next
        case "enter", "numpadEnter", "return": return .readFull
        case "escape": return .off
        default: return nil
        }
    }

    /// How long the mode stays on with no key before it ends by itself.
    public static let idleLimit: TimeInterval = 300

    /// What is true now, gathered by the caller.
    public struct Situation: Equatable, Sendable {
        public var settingEnabled: Bool
        public var isOn: Bool
        public var sameApp: Bool
        public var sameFocus: Bool
        public var menuOpen: Bool
        public var idleSeconds: TimeInterval
        public init(settingEnabled: Bool, isOn: Bool, sameApp: Bool, sameFocus: Bool, menuOpen: Bool, idleSeconds: TimeInterval) {
            self.settingEnabled = settingEnabled; self.isOn = isOn; self.sameApp = sameApp
            self.sameFocus = sameFocus; self.menuOpen = menuOpen; self.idleSeconds = idleSeconds
        }
    }

    public enum OffReason: Equatable, Sendable {
        case settingOff, menuOpen, otherApp, focusMoved, idle
    }

    /// Why the mode must end now; nil while it may go on (and nil when it is not on).
    public static func offReason(_ s: Situation) -> OffReason? {
        guard s.isOn else { return nil }
        if !s.settingEnabled { return .settingOff }
        if s.menuOpen { return .menuOpen }
        if !s.sameApp { return .otherApp }
        if !s.sameFocus { return .focusMoved }
        if s.idleSeconds > idleLimit { return .idle }
        return nil
    }

    /// The move a key makes: nil (the key goes to the app) unless the mode is on and valid and the key is one of its four.
    public static func claim(keyName: String, modifiers: Modifiers, in s: Situation) -> Move? {
        guard s.isOn, offReason(s) == nil else { return nil }
        return move(forKey: keyName, modifiers: modifiers)
    }

    /// The item Up or Down goes to, from the one reached last (nil: none yet, so Down goes to the first and Up to
    /// the last). nil at either end.
    public static func step(from index: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let i = index else { return forward ? 0 : count - 1 }
        let j = forward ? i + 1 : i - 1
        return (0..<count).contains(j) ? j : nil
    }
}
