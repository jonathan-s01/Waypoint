// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func mouseTrackingTests() {
    test("mouse tracking: a pointer that has hardly moved is not looked at again") {
        var t = PointerTracker<String>()
        expect(t.worthLooking(at: CGPoint(x: 100, y: 100)), true, "the first place is always looked at")
        t.looked(at: CGPoint(x: 100, y: 100))
        expect(t.worthLooking(at: CGPoint(x: 102, y: 103)), false, "5 points is a tremor")
        expect(t.worthLooking(at: CGPoint(x: 106, y: 100)), true, "6 points is a move")
        expect(t.worthLooking(at: CGPoint(x: 100, y: 94)), true, "up as well as across")
    }

    test("mouse tracking: an item is said once, however many looks find it") {
        var t = PointerTracker<String>()
        expect(t.answer("Save"), .say)
        expect(t.answer("Save"), .nothing, "still over the same button")
        expect(t.answer("Cancel"), .say, "a new one")
        expect(t.answer("Save"), .say, "back to the first is a change")
    }

    test("mouse tracking: a text inside the row just said is silent, and the row is not said again for it") {
        var t = PointerTracker<String>()
        expect(t.answer("row A"), .say)
        expect(t.spokenIs(in: ["row A"]), true)
        expect(t.answer("text", insideSpoken: t.spokenIs(in: ["row A"])), .nothing, "inside the row said")
        expect(t.answer("row A"), .nothing, "back on the row: it was never replaced")
        expect(t.answer("text of B", insideSpoken: t.spokenIs(in: ["row B"])), .say, "inside another row")
    }

    test("mouse tracking: a blank place is the empty sound once, and coming back to the item says it again") {
        var t = PointerTracker<String>()
        expect(t.answer(nil), .nothing, "blank from the start has nothing to leave")
        expect(t.answer("Save"), .say)
        expect(t.answer(nil), .blank, "leaving the item for blank space")
        expect(t.answer(nil), .nothing, "still blank: the sound is not repeated")
        expect(t.answer("Save"), .say, "the same button after a gap is heard again, as VoiceOver does")
    }

    test("mouse tracking: a look given up on leaves its place to be looked at again, and what was said stays said") {
        var t = PointerTracker<String>()
        t.looked(at: CGPoint(x: 5, y: 5))
        _ = t.answer("Save")
        t.forgetLook()
        expect(t.worthLooking(at: CGPoint(x: 5, y: 5)), true, "the pointer resting where the lost look was")
        expect(t.answer("Save"), .nothing, "the same item is not said twice")
        expect(t.answer("Cancel"), .say)
    }

    test("mouse tracking: a reset forgets where the pointer was and what was said") {
        var t = PointerTracker<String>()
        t.looked(at: CGPoint(x: 5, y: 5))
        _ = t.answer("Save")
        t.reset()
        expect(t.worthLooking(at: CGPoint(x: 5, y: 5)), true)
        expect(t.answer("Save"), .say, "turned on again, the item under the pointer is said")
    }

    test("mouse tracking: off unless asked for, and kept in the file once set") {
        expect(Config().presentation.mouseTracking, false)
        var c = Config()
        c.presentation.mouseTracking = true
        let back = try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        expect(back?.presentation.mouseTracking, true)
        let old = try? JSONDecoder().decode(Config.self, from: Data("{\"presentation\":{\"verbosity\":\"medium\"}}".utf8))
        expect(old?.presentation.mouseTracking, false, "a file from before the setting existed")
        expect(Config().presentation.mouseMovesCursor, true, "the cursor follows unless that is turned off")
        c.presentation.mouseMovesCursor = false
        let kept = try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        expect(kept?.presentation.mouseMovesCursor, false)
        expect(old?.presentation.mouseMovesCursor, true, "a file from before the setting existed")
    }

    test("mouse tracking: interrupting other speech is on in Waypoint, and kept in the file once changed") {
        expect(Config().presentation.mouseInterruptsSpeech, true)
        var c = Config()
        c.presentation.mouseInterruptsSpeech = false
        let kept = try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        expect(kept?.presentation.mouseInterruptsSpeech, false)
        let old = try? JSONDecoder().decode(Config.self, from: Data("{\"presentation\":{\"mouseTracking\":true}}".utf8))
        expect(old?.presentation.mouseInterruptsSpeech, true, "a file from before the setting existed")
    }

    test("mouse paragraphs: off unless asked for, and kept in the file once set") {
        expect(Config().presentation.mouseReadsParagraphs, false)
        var c = Config()
        c.presentation.mouseReadsParagraphs = true
        let kept = try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        expect(kept?.presentation.mouseReadsParagraphs, true)
        let old = try? JSONDecoder().decode(Config.self, from: Data("{\"presentation\":{\"mouseTracking\":true}}".utf8))
        expect(old?.presentation.mouseReadsParagraphs, false, "a file from before the setting existed")
    }

    test("mouse paragraphs: the pieces of one paragraph are said once") {
        var t = PointerTracker<String>()
        expect(t.answer("text 1", block: "P", readsBlock: true), .say, "the first piece reads the paragraph")
        expect(t.answer("bold", block: "P", readsBlock: true), .nothing, "a bold piece of it is silent")
        expect(t.answer("text 2", block: "P", readsBlock: true), .nothing, "so is the text after")
        expect(t.answer("text 3", block: "Q", readsBlock: true), .say, "another paragraph")
    }

    test("mouse paragraphs: a link in the paragraph is said as a link, and the text after it stays silent") {
        var t = PointerTracker<String>()
        expect(t.answer("text 1", block: "P", readsBlock: true), .say)
        expect(t.answer("link", block: "P"), .say, "the link says itself and its role")
        expect(t.answer("text 2", block: "P", readsBlock: true), .nothing, "the paragraph was already read")
    }

    test("mouse paragraphs: entering a paragraph at its link reads the paragraph at the next plain text") {
        var t = PointerTracker<String>()
        expect(t.answer("button"), .say)
        expect(t.answer("link", block: "P"), .say)
        expect(t.answer("text 2", block: "P", readsBlock: true), .say, "not yet read")
    }

    test("mouse paragraphs: the gap between lines does not make the paragraph new, but leaving it does") {
        var t = PointerTracker<String>()
        expect(t.answer("text 1", block: "P", readsBlock: true), .say)
        expect(t.answer(nil), .blank)
        expect(t.answer("text 2", block: "P", readsBlock: true), .nothing, "back in the same paragraph")
        expect(t.answer("Save"), .say, "something else")
        expect(t.answer("text 1", block: "P", readsBlock: true), .say, "back to the paragraph after it")
    }

    test("mouse tracking: a file with the removed blank-sound and watchdog settings still loads") {
        let old = try? JSONDecoder().decode(Config.self, from: Data("{\"presentation\":{\"mouseTracking\":true,\"mouseEmptySound\":false,\"mouseWatchdog\":false}}".utf8))
        expect(old?.presentation.mouseTracking, true)
    }

    test("mouse tracking: a watchdog for an earlier look does nothing once a later one is out") {
        var s = LookState()
        let first = s.begin()
        _ = s.arrived(generation: first.generation)
        let second = s.begin()
        expect(s.giveUp(onLookOf: first.id), false)
        expect(s.inFlight, true, "the later look is still out")
        expect(s.accepts(generation: second.generation), true)
    }

    test("mouse tracking: a look that arrives after it was given up on is dropped") {
        var s = LookState()
        let look = s.begin()
        expect(s.giveUp(onLookOf: look.id), true)
        expect(s.inFlight, false)
        expect(s.arrived(generation: look.generation), false)
    }

    test("mouse tracking: stopping drops a look still out") {
        var s = LookState()
        let look = s.begin()
        s.stop()
        expect(s.inFlight, false)
        expect(s.arrived(generation: look.generation), false)
    }

    test("mouse tracking: a look that arrives in time leaves the watchdog nothing to give up on") {
        var s = LookState()
        let look = s.begin()
        expect(s.arrived(generation: look.generation), true)
        expect(s.inFlight, false)
        expect(s.giveUp(onLookOf: look.id), false)
        expect(s.accepts(generation: look.generation), true, "nothing was dropped")
    }
}
