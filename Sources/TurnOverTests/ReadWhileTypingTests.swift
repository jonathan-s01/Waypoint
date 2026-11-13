// SPDX-License-Identifier: GPL-3.0-or-later
// The review layer (plan 4.7): which keys the chord takes and what each means, and the stepping and the text put
// into a field. All pure: no application, no speech, no keyboard.
import Foundation
import TurnOverCore

func readWhileTypingTests() {
    typealias Logic = ReadWhileTypingLogic

    typealias Layer = ReviewLayerLogic
    let std = Layer.Chord.standard
    let held = Layer.Device.leftOption | Layer.Device.rightShift
    func chord(_ key: String, extra: UInt = 0, hold: UInt? = nil, turnover: Bool = false) -> Layer.Decision? {
        Layer.decide(flags: (hold ?? held) | extra, keyName: key, chord: std, armed: false, turnOverKey: turnover)
    }

    test("review layer: without the chord no key is taken") {
        for key in ["h", "a", "leftArrow", "home", "enter", "escape", "tab", "space", ","] {
            check(Layer.decide(flags: 0, keyName: key, chord: std, armed: false, turnOverKey: false) == nil, "\(key), no keys held")
            check(chord(key, hold: Layer.Device.leftOption) == nil, "\(key), Left Option alone")
            check(chord(key, hold: Layer.Device.rightShift) == nil, "\(key), Right Shift alone")
            check(chord(key, hold: Layer.Device.leftOption | Layer.Device.leftShift) == nil, "\(key), Left Option and Left Shift")
        }
    }

    test("review layer: a letter is the document's quick key, Left Shift reverses it") {
        expect(chord("h"), .review("kb:h"))
        expect(chord("h", extra: Layer.Device.leftShift), .review("kb:shift+h"))
        expect(chord("3"), .review("kb:3"))
        expect(chord(","), .review("kb:,"))
        expect(chord("h", extra: Layer.Device.rightOption), .review("kb:h"), "Right Option does not change a letter")
    }

    test("review layer: arrows read, with Right Option by word") {
        expect(chord("downArrow"), .review("kb:downArrow"))
        expect(chord("leftArrow", extra: Layer.Device.rightOption), .review("kb:option+leftArrow"))
        expect(chord("upArrow", extra: Layer.Device.rightOption), .review("kb:option+upArrow"))
    }

    test("review layer: Left Shift and an arrow select in the field, with Right Option by word") {
        expect(chord("rightArrow", extra: Layer.Device.leftShift), .select("kb:shift+rightArrow"))
        expect(chord("leftArrow", extra: Layer.Device.leftShift | Layer.Device.rightOption), .select("kb:option+shift+leftArrow"))
    }

    test("review layer: Home, End, the page keys and Return") {
        expect(chord("home"), .review("kb:home"))
        expect(chord("pageDown"), .review("kb:pageDown"))
        check(chord("end", extra: Layer.Device.leftShift) == nil, "Shift End is the field's")
        expect(chord("enter"), .activate)
        check(chord("enter", extra: Layer.Device.leftShift) == nil, "Shift Return is the field's")
        for key in ["space", "escape", "delete", "f1", "-"] { check(chord(key) == nil, "\(key) goes to the application") }
        expect(chord("tab"), .review("kb:tab"))
        expect(chord("tab", extra: Layer.Device.leftShift), .review("kb:shift+tab"))
    }

    test("review layer: another modifier or a TurnOver key is some other command") {
        check(chord("h", extra: Layer.Device.leftControl) == nil, "with Control")
        check(chord("h", extra: Layer.Device.leftCommand) == nil, "with Command")
        check(chord("h", turnover: true) == nil, "with the TurnOver key")
        check(chord("h", extra: Layer.Device.rightControl) == nil, "with Right Control")
    }

    test("pointer place: the TurnOver key, the layer's keys or chosen keys make a click place the cursor") {
        typealias P = PointerPlaceLogic
        let layer = held
        check(P.captures(flags: 0, turnOverHeld: true, layerHold: layer, extraHold: 0), "the TurnOver key")
        check(P.captures(flags: held, turnOverHeld: false, layerHold: layer, extraHold: 0), "the layer's keys")
        check(!P.captures(flags: Layer.Device.leftOption, turnOverHeld: false, layerHold: layer, extraHold: 0), "half the chord is not enough")
        check(!P.captures(flags: held, turnOverHeld: false, layerHold: 0, extraHold: 0), "layer off: its keys are nothing")
        check(P.captures(flags: Layer.Device.rightControl, turnOverHeld: false, layerHold: layer, extraHold: Layer.Device.rightControl), "chosen keys")
        check(!P.captures(flags: 0, turnOverHeld: false, layerHold: layer, extraHold: Layer.Device.rightControl), "a plain click is the app's")
    }

    test("pointer place: the layer's keys or Right Option with the TurnOver key place the second reader, other clicks the keyboard's") {
        typealias P = PointerPlaceLogic
        let layer = held
        check(P.isSecond(flags: held, turnOverHeld: false, layerHold: layer), "the layer's keys")
        check(P.isSecond(flags: held | Layer.Device.rightOption, turnOverHeld: true, layerHold: layer), "the layer's keys and the TurnOver key")
        check(P.isSecond(flags: Layer.Device.rightOption, turnOverHeld: true, layerHold: layer), "Right Option with the TurnOver key")
        check(!P.isSecond(flags: 0, turnOverHeld: true, layerHold: layer), "the TurnOver key alone is the keyboard's")
        check(!P.isSecond(flags: Layer.Device.leftOption, turnOverHeld: true, layerHold: layer), "Left Option with the TurnOver key is the keyboard's")
        check(!P.isSecond(flags: Layer.Device.rightOption, turnOverHeld: false, layerHold: layer), "Right Option alone is not")
        check(!P.isSecond(flags: held, turnOverHeld: false, layerHold: 0), "layer off: its keys are nothing")
    }

    test("review layer: the chord can be changed") {
        let mine = Layer.Chord(hold: Layer.Device.rightControl, reverse: Layer.Device.leftShift, word: Layer.Device.leftOption)
        expect(Layer.decide(flags: Layer.Device.rightControl, keyName: "h", chord: mine, armed: false, turnOverKey: false), .review("kb:h"))
        expect(Layer.decide(flags: Layer.Device.rightControl | Layer.Device.leftOption, keyName: "leftArrow", chord: mine, armed: false, turnOverKey: false), .review("kb:option+leftArrow"))
        check(Layer.decide(flags: held, keyName: "h", chord: mine, armed: false, turnOverKey: false) == nil, "the old chord is free")
        let none = Layer.Chord(hold: 0, reverse: 0, word: 0)
        check(Layer.decide(flags: 0, keyName: "h", chord: none, armed: false, turnOverKey: false) == nil, "no keys chosen: never on")
    }

    test("review layer: armed, the plain keys count and Shift and Option are the modifiers") {
        func armed(_ key: String, _ flags: UInt = 0) -> Layer.Decision? { Layer.decide(flags: flags, keyName: key, chord: std, armed: true, turnOverKey: false) }
        expect(armed("h"), .review("kb:h"))
        expect(armed("h", Layer.Generic.shift), .review("kb:shift+h"))
        expect(armed("leftArrow", Layer.Generic.option), .review("kb:option+leftArrow"))
        expect(armed("leftArrow", Layer.Generic.shift), .select("kb:shift+leftArrow"))
        expect(armed("escape"), .off)
        check(armed("h", Layer.Generic.command) == nil, "Command-H is the application's")
        check(armed("h", Layer.Generic.control) == nil, "Control-H is the application's")
        expect(armed("tab", Layer.Generic.shift), .review("kb:shift+tab"))
    }

    test("review layer: only the document's reading scripts may run") {
        for name in ["moveByLine_down", "moveByWord_left", "nextHeading", "previousLink", "vo_nextHeading", "startOfLine", "endOfLine", "topOfDocument", "bottomOfDocument", "sayAllFromHere", "pastEndOfContainer", "startOfContainer"] {
            check(Layer.isAllowed(script: name), "\(name) is allowed")
        }
        for name in ["tabFromCaret", "disablePassThrough", "activatePosition", "selectCharacter_right", "elementsList", "browseModeTrap"] {
            check(!Layer.isAllowed(script: name), "\(name) is not allowed")
        }
    }

    test("read while typing: text fields are taken, passwords and read only fields are not") {
        check(Logic.isTextInput(axRole: "AXTextField", subrole: nil, readOnly: false), "a text field")
        check(Logic.isTextInput(axRole: "AXTextArea", subrole: nil, readOnly: false), "a text area")
        check(Logic.isTextInput(axRole: "AXTextField", subrole: "AXSearchField", readOnly: false), "a search field")
        check(!Logic.isTextInput(axRole: "AXTextField", subrole: "AXSecureTextField", readOnly: false), "a password")
        check(!Logic.isTextInput(axRole: "AXTextArea", subrole: nil, readOnly: true), "read only")
        check(!Logic.isTextInput(axRole: "AXButton", subrole: nil, readOnly: false), "a button")
        check(!Logic.isTextInput(axRole: "AXWebArea", subrole: nil, readOnly: false), "a page")
        check(!Logic.isTextInput(axRole: "AXStaticText", subrole: nil, readOnly: false), "static text")
    }

    func pieces(_ text: String, forward: Bool, byWord: Bool) -> [String] {
        var out: [String] = []
        var at: NSRange?
        while let r = Logic.step(in: text, from: at, forward: forward, byWord: byWord), out.count < 100 {
            out.append((text as NSString).substring(with: r))
            at = r
        }
        return out
    }

    test("read while typing: Right steps forward through the words, Left back through them") {
        expect(pieces("Hello, brave new world", forward: true, byWord: true), ["Hello", "brave", "new", "world"])
        expect(pieces("Hello, brave new world", forward: false, byWord: true), ["world", "new", "brave", "Hello"])
    }

    test("read while typing: characters step whole, a combined character is one step") {
        expect(pieces("ab", forward: true, byWord: false), ["a", "b"])
        expect(pieces("ab", forward: false, byWord: false), ["b", "a"])
        expect(pieces("e\u{301}x", forward: true, byWord: false), ["e\u{301}", "x"])
        expect(pieces("x👍🏽", forward: false, byWord: false), ["👍🏽", "x"])
    }

    test("read while typing: stepping stops at the edges and in empty text") {
        check(Logic.step(in: "", from: nil, forward: true, byWord: true) == nil, "empty, forward")
        check(Logic.step(in: "", from: nil, forward: false, byWord: false) == nil, "empty, back")
        check(Logic.step(in: "one", from: NSRange(location: 0, length: 3), forward: true, byWord: true) == nil, "past the last word")
        check(Logic.step(in: "one", from: NSRange(location: 0, length: 3), forward: false, byWord: true) == nil, "before the first word")
        check(Logic.step(in: "   ", from: nil, forward: true, byWord: true) == nil, "no word in spaces")
    }

    test("read while typing: a stale position starts again instead of failing") {
        let r = Logic.step(in: "one two", from: NSRange(location: 40, length: 3), forward: true, byWord: true)
        expect(r, NSRange(location: 0, length: 3))
        let back = Logic.step(in: "one two", from: NSRange(location: -1, length: 3), forward: false, byWord: true)
        expect(back, NSRange(location: 4, length: 3))
    }

    test("read while typing: a quote puts \"> \" before each line and never ends in a new line") {
        expect(Logic.insertable("Hello there", quoted: true), "> Hello there")
        expect(Logic.insertable("one\ntwo\n", quoted: true), "> one\n> two")
        expect(Logic.insertable("one\n\ntwo", quoted: true), "> one\n>\n> two")
        expect(Logic.insertable("  padded \n", quoted: true), "> padded")
    }

    test("read while typing: an insert is the text as it is, trimmed, and nothing for blank text") {
        expect(Logic.insertable("  Hello there\n", quoted: false), "Hello there")
        expect(Logic.insertable("one\ntwo", quoted: false), "one\ntwo")
        expect(Logic.insertable("", quoted: false), "")
        expect(Logic.insertable(" \n\t ", quoted: true), "")
        expect(Logic.insertable(String(repeating: "a", count: Logic.insertLimit + 50), quoted: false).count, Logic.insertLimit)
    }

    test("review layer: a message heading is a level 2 \"said\" heading") {
        check(ReviewStart.isMessageHeading(title: "Copilot said: Done.", level: 2), "Copilot's reply")
        check(ReviewStart.isMessageHeading(title: "You said: go on", level: 2), "your message")
        check(!ReviewStart.isMessageHeading(title: "Ran git status and 2 other tool calls", level: 3), "a tool call")
        check(!ReviewStart.isMessageHeading(title: "Copilot said: Done.", level: 3), "a said heading at another level")
        check(!ReviewStart.isMessageHeading(title: nil, level: 2), "no title")
    }
}
