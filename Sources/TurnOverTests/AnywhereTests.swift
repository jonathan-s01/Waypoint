// SPDX-License-Identifier: GPL-3.0-or-later
// Anywhere (Waypoint's command bar): which results a typed query finds, their order, which are risky, the second Return,
// recent use and which keys count as commands. All pure; the gathering of results is tried by ear (System/Anywhere.swift).
import Foundation
import TurnOverCore

private func entry(_ name: String, _ kind: AnywhereKind = .menuCommand, id: String? = nil, shortcut: String? = nil, place: String? = nil, enabled: Bool = true) -> AnywhereEntry {
    AnywhereEntry(id: id ?? "\(kind.rawValue):\(name)", name: name, kind: kind, shortcut: shortcut, place: place, enabled: enabled)
}

private func names(_ query: String, _ entries: [AnywhereEntry], recents: [String] = []) -> [String] {
    AnywhereRanking.rank(query: query, entries: entries, recents: recents).map { entries[$0].name }
}

func anywhereTests() {
    test("anywhere: an exact name comes before a prefix, a prefix before a word inside") {
        let e = [entry("Open Safari Settings"), entry("Safari Technology Preview", .app), entry("Safari", .app), entry("Unsafari")]
        expect(names("safari", e), ["Safari", "Safari Technology Preview", "Open Safari Settings", "Unsafari"], "exact name, name starting with it, word inside the name, inside a word")
    }
    test("anywhere: a prefix of a word matches, and case and accents are ignored") {
        let e = [entry("Café Menu", .app), entry("Close Window")]
        expect(names("cafe", e), ["Café Menu"], "accents folded")
        expect(names("CLO", e), ["Close Window"], "case folded")
    }
    test("anywhere: every typed word must match, in any order") {
        let e = [entry("Show Sidebar"), entry("Show Toolbar"), entry("Hide Sidebar")]
        expect(names("side show", e), ["Show Sidebar"], "both words")
        expect(names("sidebar", e).count, 2, "one word")
        expect(names("xyz", e), [], "nothing")
    }
    test("anywhere: the menu or kind a result is in can be typed, but ranks below the name") {
        let e = [entry("Copy", place: "Edit menu"), entry("Edit Profile", .app), entry("Paste", place: "Edit menu")]
        expect(names("edit", e).first ?? "", "Edit Profile", "the name beats the menu it is in")
        expect(names("edit", e).count, 3, "the menu's items are found by its name")
        expect(names("app", e), ["Edit Profile"], "the kind is searchable")
    }
    test("anywhere: recently used results come first within the same fit, and with nothing typed") {
        let e = [entry("Save", id: "a"), entry("Save As", id: "b"), entry("Save All", id: "c")]
        expect(names("sav", e), ["Save", "Save As", "Save All"], "nothing recent: shorter names first")
        expect(names("sav", e, recents: ["c"]).first ?? "", "Save All", "used recently, same fit as the others")
        expect(names("", e, recents: ["b", "c"]), ["Save As", "Save All", "Save"], "recents newest first, then the rest as given")
        expect(names("", e), ["Save", "Save As", "Save All"], "no recents: as given")
    }
    test("anywhere: a better fit still beats a recent worse one") {
        let e = [entry("Print", id: "p"), entry("Footprint", id: "f")]
        expect(names("print", e, recents: ["f"]).first ?? "", "Print", "an exact name over a recent substring")
    }
    test("anywhere: ties between kinds go to the item's own actions, then regions, apps, menus, commands") {
        let e = [entry("Press", .command, id: "5"), entry("Press", .menuCommand, id: "4"), entry("Press", .app, id: "3"), entry("Press", .region, id: "2"), entry("Press", .action, id: "1")]
        expect(AnywhereRanking.rank(query: "press", entries: e, recents: []).map { e[$0].kind }, [.action, .region, .app, .menuCommand, .command])
    }
    test("anywhere: risky commands are found by whole words") {
        for name in ["Delete", "Delete Message…", "Erase Disk", "Empty Trash…", "Quit Safari", "Log Out Jonathan…", "Shut Down…", "Restart…", "Format Disk", "Move to Trash and Delete"] {
            check(AnywhereRanking.isRisky(name: name, kind: .menuCommand), "\(name) is risky")
        }
        for name in ["Reformat", "Formatted Text", "Deleted Items", "Trash", "Logout Settings", "Quite Good", "Show Sidebar", "Empty Cell"] {
            check(!AnywhereRanking.isRisky(name: name, kind: .menuCommand), "\(name) is not risky")
        }
        check(AnywhereRanking.isRisky(name: "Format", kind: .command), "a Waypoint command too")
        check(AnywhereRanking.isRisky(name: "Delete", kind: .action), "an item's action too")
        check(!AnywhereRanking.isRisky(name: "Quit", kind: .app), "an app only takes you there")
        check(!AnywhereRanking.isRisky(name: "Delete", kind: .region), "a part of the window only takes you there")
    }
    test("anywhere: the second Return confirms the same result within the window only") {
        let t = Date(timeIntervalSince1970: 1_000)
        check(AnywhereRanking.isConfirmation(pendingID: "x", pendingAt: t, id: "x", now: t.addingTimeInterval(2)), "same result, soon")
        check(!AnywhereRanking.isConfirmation(pendingID: "x", pendingAt: t, id: "x", now: t.addingTimeInterval(6)), "too late")
        check(!AnywhereRanking.isConfirmation(pendingID: "x", pendingAt: t, id: "y", now: t.addingTimeInterval(1)), "another result")
        check(!AnywhereRanking.isConfirmation(pendingID: nil, pendingAt: nil, id: "x", now: t), "nothing pending")
    }
    test("anywhere: recent use moves to the front, once, and the list stays short") {
        expect(AnywhereRanking.recordRecent("b", in: ["a", "b", "c"]), ["b", "a", "c"])
        expect(AnywhereRanking.recordRecent("z", in: ["a", "b"]), ["z", "a", "b"])
        let many = (0..<20).map { "id\($0)" }
        let out = AnywhereRanking.recordRecent("new", in: many)
        expect(out.count, 12, "limit")
        expect(out.first ?? "", "new")
    }
    test("anywhere: said as the name, the kind, the shortcut, then dimmed") {
        expect(AnywhereRanking.spokenTitle(entry("Safari", .app)), "Safari, app")
        expect(AnywhereRanking.spokenTitle(entry("New Folder", .menuCommand, shortcut: "shift command N")), "New Folder, menu command, shift command N")
        expect(AnywhereRanking.spokenTitle(entry("Paste", .menuCommand, shortcut: "command V", enabled: false)), "Paste, menu command, command V, dimmed")
        expect(AnywhereRanking.spokenTitle(entry("Sidebar", .region)), "Sidebar, region")
    }
    test("anywhere: only keys with a modifier are commands") {
        check(AnywhereRanking.isChord("kb:turnover+command+a"), "a VoiceOver chord")
        check(AnywhereRanking.isChord("kb:control+command+1"), "control command 1")
        check(AnywhereRanking.isChord("kb:command+shift+n"), "command shift n")
        check(!AnywhereRanking.isChord("kb:a"), "a letter")
        check(!AnywhereRanking.isChord("kb:downArrow"), "an arrow")
        check(!AnywhereRanking.isChord("kb:shift+tab"), "shift alone")
        check(!AnywhereRanking.isChord("nonsense"), "no key")
    }
    test("anywhere: a name's own spaces and punctuation do not matter") {
        let e = [entry("Open Recent…"), entry("Save As…")]
        expect(names("open recent", e), ["Open Recent…"])
        expect(names("save as", e), ["Save As…"])
        expect(names("   ", e), ["Open Recent…", "Save As…"], "only spaces: nothing typed")
    }
}
