// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's typing flight recorder, for the web and Electron fields that sometimes miss, repeat or misread what is
// typed. The log hides typed letters and field text on purpose, so it cannot say whether the field or the reader got
// it wrong. This keeps the last minutes in memory: each real key, what the field held (and which element the system
// says has focus, against the one the reader holds) just after it, everything said and cut, and every log line.
// Nothing reaches the disk until a mark (VO-Command-Equals): then the 30 seconds before it and the 30 after go to
// one text file in "typing marks" for a developer to read. Keys and text are not recorded in a password field.
import Foundation
import ApplicationServices
import TurnOverAX

nonisolated public enum TypingRecorder {
    public static let before: TimeInterval = 30
    public static let after: TimeInterval = 30
    private static let keep: TimeInterval = 100

    public struct Entry: Sendable {
        public let at: Date, kind: String, text: String
        public init(at: Date, kind: String, text: String) { self.at = at; self.kind = kind; self.text = text }
    }

    // The lock guards `entries` and `pending`: every access, from the keyboard thread, main, the log and the read queue,
    // is inside it, and nothing logs or waits while holding it.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []
    nonisolated(unsafe) private static var pending = 0
    private static let reads = DispatchQueue(label: "typing-recorder.reads", qos: .utility)
    private static let writer = DispatchQueue(label: "typing-recorder.writer", qos: .utility)

    public static func note(_ kind: String, _ text: String, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(at: at, kind: kind, text: text))
        if entries.count % 256 == 0 {
            let cutoff = Date().addingTimeInterval(-keep)
            entries.removeAll { $0.at < cutoff }
        }
    }

    /// Every log line, so the file shows the reader's own events between the keys.
    public static func logLine(_ line: String) { note("LOG", String(line.dropLast(line.hasSuffix("\n") ? 1 : 0))) }

    /// Called as a key goes down, on the keyboard thread.
    public static func key(_ gesture: KeyboardGesture) {
        let at = Date(), typed = gesture.typedCharacter.map { String($0) }, id = gesture.identifier, repeating = gesture.isRepeat
        DispatchQueue.main.async { keyOnMain(at: at, typed: typed, id: id, repeating: repeating) }
    }

    @MainActor private static func keyOnMain(at: Date, typed: String?, id: String, repeating: Bool) {
        let focus = API.focusObject
        if focus?.role == .passwordEdit { note("KEY", "(password field: not recorded)", at: at); return }
        note("KEY", (typed.map { "\"\($0)\"  " } ?? "") + id + (repeating ? " (repeat)" : ""), at: at)
        guard let focus else { return }
        let held = focus.element, pid = focus.pid
        for delay in [0, 0.08, 0.3] {
            lock.lock(); let busy = pending > 8; if !busy { pending += 1 }; lock.unlock()
            if busy { note("FIELD", "(skipped: reads are behind)"); continue }
            reads.asyncAfter(deadline: .now() + delay) {
                let text = describeField(held: held, pid: pid, delay: delay)
                lock.lock(); pending -= 1; lock.unlock()
                note("FIELD", text)
            }
        }
    }

    /// What the system says has focus and what it holds, against the element the reader holds.
    private static func describeField(held: AXUIElement, pid: pid_t, delay: TimeInterval) -> String {
        let os = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute)
        let target = os ?? held
        func tag(_ e: AXUIElement) -> String { String(CFHash(e), radix: 16) }
        let (value, error) = target.attrError(kAXValueAttribute)
        var range = CFRange()
        let hasRange = axValue(target.attr(kAXSelectedTextRangeAttribute), .cfRange, &range)
        let heldAlive = held.attrError(kAXRoleAttribute).1 == .success
        let relation = os == nil ? "system focus unreadable" : CFEqual(os!, held) ? "reader holds it" : "READER HOLDS ANOTHER ELEMENT" + (heldAlive ? "" : " (gone)")
        let head = "+\(Int(delay * 1000)) ms \(target.role) #\(tag(target)) [\(relation)]"
        guard let text = value as? String else { return head + " no text (\(error.rawValue))" }
        return head + " " + (hasRange ? excerpt(text, caret: range.location, length: range.length) : "caret unreadable, " + excerpt(text, caret: nil, length: 0))
    }

    /// The text around the caret, with ▮ for the caret and the whole length, newlines as ⏎.
    public static func excerpt(_ text: String, caret: Int?, length: Int, around: Int = 40) -> String {
        let ns = text as NSString
        guard let caret, caret >= 0, caret + length <= ns.length else { return "(\(ns.length) chars) " + ns.substring(to: min(ns.length, 2 * around)).replacingOccurrences(of: "\n", with: "⏎") }
        let from = max(0, caret - around), to = min(ns.length, caret + length + around)
        let left = ns.substring(with: NSRange(location: from, length: caret - from))
        let selected = ns.substring(with: NSRange(location: caret, length: length))
        let right = ns.substring(with: NSRange(location: caret + length, length: to - caret - length))
        let mid = length > 0 ? "▮\(selected)▮" : "▮"
        return "(\(ns.length) chars, caret \(caret)\(length > 0 ? "+\(length)" : "")) " + (from > 0 ? "…" : "") + (left + mid + right).replacingOccurrences(of: "\n", with: "⏎") + (to < ns.length ? "…" : "")
    }

    public static func said(_ text: String, isPrivate: Bool) { note("SAID", (isPrivate ? "(typed echo) " : "") + "\"\(text)\"") }

    /// The marked moment: the file is written once the 30 seconds after it have passed.
    public static func mark() {
        let at = Date()
        note("MARK", "pressed", at: at)
        writer.asyncAfter(deadline: .now() + after + 0.5) { write(markedAt: at) }
        Log.info("typing recorder: marked; the file is written \(Int(after)) seconds from now")
    }

    /// The entries inside the window around a mark, oldest first.
    public static func window(_ all: [Entry], markedAt: Date, before: TimeInterval = TypingRecorder.before, after: TimeInterval = TypingRecorder.after) -> [Entry] {
        all.filter { $0.at >= markedAt.addingTimeInterval(-before) && $0.at <= markedAt.addingTimeInterval(after) }.sorted { $0.at < $1.at }
    }

    /// A few counts up front, so a reader of the file knows where to look.
    static func summary(_ entries: [Entry]) -> String {
        func count(_ kind: String, _ needle: String = "") -> Int { entries.filter { $0.kind == kind && $0.text.contains(needle) }.count }
        return [
            "keys \(count("KEY"))", "typed-character events \(count("LOG", "event typedCharacter"))",
            "said \(count("SAID"))", "speech cuts \(count("CANCEL"))",
            "reader held another element \(count("FIELD", "READER HOLDS ANOTHER"))",
            "field rebuilt \(count("LOG", "rebuilt by the page"))",
            "field hadn't taken the key \(count("LOG", "hadn't taken"))",
            "focus moved on at once \(count("LOG", "moved on at once"))",
            "focus lost/gained \(count("LOG", "event loseFocus")) / \(count("LOG", "event gainFocus"))",
        ].joined(separator: "\n")
    }

    private static func write(markedAt: Date) {
        lock.lock(); let all = entries; lock.unlock()
        let kept = window(all, markedAt: markedAt)
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss.SSS"
        var out = "Typing mark at \(day.string(from: markedAt)); \(Int(before)) s before to \(Int(after)) s after.\n"
        out += "KEY = a real key, FIELD = the field after it (system focus), SAID = spoken, CANCEL = speech cut, LOG = the reader's log line.\n\n"
        out += summary(kept) + "\n\n"
        out += kept.map { "\(clock.string(from: $0.at))  \($0.kind.padding(toLength: 6, withPad: " ", startingAt: 0)) \($0.text)" }.joined(separator: "\n") + "\n"
        let dir = AppPaths.file("typing marks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter(); stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("typing-mark-\(stamp.string(from: markedAt)).txt")
        do { try out.write(to: url, atomically: true, encoding: .utf8); Log.info("typing recorder: wrote \(url.path) (\(kept.count) entries)") }
        catch { Log.warning("typing recorder: could not write \(url.path): \(error)") }
        // These hold real typed text: older ones go (2 days).
        let old = Date().addingTimeInterval(-2 * 24 * 3600)
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()) < old { try? FileManager.default.removeItem(at: f) }
    }
}
