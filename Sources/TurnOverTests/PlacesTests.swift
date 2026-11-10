// SPDX-License-Identifier: GPL-3.0-or-later
// Places (Waypoint's bookmarks and recent places): naming, order, finding by typing, the file. All pure; going to a place
// and the recent list's gathering need a running app and are tried by ear (Places.swift).
import Foundation
import TurnOverCore

private func fingerprint(_ text: String, window: String = "inbox", row: Int = 3) -> FocusFingerprint {
    FocusFingerprint(windowTitle: window, nodes: [FocusNode(role: "AXScrollArea"), FocusNode(role: "AXRow", text: text, index: row)])
}

private func place(_ name: String, app: String = "Mail", bundle: String = "com.apple.mail", text: String? = nil, window: String = "inbox", row: Int = 3, created: Double = 1_700_000_000) -> PlaceRecord {
    PlaceRecord(name: name, bundleID: bundle, appName: app, fingerprint: fingerprint(text ?? name, window: window, row: row), id: "id-\(name)-\(app)", created: Date(timeIntervalSince1970: created))
}

func placesTests() {
    test("places: a name is the item's own words, spacing folded and kept short") {
        expect(PlacesLogic.autoName(text: "  Lunch   on\nFriday? ", axRole: "AXRow", windowTitle: "inbox", appName: "Mail"), "Lunch on Friday?")
        let long = "Quarterly budget review with the whole of the finance team and the external auditors on Thursday"
        let name = PlacesLogic.autoName(text: long, axRole: "AXRow", windowTitle: "", appName: "Mail")
        check(name.count <= PlacesLogic.nameLimit, "short enough")
        check(long.hasPrefix(name), "a start of the words")
        check(!name.hasSuffix(" "), "cut at a word")
        expect(name, "Quarterly budget review with the whole of the finance team", "the last whole word that fits")
    }
    test("places: with no words the name is the kind and where it is") {
        expect(PlacesLogic.autoName(text: "", axRole: "AXTextField", windowTitle: "new message", appName: "Mail"), "text field in new message")
        expect(PlacesLogic.autoName(text: "  ", axRole: "AXButton", windowTitle: "", appName: "Notes"), "button in Notes")
        expect(PlacesLogic.autoName(text: "", axRole: "AXTable", windowTitle: "", appName: ""), "table")
        expect(PlacesLogic.roleWords("AXPopUpButton"), "pop up button")
        expect(PlacesLogic.roleWords("?"), "item", "a role that could not be read")
    }
    test("places: a taken name gets a number") {
        expect(PlacesLogic.uniqueName("Inbox", among: ["Drafts"]), "Inbox")
        expect(PlacesLogic.uniqueName("Inbox", among: ["inbox"]), "Inbox 2", "case aside")
        expect(PlacesLogic.uniqueName("Inbox", among: ["Inbox", "Inbox 2"]), "Inbox 3")
    }
    test("places: bookmarking the same place again keeps its name and takes the new fingerprint") {
        let first = place("Lunch", row: 3)
        let list = PlacesLogic.upsert(first, into: []).list
        let again = place("Lunch on Friday?", text: "Lunch", row: 9)
        let result = PlacesLogic.upsert(again, into: list)
        expect(result.list.count, 1, "one bookmark")
        expect(result.saved.name, "Lunch", "the name it had")
        expect(result.saved.id, first.id, "the id it had")
        expect(result.saved.nodes.last?.index ?? -1, 9, "the row's new place")
    }
    test("places: the same name in one app is numbered, in another app it is not") {
        var list = PlacesLogic.upsert(place("Inbox", text: "a"), into: []).list
        let second = PlacesLogic.upsert(place("Inbox", text: "b"), into: list)
        expect(second.saved.name, "Inbox 2", "same app")
        list = second.list
        let other = PlacesLogic.upsert(place("Inbox", app: "Outlook", bundle: "com.microsoft.Outlook", text: "c"), into: list)
        expect(other.saved.name, "Inbox", "another app")
        expect(other.list.count, 3)
    }
    test("places: a bookmark without a bundle is the same app by name") {
        let a = place("Inbox", app: "Odd", bundle: "")
        check(PlacesLogic.sameApp(a, place("Other", app: "Odd", bundle: "")), "same name")
        check(!PlacesLogic.sameApp(a, place("Other", app: "Else", bundle: "")), "other name")
        check(!PlacesLogic.sameApp(a, place("Other", app: "Odd", bundle: "com.odd")), "one has a bundle")
    }
    test("places: the same place is the same element, whatever row it moved to") {
        check(place("Lunch", row: 3).isSamePlace(as: place("Lunch", row: 12)), "moved")
        check(!place("Lunch").isSamePlace(as: place("Dinner")), "other words")
        check(!place("Lunch").isSamePlace(as: place("Lunch", window: "sent")), "other window")
        check(!place("Lunch").isSamePlace(as: place("Lunch", app: "Outlook", bundle: "com.microsoft.Outlook")), "other app")
    }
    test("places: deleting removes the one bookmark") {
        let list = [place("A"), place("B"), place("C")]
        expect(PlacesLogic.removing(id: list[1].id, from: list).map(\.name), ["A", "C"])
        expect(PlacesLogic.removing(id: "nothing", from: list).count, 3)
    }
    test("places: bookmarks are listed by name, older first among equal names") {
        let list = [place("banana"), place("Apple", created: 2), place("Cherry"), place("apple", app: "Notes", bundle: "n", created: 1)]
        expect(PlacesLogic.sorted(list).map { "\($0.name)/\($0.appName)" }, ["apple/Notes", "Apple/Mail", "banana/Mail", "Cherry/Mail"])
    }
    test("places: a place counts after five seconds on it") {
        let t = Date(timeIntervalSince1970: 1_000)
        check(!PlacesLogic.dwelled(from: t, to: t.addingTimeInterval(4.9)), "passing through")
        check(PlacesLogic.dwelled(from: t, to: t.addingTimeInterval(5)), "stayed")
    }
    test("places: a newer visit moves to the front, once, and the list stays short") {
        expect(PlacesLogic.pushRecent(2, into: [1, 2, 3], limit: 5) { $0 == $1 }, [2, 1, 3])
        expect(PlacesLogic.pushRecent(9, into: [1, 2, 3], limit: 3) { $0 == $1 }, [9, 1, 2])
        expect(PlacesLogic.pushRecent(1, into: [], limit: 3) { $0 == $1 }, [1])
    }
    test("places: the recent places list each place once, newest first, without the place you are at") {
        let newest = place("Lunch", row: 5)
        let list = [newest, place("Dinner"), place("Lunch", row: 8), place("Notes", app: "Notes", bundle: "n"), place("Report")]
        let out = PlacesLogic.dedupe(list, excluding: place("Report"))
        expect(out.map(\.name), ["Lunch", "Dinner", "Notes"], "the first is the previous place")
        expect(out.first?.nodes.last?.index ?? -1, 5, "its newest visit")
        expect(PlacesLogic.dedupe(list, limit: 2).map(\.name), ["Lunch", "Dinner"], "limit")
    }
    test("places: the window with the title the place had is looked in first") {
        expect(PlacesLogic.windowOrder(titles: ["a", "inbox", "b", "inbox"], wanted: "inbox"), [1, 3, 0, 2])
        expect(PlacesLogic.windowOrder(titles: ["a", "b"], wanted: "gone"), [0, 1], "the others still tried")
        expect(PlacesLogic.windowOrder(titles: ["a", "b", "c", "d"], wanted: "d", limit: 2), [3, 0], "limit")
        expect(PlacesLogic.windowOrder(titles: [], wanted: "x"), [])
    }
    test("places: a typed query narrows by name, then by app or window") {
        let places = [place("Lunch on Friday?"), place("Budget", app: "Numbers", bundle: "n"), place("Friday lunch notes", app: "Notes", bundle: "no"), place("Summary", app: "Notes", bundle: "no", window: "friday")]
        let names = places.map(\.name)
        let others = places.map { PlacesLogic.otherWords(appName: $0.appName, windowTitle: $0.windowTitle) }
        func ask(_ q: String) -> [String] { PlacesLogic.filter(query: q, names: names, others: others).map { names[$0] } }
        expect(ask(""), names, "nothing typed: all, as given")
        expect(ask("friday"), ["Lunch on Friday?", "Friday lunch notes", "Summary"], "words in the name, then the window")
        expect(ask("lunch fri"), ["Lunch on Friday?", "Friday lunch notes"], "every word, any order")
        expect(ask("notes"), ["Friday lunch notes", "Summary"], "the name beats the app")
        expect(ask("numbers"), ["Budget"], "by app")
        expect(ask("xyz"), [], "nothing")
        expect(ask("budget"), ["Budget"], "a whole name")
    }
    test("places: the whole name comes before a longer name that starts with it") {
        let names = ["Inbox 2", "Inbox", "Inbox settings"]
        expect(PlacesLogic.filter(query: "inbox", names: names, others: ["", "", ""]).map { names[$0] }, ["Inbox", "Inbox 2", "Inbox settings"])
    }
    test("places: the previous place can be typed for, and is said first") {
        let list = [place("Report"), place("Lunch")]
        let others = list.enumerated().map { PlacesLogic.otherWords(appName: $1.appName, windowTitle: $1.windowTitle, previous: $0 == 0) }
        expect(PlacesLogic.filter(query: "previous", names: list.map(\.name), others: others), [0])
        expect(PlacesLogic.spokenTitle(name: "Report", appName: "Mail", previous: true), "previous place: Report, Mail")
        expect(PlacesLogic.spokenTitle(name: "Lunch", appName: "Mail"), "Lunch, Mail")
        expect(PlacesLogic.spokenTitle(name: "Lunch", appName: ""), "Lunch", "no app name")
    }
    test("places: a bookmark keeps its fingerprint through the record and back") {
        let fp = FocusFingerprint(windowTitle: "inbox", nodes: [FocusNode(role: "AXGroup", id: "list", text: "Inbox", index: 2), FocusNode(role: "AXRow", id: "", text: "Lunch", index: 7)])
        let record = PlaceRecord(name: "Lunch", bundleID: "com.apple.mail", appName: "Mail", fingerprint: fp)
        check(record.fingerprint == fp, "the same fingerprint")
        check(record.fingerprint.isUsable, "and usable")
    }
    test("places: the file round trips, in order, with ids and dates") {
        let list = [place("Lunch"), place("Notes", app: "Notes", bundle: "com.apple.Notes", text: "Shopping", created: 1_700_000_500)]
        guard let data = PlacesLogic.encode(list) else { check(false, "no data"); return }
        let back = PlacesLogic.decode(data)
        expect(back ?? [], list, "the same bookmarks")
        check((String(data: data, encoding: .utf8) ?? "").contains("\"version\" : 1"), "versioned")
    }
    test("places: a file that is not a places file is refused, so it is kept and not overwritten") {
        check(PlacesLogic.decode(Data("not json".utf8)) == nil, "garbage")
        check(PlacesLogic.decode(Data("{\"version\":2,\"bookmarks\":[]}".utf8)) == nil, "a later version")
        check(PlacesLogic.decode(Data("[]".utf8)) == nil, "another shape")
        expect(PlacesLogic.decode(Data("{\"version\":1,\"bookmarks\":[]}".utf8)) ?? [place("x")], [], "an empty list is a list")
    }
    test("places: a bookmark with nothing to find it by is left out when the file is read") {
        let empty = PlaceRecord(name: "Window", bundleID: "b", appName: "A", windowTitle: "w", nodes: [PlaceNode(role: "AXRow")])
        guard let data = PlacesLogic.encode([place("Lunch"), empty]) else { check(false, "no data"); return }
        expect(PlacesLogic.decode(data)?.map(\.name) ?? [], ["Lunch"])
    }
}
