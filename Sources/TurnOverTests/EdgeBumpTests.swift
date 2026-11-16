// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func edgeBumpTests() {
    test("edge bump: right-to-left text is told from left-to-right, so only the latter bumps at once at an edge") {
        check(!EditableText.hasRightToLeft("Hello, world 123"), "English")
        check(EditableText.hasRightToLeft("שלום"), "Hebrew")
        check(EditableText.hasRightToLeft("hello مرحبا"), "Arabic in a line of English")
        check(!EditableText.hasRightToLeft(""), "nothing")
    }
    test("edge bump: Left and Right bump at once only when the caret and its line both reach the edge") {
        func edge(_ key: String, caret: Int, lineStart: Int = 0, lineEnd: Int = 10, length: Int = 10, empty: Bool = false) -> Bool {
            EditableText.sidewaysEdge(key: key, caret: caret, lineStart: lineStart, lineEnd: lineEnd, length: length, fieldIsEmpty: empty)
        }
        check(edge("leftArrow", caret: 0), "Left at the start")
        check(!edge("leftArrow", caret: 0, lineStart: 4), "an app that reports caret 0 while the line starts later")
        check(!edge("leftArrow", caret: 3), "Left in the middle")
        check(edge("rightArrow", caret: 10), "Right at the end")
        check(!edge("rightArrow", caret: 10, lineEnd: 6), "Right when the line ends before the end")
        check(!edge("rightArrow", caret: 0, lineEnd: 0, length: 0), "length 0 not confirmed by the field")
        check(edge("rightArrow", caret: 0, lineEnd: 0, length: 0, empty: true), "an empty field")
        check(!edge("upArrow", caret: 0), "other keys are not sideways")
    }
    test("focus: a popup holds the focus, the field behind it still has the typed keys, the popup's own Up and Down stay its") {
        check(StaleFocus.actsOnFieldBehindPopup(typedCharacter: "a", keyName: "a"), "a typed character")
        check(StaleFocus.actsOnFieldBehindPopup(typedCharacter: nil, keyName: "backspace"), "Backspace")
        check(StaleFocus.actsOnFieldBehindPopup(typedCharacter: nil, keyName: "leftArrow"), "Left")
        check(!StaleFocus.actsOnFieldBehindPopup(typedCharacter: nil, keyName: "downArrow"), "Down moves in the popup's list")
        check(!StaleFocus.actsOnFieldBehindPopup(typedCharacter: nil, keyName: "upArrow"), "Up moves in the popup's list")
        check(StaleFocus.fieldHasKeysBehind(sameHeld: true, newsAge: 2), "news just now, the same popup")
        check(!StaleFocus.fieldHasKeysBehind(sameHeld: false, newsAge: 2), "the focus has moved on to something else")
        check(!StaleFocus.fieldHasKeysBehind(sameHeld: true, newsAge: 60), "no news for a long while")
    }
    test("lines: a line with a paragraph break inside is not a line, one that ends in a break is") {
        check(AXTextInfo.holdsHardBreak("first paragraph\nsecond paragraph"), "a break in the middle (Chrome answers the whole field as one line)")
        check(AXTextInfo.holdsHardBreak("one\r\ntwo"), "a Windows break in the middle")
        check(!AXTextInfo.holdsHardBreak("a line that ends the paragraph\n"), "the break that ends a line")
        check(!AXTextInfo.holdsHardBreak("a line that ends the paragraph\r\n"), "a Windows break that ends a line")
        check(!AXTextInfo.holdsHardBreak("a plain line"), "no break")
        check(!AXTextInfo.holdsHardBreak(""), "nothing")
    }
    test("edge bump: an end the caret was seen to stop short of is the end, for that length and process only") {
        expect(EditableText.reachableEnd(length: 193, pid: 7, learned: (pid: 7, length: 193, caret: 192)), 192)
        expect(EditableText.reachableEnd(length: 194, pid: 7, learned: (pid: 7, length: 193, caret: 192)), 194)
        expect(EditableText.reachableEnd(length: 193, pid: 8, learned: (pid: 7, length: 193, caret: 192)), 193)
        expect(EditableText.reachableEnd(length: 193, pid: 7, learned: nil), 193)
        check(EditableText.isHiddenTail(caret: 192, length: 193), "one character short")
        check(EditableText.isHiddenTail(caret: 1701, length: 1705), "a field that counts its paragraph breaks")
        check(!EditableText.isHiddenTail(caret: 193, length: 193), "at the end")
        check(!EditableText.isHiddenTail(caret: 100, length: 193), "mid-text")
    }
}
