// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func typingRecorderTests() {
    test("typing recorder: the excerpt marks the caret and shows the length") {
        expect(TypingRecorder.excerpt("hello world", caret: 5, length: 0), "(11 chars, caret 5) hello▮ world")
        expect(TypingRecorder.excerpt("a\nb", caret: 2, length: 0), "(3 chars, caret 2) a⏎▮b")
        expect(TypingRecorder.excerpt("abcdef", caret: 1, length: 2), "(6 chars, caret 1+2) a▮bc▮def")
    }
    test("typing recorder: a long field shows the text around the caret only") {
        let text = String(repeating: "x", count: 100) + "|" + String(repeating: "y", count: 100)
        let shown = TypingRecorder.excerpt(text, caret: 100, length: 0, around: 3)
        expect(shown, "(201 chars, caret 100) …xxx▮|yy…")
    }
    test("typing recorder: an unreadable caret still shows the start of the text") {
        expect(TypingRecorder.excerpt("abc", caret: nil, length: 0), "(3 chars) abc")
        expect(TypingRecorder.excerpt("abc", caret: 9, length: 0), "(3 chars) abc")
    }
    test("typing recorder: a mark keeps 30 seconds each side, in time order") {
        let mark = Date(timeIntervalSince1970: 1000)
        func entry(_ s: TimeInterval, _ t: String) -> TypingRecorder.Entry { .init(at: mark.addingTimeInterval(s), kind: "KEY", text: t) }
        let kept = TypingRecorder.window([entry(5, "d"), entry(-31, "a"), entry(-30, "b"), entry(30, "e"), entry(31, "f"), entry(-1, "c")], markedAt: mark)
        expect(kept.map(\.text), ["b", "c", "d", "e"])
    }
    test("typing recorder: the summary counts keys, speech and cuts") {
        let at = Date(timeIntervalSince1970: 1000)
        let all = ["KEY", "KEY", "SAID", "CANCEL"].map { TypingRecorder.Entry(at: at, kind: $0, text: "x") }
        let lines = TypingRecorder.summary(all).split(separator: "\n").map(String.init)
        expect(lines.contains("keys 2"), true)
        expect(lines.contains("said 1"), true)
        expect(lines.contains("speech cuts 1"), true)
    }
}
