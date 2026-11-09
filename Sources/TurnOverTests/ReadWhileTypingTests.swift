// SPDX-License-Identifier: GPL-3.0-or-later
// Read while typing (plan 4.7): which keys are claimed in which state, when the mode ends, and the stepping and
// the text put into a field. All pure: no application, no speech, no keyboard.
import Foundation
import TurnOverCore

func readWhileTypingTests() {
    typealias Logic = ReadWhileTypingLogic

    func state(on: Bool = true, setting: Bool = true, input: Bool = true, same: Bool = true, app: Bool = true, menu: Bool = false, idle: TimeInterval = 1) -> Logic.Situation {
        Logic.Situation(settingEnabled: setting, isOn: on, focusIsTextInput: input, sameField: same, sameApp: app, menuOpen: menu, idleSeconds: idle)
    }

    test("read while typing: only the four plain arrows are moves") {
        expect(Logic.move(forKey: "upArrow", modifiers: []), .previousItem)
        expect(Logic.move(forKey: "downArrow", modifiers: []), .nextItem)
        expect(Logic.move(forKey: "leftArrow", modifiers: []), .previousPart)
        expect(Logic.move(forKey: "rightArrow", modifiers: []), .nextPart)
        for key in ["a", "return", "space", "tab", "escape", "home", "end", "pageUp", "delete", "1", "."] {
            check(Logic.move(forKey: key, modifiers: []) == nil, "\(key) stays with the field")
        }
    }

    test("read while typing: an arrow with any modifier stays with the field") {
        for key in ["upArrow", "downArrow", "leftArrow", "rightArrow"] {
            for mods in [Modifiers.shift, .control, .option, .command, .turnover, [.shift, .option], [.command, .shift]] {
                check(Logic.move(forKey: key, modifiers: mods) == nil, "\(key) with \(mods.rawValue) is not taken")
            }
        }
    }

    test("read while typing: a mode that is off claims nothing") {
        for key in ["upArrow", "downArrow", "leftArrow", "rightArrow"] {
            check(Logic.claim(keyName: key, modifiers: [], in: state(on: false)) == nil, "\(key), mode off")
        }
    }

    test("read while typing: a mode that is on and valid claims the plain arrows") {
        expect(Logic.claim(keyName: "upArrow", modifiers: [], in: state()), .previousItem)
        expect(Logic.claim(keyName: "rightArrow", modifiers: [], in: state()), .nextPart)
        check(Logic.claim(keyName: "x", modifiers: [], in: state()) == nil, "a letter is typed")
        check(Logic.claim(keyName: "upArrow", modifiers: .shift, in: state()) == nil, "Shift-Up selects in the field")
        check(Logic.claim(keyName: "return", modifiers: [], in: state()) == nil, "Return sends")
    }

    test("read while typing: the mode ends when it may not go on") {
        expect(Logic.offReason(state()), nil)
        expect(Logic.offReason(state(on: false, setting: false, same: false)), nil, "nothing to end when it is not on")
        expect(Logic.offReason(state(setting: false)), .settingOff)
        expect(Logic.offReason(state(menu: true)), .menuOpen)
        expect(Logic.offReason(state(app: false)), .otherApp)
        expect(Logic.offReason(state(same: false)), .leftField)
        expect(Logic.offReason(state(input: false)), .notTextInput)
        expect(Logic.offReason(state(idle: Logic.idleLimit + 1)), .idle)
        expect(Logic.offReason(state(idle: Logic.idleLimit)), nil, "at the limit it goes on")
    }

    test("read while typing: no arrow is claimed once the mode must end") {
        let broken = [state(setting: false), state(menu: true), state(app: false), state(same: false), state(input: false), state(idle: 10_000)]
        for s in broken {
            for key in ["upArrow", "downArrow", "leftArrow", "rightArrow"] {
                check(Logic.claim(keyName: key, modifiers: [], in: s) == nil, "\(key) goes to the field in \(s)")
            }
        }
    }

    test("read while typing: the reason that matters first is named") {
        expect(Logic.offReason(state(setting: false, same: false, app: false, menu: true)), .settingOff)
        expect(Logic.offReason(state(app: false, menu: true)), .menuOpen)
        expect(Logic.offReason(state(same: false, app: false)), .otherApp)
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
}
