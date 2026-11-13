// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func pointerReaderTests() {
    func snap(_ role: String, _ edit: (inout PointerSnapshot) -> Void = { _ in }) -> PointerSnapshot {
        var s = PointerSnapshot()
        s.axRole = role
        s.roleDescription = String(role.dropFirst(2)).lowercased()
        edit(&s)
        return s
    }

    test("pointer reader: a button is its name and role") {
        expect(PointerReader.compose(snap("AXButton") { $0.title = "Save" }), "Save, button")
    }

    test("pointer reader: a check box says its state, not its number") {
        expect(PointerReader.compose(snap("AXCheckBox") { $0.title = "Mute"; $0.number = 1; $0.value = "1" }), "Mute, checkbox, checked")
        expect(PointerReader.compose(snap("AXCheckBox") { $0.title = "Mute"; $0.number = 0 }), "Mute, checkbox, not checked")
    }

    test("pointer reader: a static text is just its value") {
        expect(PointerReader.compose(snap("AXStaticText") { $0.value = "Hello there" }), "Hello there")
    }

    test("pointer reader: a value that only repeats the name is not said twice") {
        expect(PointerReader.compose(snap("AXHeading") { $0.title = "Discover"; $0.value = "Discover" }), "Discover, heading")
        expect(PointerReader.compose(snap("AXSlider") { $0.title = "Volume"; $0.value = "50" }), "Volume, slider, 50")
    }

    test("pointer reader: a secure field's value is never spoken") {
        let s = snap("AXTextField") { $0.subrole = "AXSecureTextField"; $0.title = "Password"; $0.value = "hunter2"; $0.roleDescription = "secure text field" }
        let said = PointerReader.compose(s)
        expect(said, "Password, secure text field")
        check(!said.contains("hunter2"), "the password is not in what is said")
    }

    test("pointer reader: a group says how many items it holds") {
        let s = snap("AXToolbar") { $0.title = "Main"; $0.isGroup = true; $0.groupItemCount = 6 }
        expect(PointerReader.compose(s), "Main, toolbar, \(Phrases.items(6))")
    }

    test("pointer reader: a group not counted in time is said without a count") {
        let s = snap("AXToolbar") { $0.title = "Main"; $0.isGroup = true; $0.groupItemCount = nil }
        expect(PointerReader.compose(s), "Main, toolbar")
    }

    test("pointer reader: nothing to say falls back to the role word") {
        expect(PointerReader.compose(snap("AXImage")), "image")
    }
    test("pointer reader: a text inside a link or heading says so after its words") {
        expect(PointerReader.compose(snap("AXStaticText") { $0.value = "Discover"; $0.context = ["link"] }), "Discover, link")
        expect(PointerReader.compose(snap("AXStaticText") { $0.value = "News"; $0.context = [Phrases.headingLevel(2), "link"] }),
               "News, \(Phrases.headingLevel(2)), link")
        expect(PointerReader.compose(snap("AXImage") { $0.title = "Logo"; $0.context = ["link"] }), "Logo, image, link")
    }

    test("pointer reader: a heading is said with its level") {
        expect(PointerReader.compose(snap("AXHeading") { $0.title = "Discover"; $0.headingLevel = 2 }), "Discover, \(Phrases.headingLevel(2))")
        expect(PointerReader.compose(snap("AXHeading") { $0.title = "Discover" }), "Discover, heading")
    }

    test("pointer context: which elements above a text count") {
        expect(PointerContext.kind(role: "AXLink", subrole: "", named: false, distance: 3), .control)
        expect(PointerContext.kind(role: "AXHeading", subrole: "", named: false, distance: 1), .control)
        expect(PointerContext.kind(role: "AXCell", subrole: "", named: false, distance: 2), .container)
        expect(PointerContext.kind(role: "AXGroup", subrole: "AXListItem", named: false, distance: 2), .container)
        expect(PointerContext.kind(role: "AXGroup", subrole: "", named: true, distance: 1), .container)
        expect(PointerContext.kind(role: "AXGroup", subrole: "", named: true, distance: 2), .none)
        expect(PointerContext.kind(role: "AXGroup", subrole: "", named: false, distance: 1), .none)
        expect(PointerContext.kind(role: "AXScrollArea", subrole: "", named: true, distance: 1), .none)
    }

    test("pointer context: words for an element above a text") {
        expect(PointerContext.word(role: "AXHeading", subrole: "", roleDescription: "heading", headingLevel: 3), Phrases.headingLevel(3))
        expect(PointerContext.word(role: "AXLink", subrole: "", roleDescription: "link", headingLevel: nil), "link")
        expect(PointerContext.word(role: "AXButton", subrole: "", roleDescription: "", headingLevel: nil), "button")
    }

    test("pointer reader: a long text is cut at a word, never inside one") {
        expect(PointerReader.clip("one two three", limit: 100), "one two three")
        expect(PointerReader.clip("one two three", limit: 9), "one two")
        expect(PointerReader.clip("everything", limit: 5), "every")
        let long = String(repeating: "word ", count: 600)
        expect(PointerReader.clip(long), long)
        expect(PointerReader.clip(String(repeating: "word ", count: 6000)).count <= 20000, true)
    }
}
