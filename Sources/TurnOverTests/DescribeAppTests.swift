// SPDX-License-Identifier: GPL-3.0-or-later
// "Describe this app" and "What changed": the wording, the comparison of two snapshots, and the reading of a list.
import Foundation
import TurnOverCore
import AXFixtures

func describeAppTests() {
    func names(_ r: Range<Int>) -> [String] { r.map { "Message \($0)" } }
    let base = ListState(count: 30, head: Array(names(0..<4)), tail: Array(names(24..<30)))

    test("what changed: nothing moved is the same") {
        expect(WhatChanged.compare(base, base), .same)
        expect(WhatChanged.compare(base, ListState(count: 30, head: base.head.map { " " + $0.uppercased() }, tail: base.tail)), .same)
    }
    test("what changed: items that arrived at the top are counted and the newest is the first") {
        let now = ListState(count: 32, head: ["New B", "New A", "Message 0", "Message 1"], tail: base.tail)
        expect(WhatChanged.compare(base, now), .added(2, newest: "New B"))
    }
    test("what changed: items that arrived at the bottom are counted and the newest is the last") {
        let now = ListState(count: 31, head: base.head, tail: Array(names(25..<30)) + ["Tail X"])
        expect(WhatChanged.compare(base, now), .added(1, newest: "Tail X"))
    }
    test("what changed: more arrived than the kept words reach, the count says how many") {
        let now = ListState(count: 40, head: names(100..<104), tail: base.tail)
        expect(WhatChanged.compare(base, now), .added(10, newest: "Message 100"))
    }
    test("what changed: items that went, and items that were replaced") {
        let fewer = ListState(count: 28, head: base.head, tail: Array(names(20..<26)))
        expect(WhatChanged.compare(base, fewer), .removed(2))
        let swapped = ListState(count: 30, head: base.head, tail: Array(names(24..<29)) + ["Other"])
        expect(WhatChanged.compare(base, swapped), .changed(newest: "Other"))
    }
    test("what changed: a page not walked to its start is believed only by the words at its end") {
        let partial = ListState(count: 300, head: ["x"], tail: base.tail, complete: false)
        expect(WhatChanged.compare(partial, ListState(count: 300, head: ["y"], tail: base.tail, complete: false)), .same)
        let grown = ListState(count: 300, head: ["y"], tail: Array(names(26..<30)) + ["A", "B"], complete: false)
        expect(WhatChanged.compare(partial, grown), .added(2, newest: "B"))
    }
    test("what changed: how long ago is said in words") {
        expect(WhatChanged.agoText(10), "a moment ago")
        expect(WhatChanged.agoText(60), "1 minute ago")
        expect(WhatChanged.agoText(720), "12 minutes ago")
        expect(WhatChanged.agoText(3600), "1 hour ago")
        expect(WhatChanged.agoText(7200), "2 hours ago")
        expect(WhatChanged.agoText(86400 * 3), "3 days ago")
    }
    test("what changed: the sentences") {
        expect(WhatChanged.sentence(nil, ago: 0), "no earlier visit remembered")
        expect(WhatChanged.sentence(.same, ago: 720), "nothing new since you left, 12 minutes ago")
        expect(WhatChanged.sentence(.added(3, newest: "Lunch on Friday?"), ago: 0), "3 new items, newest: Lunch on Friday?")
        expect(WhatChanged.sentence(.added(1, newest: ""), ago: 0), "1 new item")
        expect(WhatChanged.sentence(.removed(2), ago: 0), "2 items fewer than when you left")
        expect(WhatChanged.sentence(.changed(newest: "Hi"), ago: 0), "changed since you left, newest: Hi")
        expect(WhatChanged.firstWords("one two three four five six seven eight nine ten"), "one two three four five six seven eight…")
    }
    test("what changed: the summary of the whole app names the parts that changed first") {
        expect(WhatChanged.appSummary([]), "no earlier visit remembered")
        let rows = [RegionChange(name: "Sidebar", change: .same, ago: 60), RegionChange(name: "Messages", change: .added(1, newest: "Hi"), ago: 60)]
        expect(WhatChanged.appSummary(rows), "Messages: 1 new item, newest: Hi. nothing new in Sidebar")
        expect(WhatChanged.appSummary([RegionChange(name: "Sidebar", change: .same, ago: 720)]), "nothing new anywhere since you left, 12 minutes ago")
    }
    test("what changed: the rows of a list are counted with the words of the ends") {
        AXReplay.load(memoryFixture(names: names(0..<30)))
        defer { AXReplay.unload() }
        guard let state = WhatChanged.state(of: AXReplay.element(2), part: nil, budget: 2) else { check(false, "no state"); return }
        expect(state.count, 30)
        expect(state.head, Array(names(0..<4)))
        expect(state.tail, Array(names(24..<30)))
        guard let fromWindow = WhatChanged.state(of: AXReplay.element(0), part: nil, budget: 2) else { check(false, "no state from the window"); return }
        expect(fromWindow, state, "the window's biggest list is the table")
    }
    test("what changed: a list read before and after shows what arrived") {
        AXReplay.load(memoryFixture(names: names(0..<30)))
        let before = WhatChanged.state(of: AXReplay.element(2), part: nil, budget: 2)
        AXReplay.unload()
        AXReplay.load(memoryFixture(names: ["New B", "New A"] + names(0..<30)))
        defer { AXReplay.unload() }
        let after = WhatChanged.state(of: AXReplay.element(2), part: nil, budget: 2)
        guard let before, let after else { check(false, "no state"); return }
        expect(WhatChanged.compare(before, after), .added(2, newest: "New B"))
    }

    test("describe app: the parts are numbered and the one you are in is said") {
        expect(DescribeApp.regionLines(regions: ["Sidebar", "Messages"], current: 1), ["1, Sidebar", "2, Messages, you are here"])
        expect(DescribeApp.regionLines(regions: [], current: nil), [])
    }
    test("describe app: the overview of an app with parts") {
        expect(DescribeApp.overview(app: "Teams", window: "Chat", kind: nil, regions: ["Sidebar", "Messages", "Compose"], current: 1, focus: "Reply, text field"),
               "Teams. window: Chat. 3 parts. 1, Sidebar. 2, Messages, you are here. 3, Compose")
        expect(DescribeApp.overview(app: "Teams", window: "Chat", kind: nil, regions: ["Sidebar", "Messages"], current: nil, focus: "Reply, text field"),
               "Teams. window: Chat. 2 parts. 1, Sidebar. 2, Messages. focus: Reply, text field")
    }
    test("describe app: the overview of an app without parts says the item you are on and the kind of window") {
        expect(DescribeApp.overview(app: "Notes", window: nil, kind: "dialog", regions: [], current: nil, focus: "Search, search field"),
               "Notes. dialog. focus: Search, search field")
        expect(DescribeApp.windowKind(role: "AXWindow", subrole: "AXDialog"), "dialog")
        check(DescribeApp.windowKind(role: "AXWindow", subrole: "AXStandardWindow") == nil, "an ordinary window has no kind")
    }
}
