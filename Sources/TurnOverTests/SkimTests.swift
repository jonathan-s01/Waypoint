// SPDX-License-Identifier: GPL-3.0-or-later
// Skim mode (plan 4.16): what an item is cut down to for each kind of list, the important-words-first order, the
// speed, and which keys the mode claims and when it ends. All pure: no application, no speech, no keyboard.
import Foundation
import TurnOverCore

func skimTests() {
    typealias Logic = SkimLogic

    func kw(_ text: String, _ kind: SkimText.Kind = .generic) -> String { SkimText.keyWords(text, kind: kind) }

    func state(on: Bool = true, setting: Bool = true, app: Bool = true, focus: Bool = true, menu: Bool = false, idle: TimeInterval = 1) -> Logic.Situation {
        Logic.Situation(settingEnabled: setting, isOn: on, sameApp: app, sameFocus: focus, menuOpen: menu, idleSeconds: idle)
    }

    // MARK: Pieces

    test("skim: segments split at commas, new lines and bars, with no empty piece") {
        expect(SkimText.segments("a, b | c"), ["a", "b", "c"])
        expect(SkimText.segments("one\ntwo\n\nthree"), ["one", "two", "three"])
        expect(SkimText.segments("a,, b"), ["a", "b"])
        expect(SkimText.segments("  spaced   out  "), ["spaced out"])
        expect(SkimText.segments(""), [])
        expect(SkimText.segments("  \n  "), [])
        expect(SkimText.segments("a - b"), ["a - b"])
    }

    test("skim: invisible marks are not in the pieces") {
        expect(SkimText.collapsed("Hel\u{200B}lo\u{FEFF} wor\u{200E}ld"), "Hello world")
        expect(SkimText.collapsed("\u{2066}Alice\u{2069}"), "Alice")
    }

    test("skim: only words with a letter or a digit are counted") {
        expect(SkimText.wordCount("- hello \u{2014} world"), 2)
        expect(SkimText.wordCount("1 2 3"), 3)
        expect(SkimText.wordCount(""), 0)
        expect(SkimText.wordCount("... !!!"), 0)
    }

    test("skim: first words are whole words and leave no dangling mark") {
        expect(SkimText.firstWords("alpha beta gamma", 2), "alpha beta")
        expect(SkimText.firstWords("alpha beta", 1), "alpha")
        expect(SkimText.firstWords("alpha beta", 5), "alpha beta")
        expect(SkimText.firstWords("one two three four five - six", 5), "one two three four five")
        expect(SkimText.firstWords("one, two, three", 2), "one, two")
        expect(SkimText.firstWords("alpha beta", 0), "")
        expect(SkimText.firstWords("", 3), "")
    }

    // MARK: Generic

    test("skim: generic keeps the first five words") {
        expect(kw("The quick brown fox jumps over the lazy dog"), "quick brown fox jumps over")
        expect(kw("one two three four five six seven eight nine ten eleven twelve"), "one two three four five")
        expect(kw("1 2 3 4 5 6 7"), "1 2 3 4 5")
        expect(kw("Short"), "Short")
        expect(kw("two words"), "two words")
    }

    test("skim: generic drops role words") {
        expect(kw("Save button"), "Save")
        expect(kw("Inbox row"), "Inbox")
        expect(kw("row, Inbox, 12 messages"), "Inbox, 12 messages")
        expect(kw("message, Alice, hello"), "Alice, hello")
        expect(kw("Open link"), "Open")
    }

    test("skim: generic keeps a lone role word rather than saying nothing") {
        expect(kw("button"), "button")
        expect(kw("message, button"), "message")
        expect(kw("link"), "link")
    }

    test("skim: generic drops leading filler but not the last word") {
        expect(kw("a an the unread Report"), "Report")
        expect(kw("Unread"), "Unread")
        expect(kw("the"), "the")
        expect(kw("flagged selected Budget summary"), "Budget summary")
    }

    test("skim: generic joins pieces and cuts across them") {
        expect(kw("Line one\nLine two"), "Line one, Line two")
        expect(kw("Alpha beta gamma, delta epsilon zeta"), "Alpha beta gamma, delta epsilon")
    }

    test("skim: blank text gives nothing, whatever the kind") {
        for kind in SkimText.Kind.allCases {
            expect(kw("", kind), "", "\(kind) empty")
            expect(kw("   \n \t ", kind), "", "\(kind) white space")
        }
    }

    test("skim: invisible marks do not count as words or text") {
        expect(kw("Hello\u{200B} world"), "Hello world")
        expect(kw("\u{200B}\u{200B}"), "")
    }

    test("skim: key words never end in a dangling mark") {
        expect(kw("one two three four five - six"), "one two three four five")
        expect(kw("one two three four five, six"), "one two three four five")
    }

    // MARK: Messages

    test("skim: a message is the sender and the first four words") {
        expect(kw("Alice, Are you free for lunch tomorrow, 3:45 PM", .message), "Alice, Are you free for")
        expect(kw("Carol Jones, Dinner at eight", .message), "Carol Jones, Dinner at eight")
    }

    test("skim: a message drops roles, states and times") {
        expect(kw("message, unread, Carol Jones, Dinner at eight, Yesterday", .message), "Carol Jones, Dinner at eight")
        expect(kw("Dana, Meeting moved, 10:30", .message), "Dana, Meeting moved")
        expect(kw("Eve, ok see you, 5 min ago", .message), "Eve, ok see you")
        expect(kw("Frank, hi there, 12/03/2026", .message), "Frank, hi there")
        expect(kw("Grace, Happy birthday, Jan 5, 2026", .message), "Grace, Happy birthday")
        expect(kw("Hal, Lunch, Yesterday at 9:15 AM", .message), "Hal, Lunch")
        expect(kw("Ian, On my way, Monday", .message), "Ian, On my way")
    }

    test("skim: a message written as sender, colon, words is the same") {
        expect(kw("Bob: see you at the station", .message), "Bob, see you at the")
    }

    test("skim: a reply mark is not a sender") {
        expect(kw("Re: budget numbers", .message), "Re: budget numbers")
    }

    test("skim: a message with one piece is its first five words") {
        expect(kw("Thank you so much for everything you did last week", .message), "Thank you so much for")
    }

    test("skim: a message with a long sender is cut as plain words") {
        expect(kw("Alice Bob Carol Dave, hello world", .message), "Alice Bob Carol Dave, hello")
    }

    test("skim: a message with nothing but roles and states is nothing") {
        expect(kw("message", .message), "")
        expect(kw("message, unread, Yesterday", .message), "")
    }

    test("skim: a message with a sender alone is the sender") {
        expect(kw("Judy, 3:45 PM", .message), "Judy")
    }

    // MARK: Mail

    test("skim: mail is the sender and the subject without the reply mark, the date or the preview") {
        expect(kw("Alice Smith, Re: Quarterly report, Mar 3, unread, Please find attached", .email), "Alice Smith, Quarterly report")
        expect(kw("Bob, Re: Fwd: Invoice 42", .email), "Bob, Invoice 42")
        expect(kw("Carol, one two three four five six seven", .email), "Carol, one two three four five")
        expect(kw("Anna Marie Van Der Berg, Hello there", .email), "Anna Marie Van, Hello there")
        expect(kw("unread, message, Dana, Lunch", .email), "Dana, Lunch")
        expect(kw("Eve, FW: Agenda", .email), "Eve, Agenda")
    }

    test("skim: mail with one piece is that piece") {
        expect(kw("Meeting notes", .email), "Meeting notes")
        expect(kw("message, Meeting notes", .email), "Meeting notes")
    }

    // MARK: Files

    test("skim: a file is its name and its type") {
        expect(kw("report.pdf, PDF document, 2 MB", .file), "report, PDF")
        expect(kw("photo.JPG, image", .file), "photo, JPG")
        expect(kw("row, budget.xlsx, Excel", .file), "budget, XLSX")
        expect(kw("archive.tar.gz, 1 MB", .file), "archive.tar, GZ")
    }

    test("skim: a folder says what it is") {
        expect(kw("Documents, folder, 12 items", .file), "Documents, folder")
        expect(kw("Notes, Today at 5:00 PM", .file), "Notes")
        expect(kw("Applications", .file), "Applications")
    }

    test("skim: a dot is not always an extension") {
        expect(kw("Mr. Smith notes", .file), "Mr. Smith notes")
        expect(kw(".gitignore", .file), ".gitignore")
        expect(kw("Version 1.2", .file), "Version 1.2")
    }

    test("skim: a long file name is cut to six words") {
        expect(kw("one two three four five six seven eight.txt", .file), "one two three four five six, TXT")
    }

    // MARK: Results

    test("skim: a result is its title without the number or the site") {
        expect(kw("1. Swift documentation - Apple Developer", .result), "Swift documentation")
        expect(kw("The Swift Programming Language | Apple", .result), "Swift Programming Language")
        expect(kw("2) Another result, example.com", .result), "Another result")
        expect(kw("one two three four five six seven eight", .result), "one two three four five six")
        expect(kw("button", .result), "")
    }

    // MARK: Code

    test("skim: code is the start of the first line with anything on it") {
        expect(kw("    // TODO: fix the parser now", .code), "TODO: fix the parser now")
        expect(kw("/// Doc comment here for the thing", .code), "Doc comment here for the")
        expect(kw("\n\n  func load(url: URL) throws -> Data {", .code), "func load(url: URL) throws ->")
        expect(kw("# Heading text", .code), "Heading text")
        expect(kw("-- SQL comment", .code), "SQL comment")
        expect(kw("/* start of block", .code), "start of block")
        expect(kw("*  list item", .code), "list item")
        expect(kw("#include <stdio.h>", .code), "#include <stdio.h>")
    }

    // MARK: Kind of list

    test("skim: the kind comes from the app") {
        expect(SkimText.kind(bundleID: nil), .generic)
        expect(SkimText.kind(bundleID: ""), .generic)
        expect(SkimText.kind(bundleID: "com.example.unknown"), .generic)
        expect(SkimText.kind(bundleID: "com.apple.mail"), .email)
        expect(SkimText.kind(bundleID: "com.apple.Mail"), .email)
        expect(SkimText.kind(bundleID: "com.microsoft.Outlook"), .email)
        expect(SkimText.kind(bundleID: "com.apple.MobileSMS"), .message)
        expect(SkimText.kind(bundleID: "com.tinyspeck.slackmacgap"), .message)
        expect(SkimText.kind(bundleID: "com.apple.finder"), .file)
        expect(SkimText.kind(bundleID: "com.apple.dt.Xcode"), .code)
        expect(SkimText.kind(bundleID: "com.jetbrains.intellij"), .code)
        expect(SkimText.kind(bundleID: "com.apple.Spotlight"), .result)
    }

    // MARK: Important first

    test("skim: important words first moves roles, states and times to the end") {
        expect(SkimText.importantFirst("message, Alice, Lunch tomorrow, 3:45 PM"), "Alice, Lunch tomorrow, message, 3:45 PM")
        expect(SkimText.importantFirst("9:00 AM, Standup"), "Standup, 9:00 AM")
        expect(SkimText.importantFirst("unread, Alice, Hello"), "Alice, Hello, unread")
    }

    test("skim: important words first leaves text that is in order, and changes nothing else") {
        expect(SkimText.importantFirst("Alice, Lunch tomorrow, 3:45 PM"), "Alice, Lunch tomorrow, 3:45 PM")
        expect(SkimText.importantFirst("  Alice, Lunch, 3:45 PM \n"), "Alice, Lunch, 3:45 PM")
        expect(SkimText.importantFirst("  Hello world  "), "Hello world")
        expect(SkimText.importantFirst("unread, 3:45 PM"), "unread, 3:45 PM")
        expect(SkimText.importantFirst("Alice, Bob"), "Alice, Bob")
        expect(SkimText.importantFirst(""), "")
    }

    test("skim: important words first is idempotent and drops nothing") {
        for text in ["message, Alice, Lunch tomorrow, 3:45 PM", "9:00 AM, Standup", "unread, Alice, Hello, Mon, Budget", "a, b, c"] {
            let once = SkimText.importantFirst(text)
            expect(SkimText.importantFirst(once), once, "twice: \(text)")
            expect(SkimText.segments(once).sorted(), SkimText.segments(text).sorted(), "same pieces: \(text)")
        }
    }

    // MARK: Speed

    test("skim: skimming is faster than the user's rate and never past the top") {
        check(abs(SkimText.fasterRate(from: 0.55) - 0.70) < 0.0001, "a step up from 0.55")
        check(SkimText.fasterRate(from: 0.95) == 1.0, "capped at 1.0")
        check(SkimText.fasterRate(from: 1.0) == 1.0, "already at the top")
        check(abs(SkimText.fasterRate(from: 0) - 0.25) < 0.0001, "a floor under a zero rate")
        check(abs(SkimText.fasterRate(from: -3) - 0.25) < 0.0001, "a floor under a negative rate")
        for base in stride(from: Float(0.1), through: 1.0, by: 0.1) {
            check(SkimText.fasterRate(from: base) >= base, "never slower than \(base)")
        }
    }

    // MARK: Keys

    test("skim: Up, Down, Return and Escape are the moves") {
        expect(Logic.move(forKey: "upArrow", modifiers: []), .previous)
        expect(Logic.move(forKey: "downArrow", modifiers: []), .next)
        expect(Logic.move(forKey: "enter", modifiers: []), .readFull)
        expect(Logic.move(forKey: "numpadEnter", modifiers: []), .readFull)
        expect(Logic.move(forKey: "return", modifiers: []), .readFull)
        expect(Logic.move(forKey: "escape", modifiers: []), .off)
        for key in ["a", "space", "tab", "leftArrow", "rightArrow", "home", "end", "pageUp", "pageDown", "delete", "1", "."] {
            check(Logic.move(forKey: key, modifiers: []) == nil, "\(key) stays with the app")
        }
    }

    test("skim: a key with any modifier stays with the app") {
        for key in ["upArrow", "downArrow", "enter", "escape"] {
            for mods in [Modifiers.shift, .control, .option, .command, .turnover, [.shift, .option], [.command, .shift]] {
                check(Logic.move(forKey: key, modifiers: mods) == nil, "\(key) with \(mods.rawValue) is not taken")
            }
        }
    }

    test("skim: the keys are claimed only while the mode is on and valid") {
        expect(Logic.claim(keyName: "downArrow", modifiers: [], in: state()), .next)
        expect(Logic.claim(keyName: "enter", modifiers: [], in: state()), .readFull)
        check(Logic.claim(keyName: "downArrow", modifiers: [], in: state(on: false)) == nil, "off: the arrow goes to the app")
        check(Logic.claim(keyName: "downArrow", modifiers: [], in: state(setting: false)) == nil, "feature off")
        check(Logic.claim(keyName: "downArrow", modifiers: [], in: state(menu: true)) == nil, "menu open")
        check(Logic.claim(keyName: "escape", modifiers: [], in: state(app: false)) == nil, "other app")
        check(Logic.claim(keyName: "upArrow", modifiers: [], in: state(focus: false)) == nil, "focus moved")
        check(Logic.claim(keyName: "upArrow", modifiers: [], in: state(idle: 301)) == nil, "idle")
        check(Logic.claim(keyName: "a", modifiers: [], in: state()) == nil, "letters are never claimed")
        check(Logic.claim(keyName: "downArrow", modifiers: .shift, in: state()) == nil, "shift-down is the app's")
    }

    test("skim: it ends on a change of focus, app, menu or setting, or when idle") {
        check(Logic.offReason(state()) == nil, "fine")
        expect(Logic.offReason(state(setting: false)), .settingOff)
        expect(Logic.offReason(state(menu: true)), .menuOpen)
        expect(Logic.offReason(state(app: false)), .otherApp)
        expect(Logic.offReason(state(focus: false)), .focusMoved)
        expect(Logic.offReason(state(idle: 301)), .idle)
    }

    test("skim: five minutes idle is the limit") {
        expect(Logic.idleLimit, 300)
        check(Logic.offReason(state(idle: 300)) == nil, "exactly five minutes is still on")
        expect(Logic.offReason(state(idle: 300.5)), .idle)
        check(Logic.offReason(state(idle: 0)) == nil, "just used")
    }

    test("skim: when several things changed the reason is the same each time") {
        expect(Logic.offReason(state(setting: false, app: false, focus: false, menu: true, idle: 999)), .settingOff)
        expect(Logic.offReason(state(app: false, focus: false, menu: true, idle: 999)), .menuOpen)
        expect(Logic.offReason(state(app: false, focus: false, idle: 999)), .otherApp)
        expect(Logic.offReason(state(focus: false, idle: 999)), .focusMoved)
    }

    test("skim: a mode that is not on has no reason to end") {
        check(Logic.offReason(state(on: false, setting: false, app: false, focus: false, menu: true, idle: 999)) == nil, "off stays off")
    }

    // MARK: Stepping

    test("skim: Down and Up step one item and stop at the ends") {
        expect(Logic.step(from: 0, count: 3, forward: true), 1)
        expect(Logic.step(from: 1, count: 3, forward: true), 2)
        check(Logic.step(from: 2, count: 3, forward: true) == nil, "bottom")
        expect(Logic.step(from: 2, count: 3, forward: false), 1)
        expect(Logic.step(from: 1, count: 3, forward: false), 0)
        check(Logic.step(from: 0, count: 3, forward: false) == nil, "top")
    }

    test("skim: before any item, Down goes to the first and Up to the last") {
        expect(Logic.step(from: nil, count: 4, forward: true), 0)
        expect(Logic.step(from: nil, count: 4, forward: false), 3)
    }

    test("skim: an empty list, or an index past it, has nowhere to go") {
        check(Logic.step(from: nil, count: 0, forward: true) == nil, "empty down")
        check(Logic.step(from: nil, count: 0, forward: false) == nil, "empty up")
        check(Logic.step(from: 0, count: 0, forward: true) == nil, "empty from zero")
        check(Logic.step(from: 5, count: 3, forward: true) == nil, "past the end, down")
        check(Logic.step(from: 1, count: 1, forward: true) == nil, "one item, down")
        check(Logic.step(from: 0, count: 1, forward: false) == nil, "one item, up")
    }
}
