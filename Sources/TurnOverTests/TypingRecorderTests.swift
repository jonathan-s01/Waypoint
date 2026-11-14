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
    test("stale focus: a group the application no longer has focused gives way to the field the keys go to") {
        expect(StaleFocus.shouldTake(heldIsEditable: false, heldHasText: false, namedIsEditable: true, same: false), true)
        expect(StaleFocus.shouldTake(heldIsEditable: false, heldHasText: false, namedIsEditable: true, same: true), false)
        expect(StaleFocus.shouldTake(heldIsEditable: true, heldHasText: true, namedIsEditable: true, same: false), false)
        expect(StaleFocus.shouldTake(heldIsEditable: false, heldHasText: true, namedIsEditable: true, same: false), false)
        expect(StaleFocus.shouldTake(heldIsEditable: false, heldHasText: false, namedIsEditable: false, same: false), false)
    }
    test("stale focus: an editable field that is gone gives way to the one the keys go to") {
        expect(StaleFocus.shouldTake(heldIsEditable: true, heldHasText: true, heldIsGone: true, namedIsEditable: true, same: false), true)
        expect(StaleFocus.shouldTake(heldIsEditable: true, heldHasText: true, heldIsGone: false, namedIsEditable: true, same: false), false)
    }
    test("stale focus: typed characters, Backspace and the arrows act on a field") {
        expect(StaleFocus.actsOnField(typedCharacter: "a", keyName: "a"), true)
        expect(StaleFocus.actsOnField(typedCharacter: nil, keyName: "leftArrow"), true)
        expect(StaleFocus.actsOnField(typedCharacter: nil, keyName: "backspace"), true)
        expect(StaleFocus.actsOnField(typedCharacter: nil, keyName: "escape"), false)
    }
    test("typed word: after a miss the field is waited for briefly, until the miss is old") {
        expect(TurnOverObject.fieldWaitAttempts(sinceMiss: 1), 3)
        expect(TurnOverObject.fieldWaitAttempts(sinceMiss: 60), 10)
    }
    test("typed word: a caret trailing the text does not put the word's start on the word before") {
        expect(TurnOverObject.wordStart(caret: 426, expected: 427), 427)
        expect(TurnOverObject.wordStart(caret: 427, expected: 427), 427)
        expect(TurnOverObject.wordStart(caret: 428, expected: 427), 428)
        expect(TurnOverObject.wordStart(caret: 100, expected: 427), 100)
        expect(TurnOverObject.wordStart(caret: 426, expected: nil), 426)
        // "chat and": the caret trails by one, the key lies past it, and the word is "and", not "chat".
        let r = Speech.fieldWord(endedBy: " ", before: "chat an▮d ".replacingOccurrences(of: "▮", with: ""), notBefore: 5)
        expect(r.word, "and")
    }
    test("typed word: after a Backspace the ending key is found just past a trailing caret, not the space before") {
        // "…effectivly want ": caret 17 (before the key), the word retyped after Backspace, so no start is known:
        // looked for from one before the caret on, the first space is the key and the word is "want".
        let text = "effectivly want "
        let caret = 14
        let r = Speech.fieldWord(endedBy: " ", before: text, notBefore: caret - 1)
        expect(r.taken, true)
        expect(r.word, "want")
        // A space before the word's start is not mistaken for the key.
        let early = Speech.fieldWord(endedBy: " ", before: "want ", notBefore: 4)
        expect(early.word, "want")
        expect(Speech.fieldWord(endedBy: " ", before: "want", notBefore: 3).taken, false)
    }
    test("typed word: a start that fell on the space before the word skips that space, and the next start is past the word") {
        // "2,  there ": the caret trailed by one, so the start (192) lay on the old space at 191.
        let text = "2,  there "
        let old = Speech.fieldWord(endedBy: " ", before: text, notBefore: 2)
        expect(old.word, nil)
        let r = Speech.fieldWord(endedBy: " ", before: text, notBefore: 2, skippingEmpty: true)
        expect(r.taken, true)
        expect(r.word, "there")
        expect(r.next, text.utf16.count)
    }
    test("typing recorder: notification detail is written out, with its text and nesting") {
        expect(TypingRecorder.describeNews("AXValueChanged", info: nil), "ValueChanged (no detail)")
        let line = TypingRecorder.describeNews("AXValueChanged", info: ["AXTextChangeValue": "a", "AXTextStateChangeType": 1, "AXTextChangeValues": [["AXTextChangeValue": "b"]]])
        expect(line, "ValueChanged {TextChangeValue: \"a\", TextChangeValues: [{TextChangeValue: \"b\"}], TextStateChangeType: 1}")
    }
    test("text news: a typed word is told from the inserts, when its letters agree with those typed") {
        TextNews.reset()
        let t0 = Date()
        TextNews.apply(type: 3, text: " ", pid: 7001, at: t0)   // a word before it ends: the word after starts clean
        for c in "hello" { TextNews.apply(type: 3, text: String(c), pid: 7001, at: t0) }
        TextNews.apply(type: 3, text: " ", pid: 7001, at: t0)
        expect(TextNews.takeBoundary(for: " ", typed: "help", edited: false, now: t0), nil)   // letters that disagree
        TextNews.reset()
        TextNews.apply(type: 3, text: " ", pid: 7001, at: t0)
        for c in "hello" { TextNews.apply(type: 3, text: String(c), pid: 7001, at: t0) }
        TextNews.apply(type: 3, text: " ", pid: 7001, at: t0)
        expect(TextNews.takeBoundary(for: " ", typed: "hello", edited: false, now: t0), "hello")
        expect(TextNews.takeBoundary(for: " ", typed: "hello", edited: false, now: t0), nil)   // taken once
    }
    test("text news: a Backspace inside a word, a paste and a placeholder are followed or refused") {
        let t0 = Date()
        TextNews.reset()
        TextNews.apply(type: 3, text: " ", pid: 7002, at: t0)
        for c in "thinks" { TextNews.apply(type: 3, text: String(c), pid: 7002, at: t0) }
        TextNews.apply(type: 1, text: "s", pid: 7002, at: t0)
        TextNews.apply(type: 3, text: ",", pid: 7002, at: t0)
        // The letters typed since the Backspace are its end; all that was typed matches the whole word too.
        expect(TextNews.takeBoundary(for: ",", typed: "k", edited: true, now: t0), "think")
        // A placeholder ("Type a message") and a paste make the word unfollowable until the next ending.
        TextNews.apply(type: 2, text: "Type a message\n", pid: 7002, at: t0)
        TextNews.apply(type: 3, text: "t", pid: 7002, at: t0)
        TextNews.apply(type: 3, text: " ", pid: 7002, at: t0)
        expect(TextNews.takeBoundary(for: " ", typed: "t", edited: false, now: t0), nil)
        TextNews.apply(type: 3, text: "o", pid: 7002, at: t0)
        TextNews.apply(type: 3, text: " ", pid: 7002, at: t0)
        expect(TextNews.takeBoundary(for: " ", typed: "o", edited: false, now: t0), "o")
        // A Backspace with nothing of the word to take it from, and a deleted character told on its own.
        TextNews.apply(type: 1, text: "e", pid: 7002, at: t0)
        expect(TextNews.takeDeletion(since: t0), "s")   // oldest first
        expect(TextNews.takeDeletion(since: t0), "e")
        expect(TextNews.takeDeletion(since: t0), nil)
    }
    test("text news: a boundary no one asked for is skipped, and old news is not used") {
        let t0 = Date()
        TextNews.reset()
        TextNews.apply(type: 3, text: " ", pid: 7003, at: t0)
        for c in "one" { TextNews.apply(type: 3, text: String(c), pid: 7003, at: t0) }
        TextNews.apply(type: 3, text: " ", pid: 7003, at: t0)
        TextNews.apply(type: 3, text: " ", pid: 7003, at: t0)   // a second space: empty word, never taken as a word
        expect(TextNews.takeBoundary(for: " ", typed: "one", edited: false, now: t0.addingTimeInterval(10)), nil)
        expect(TextNews.isLive(pid: 7003, now: t0.addingTimeInterval(1)), true)
        expect(TextNews.isLive(pid: 7003, now: t0.addingTimeInterval(10)), false)
        expect(TextNews.isLive(pid: 7004, now: t0), false)
    }
}
