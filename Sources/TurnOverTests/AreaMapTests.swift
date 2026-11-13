// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's areas (AreaMap): synthetic windows with the geometry and roles seen in Messages, Notes, Excel and a
// browser on 14 Nov 2026, and invented names (the recorded windows hold private mail and chats).
import Foundation
import CoreGraphics
import TurnOverCore

private struct Tree {
    var els: [AreaElement] = []
    @discardableResult mutating func add(_ parent: Int, _ role: String, _ name: String = "", _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, sub: String = "", value: String = "") -> Int {
        els.append(AreaElement(parent: parent, role: role, subrole: sub, name: name, value: value, frame: CGRect(x: x, y: y, width: w, height: h)))
        return els.count - 1
    }
    func names(_ areas: [Area], _ i: Int) -> [String] { areas[i].tools.map { els[$0].name } }
}

private func messages(details: Bool) -> (Tree, CGRect) {
    var t = Tree()
    let win = CGRect(x: 0, y: 0, width: 1024, height: 768)
    let w = t.add(-1, "AXWindow", "", 0, 0, 1024, 768)
    let split = t.add(w, "AXSplitGroup", "", 0, 0, 1024, 768)
    let bar = t.add(split, "AXToolbar", "", 0, 0, 1024, 52)
    t.add(bar, "AXButton", "Filter", 20, 10, 30, 30)
    t.add(bar, "AXButton", "Compose", 280, 10, 30, 30)
    t.add(bar, "AXButton", "Start FaceTime", 900, 10, 80, 30)
    if details { t.add(bar, "AXButton", "Close", 800, 10, 40, 30) }
    let list = t.add(split, "AXGroup", "Conversations", 0, 52, 320, 716)
    let find = t.add(split, "AXGroup", "", 0, 52, 320, 40)
    t.add(find, "AXTextField", "Search", 10, 60, 300, 28)
    let transcript = t.add(split, "AXGroup", "Messages", 0, 52, 1024, 616)
    t.add(transcript, "AXStaticText", "hello", 400, 100, 100, 20)
    let composer = t.add(split, "AXGroup", "", 320, 668, details ? 404 : 704, 100)
    t.add(composer, "AXButton", "add", 330, 700, 30, 30)
    t.add(composer, "AXTextField", "Message", 370, 700, details ? 250 : 400, 30)
    t.add(composer, "AXButton", "Record audio", details ? 680 : 780, 700, 30, 30)
    if details {
        let d = t.add(split, "AXGroup", "Details", 724, 0, 300, 768)
        for (i, n) in ["Request Location", "Call", "FaceTime", "Mail"].enumerated() { t.add(d, "AXButton", n, 740, CGFloat(100 + i * 40), 200, 30) }
    }
    return (t, win)
}

func areaMapTests() {
    test("areas: Messages is Global, the list and the transcript; toolbar buttons go to their columns") {
        let (t, win) = messages(details: false)
        let areas = AreaMap.classify(t.els, window: win)
        expect(areas.map(\.name), ["Global", "Conversations", "Messages"])
        expect(t.names(areas, 1), ["Filter", "Compose", "Search"])
        check(t.names(areas, 2).contains("Start FaceTime"), "the FaceTime button sits over the transcript")
        check(t.names(areas, 2).contains("Message"), "the message box belongs to the transcript's column")
        expect(t.names(areas, 0).sorted(), ["Compose", "Filter", "Start FaceTime"], "Global lists every toolbar button")
    }
    test("areas: Messages' details pane is the last area, and cuts the transcript back") {
        let (t, win) = messages(details: true)
        let areas = AreaMap.classify(t.els, window: win)
        expect(areas.map(\.name), ["Global", "Conversations", "Messages", "Details"])
        expect(areas[2].frame.minX, 320)
        expect(areas[2].frame.maxX, 724)
        expect(t.names(areas, 3).sorted(), ["Call", "Close", "FaceTime", "Mail", "Request Location", "Start FaceTime"])
        check(!t.names(areas, 2).contains("Close"), "and not to the transcript")
    }
    test("areas: Notes' toolbar is split by column and the list rows' controls are not tools") {
        var t = Tree()
        let win = CGRect(x: 0, y: 0, width: 1000, height: 660)
        let w = t.add(-1, "AXWindow", "", 0, 0, 1000, 660)
        let split = t.add(w, "AXSplitGroup", "", 0, 0, 1000, 660)
        let bar = t.add(split, "AXToolbar", "", 0, 0, 1000, 52)
        for (n, x) in [("Add Folder", 10), ("Toggle Sidebar", 40), ("View Options", 240), ("New Note", 400), ("Format", 500), ("Checklist", 560), ("Table", 600)] { t.add(bar, "AXButton", n, CGFloat(x), 10, 30, 30) }
        t.add(split, "AXOutline", "Folders", 0, 52, 228, 608)
        let table = t.add(split, "AXTable", "Notes", 228, 52, 243, 608)
        let row = t.add(table, "AXRow", "", 228, 60, 243, 40)
        t.add(row, "AXButton", "Pin", 300, 62, 20, 20)
        let scroll = t.add(split, "AXScrollArea", "", 471, 52, 529, 608)
        t.add(scroll, "AXTextArea", "Body", 471, 52, 529, 608)
        let areas = AreaMap.classify(t.els, window: win)
        expect(areas.map(\.name), ["Global", "Folders", "Notes", "Body"])
        expect(t.names(areas, 1), ["Add Folder", "Toggle Sidebar"])
        expect(t.names(areas, 2), ["View Options", "New Note"])
        expect(t.names(areas, 3), ["Format", "Checklist", "Table"])
        expect(areas[0].tools.count, 7)
        check(!areas.contains { a in a.tools.contains { t.els[$0].name == "Pin" } }, "a button inside a row is not a tool")
    }
    test("areas: a ribbon and a status bar are areas, the formula strip and sheet tabs go with the grid") {
        var t = Tree()
        let win = CGRect(x: 259, y: 110, width: 1402, height: 859)
        let w = t.add(-1, "AXWindow", "", 259, 110, 1402, 859)
        let top = t.add(w, "AXToolbar", "", 259, 110, 1402, 40)
        t.add(top, "AXButton", "Undo", 300, 115, 30, 30)
        t.add(top, "AXButton", "Save", 340, 115, 30, 30)
        let ribbon = t.add(w, "AXTabGroup", "ribbon", 259, 142, 1402, 105)
        for i in 0..<14 { t.add(ribbon, "AXButton", "Command \(i)", CGFloat(270 + i * 60), 190, 50, 40) }
        let strip = t.add(w, "AXGroup", "", 259, 246, 1402, 24)
        t.add(strip, "AXComboBox", "Name Box", 270, 248, 100, 20)
        t.add(strip, "AXButton", "Enter", 380, 248, 20, 20)
        let split = t.add(w, "AXSplitGroup", "", 259, 276, 1402, 665)
        let grid = t.add(split, "AXLayoutArea", "Content Area", 259, 276, 1402, 665)
        for (i, n) in ["Sheet1", "Sheet2", "New sheet"].enumerated() { t.add(grid, "AXRadioButton", n, CGFloat(270 + i * 70), 910, 60, 24) }
        let status = t.add(w, "AXGroup", "Status Bar", 259, 941, 1402, 28)
        t.add(status, "AXButton", "Zoom out", 1500, 945, 20, 20)
        t.add(status, "AXButton", "Zoom in", 1600, 945, 20, 20)
        let areas = AreaMap.classify(t.els, window: win)
        expect(areas.map(\.name), ["Global", "ribbon", "Content Area"])
        expect(areas[1].tools.count, 14)
        let gridTools = t.names(areas, 2)
        for n in ["Name Box", "Enter", "Sheet1", "Sheet2", "New sheet", "Zoom in", "Zoom out"] { check(gridTools.contains(n), "\(n) belongs to the grid") }
        expect(t.names(areas, 0), ["Undo", "Save"])
    }
    test("areas: a browser is Global and the page; the page's own buttons are not tools") {
        var t = Tree()
        let win = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w = t.add(-1, "AXWindow", "", 0, 0, 1440, 900)
        let bar = t.add(w, "AXToolbar", "", 0, 0, 1440, 80)
        t.add(bar, "AXButton", "Back", 10, 40, 30, 30)
        t.add(bar, "AXTextField", "Address and search", 200, 40, 600, 30)
        let page = t.add(w, "AXWebArea", "Inbox", 0, 80, 1440, 820)
        let g = t.add(page, "AXGroup", "", 100, 200, 600, 100)
        t.add(g, "AXButton", "Subscribe", 100, 200, 80, 30)
        for i in 0..<3 { t.add(g, "AXStaticText", "line \(i)", 100, 240, 80, 20) }
        let areas = AreaMap.classify(t.els, window: win)
        expect(areas.map(\.name), ["Global", "Inbox"])
        expect(t.names(areas, 0), ["Back", "Address and search"])
        expect(areas[1].tools.count, 0)
    }
    test("areas: a pane holding panes side by side gives way to them") {
        var t = Tree()
        let win = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let w = t.add(-1, "AXWindow", "", 0, 0, 1400, 900)
        let page = t.add(w, "AXWebArea", "App", 0, 0, 1400, 900)
        t.add(page, "AXOutline", "Chats", 0, 60, 400, 840)
        t.add(page, "AXGroup", "Message List", 400, 60, 1000, 700)
        let areas = AreaMap.classify(t.els, window: win)
        expect(areas.map(\.name), ["Global", "Chats", "Message List"])
    }
    test("areas: a control is read with its kind and state") {
        expect(AreaMap.label(AreaElement(parent: 0, role: "AXCheckBox", name: "Wrap text", value: "1", frame: .zero)), "Wrap text, check box, on")
        expect(AreaMap.label(AreaElement(parent: 0, role: "AXButton", name: "Back", frame: .zero)), "Back, button")
        expect(AreaMap.label(AreaElement(parent: 0, role: "AXRadioButton", subrole: "AXTabButton", name: "Home", frame: .zero)), "Home, tab")
    }
    test("areas: records read level by level are put into depth-first order") {
        // window(0) > [group(1) > [a(3), b(4)], bar(2) > [c(5)]]
        expect(AreaMap.preOrder(parents: [-1, 0, 0, 1, 1, 2]), [0, 1, 3, 4, 2, 5])
        expect(AreaMap.preOrder(parents: []), [])
    }
    test("areas: Mail's toolbar, last in its window, is Global; bars and side panels open as menus, panes take the focus") {
        var t = Tree()
        let win = CGRect(x: 0, y: 0, width: 1920, height: 1000)
        let w = t.add(-1, "AXWindow", "", 0, 0, 1920, 1000)
        let split = t.add(w, "AXSplitGroup", "Main Window", 0, 88, 1920, 912)
        let boxes = t.add(split, "AXScrollArea", "", 0, 88, 208, 912)
        t.add(boxes, "AXOutline", "Mailboxes", 0, 88, 208, 912)
        let list = t.add(split, "AXScrollArea", "", 208, 88, 400, 912)
        t.add(list, "AXTable", "Messages", 208, 88, 400, 912)
        let reading = t.add(split, "AXScrollArea", "message content", 608, 88, 1311, 912)
        for i in 0..<3 {
            let m = t.add(reading, "AXGroup", "", 608, CGFloat(88 + i * 300), 1311, 300)
            t.add(m, "AXWebArea", "", 608, CGFloat(120 + i * 300), 1311, 240)
            t.add(m, "AXButton", "Reply", 1700, CGFloat(90 + i * 300), 30, 24)
        }
        let bar = t.add(w, "AXGroup", "", 0, 0, 1920, 88)
        let tb = t.add(bar, "AXToolbar", "", 0, 0, 1920, 88)
        for (n, x) in [("Sidebar", 20), ("New Message", 700), ("Reply", 800), ("Delete", 900), ("Junk", 1000)] { t.add(tb, "AXButton", n, CGFloat(x), 20, 52, 52) }
        let areas = AreaMap.classify(t.els, window: win)
        check(t.names(areas, 0).contains("New Message"), "the toolbar is in Global")
        check(AreaMap.isToolArea(areas[0]), "Global opens as a menu")
        for a in areas where a.kind == .pane { check(!AreaMap.isToolArea(a), "\(a.name) keeps its own keys") }
    }
    test("groups: an Excel-shaped ribbon is its tabs, then each cluster, then what is left over") {
        var t = Tree()
        let win = CGRect(x: 0, y: 100, width: 1400, height: 880)
        let w = t.add(-1, "AXWindow", "", 0, 100, 1400, 880)
        let bar = t.add(w, "AXToolbar", "", 0, 124, 1400, 40)
        let quick = t.add(bar, "AXGroup", "", 80, 124, 1300, 40)
        for (n, x) in [("AutoSave", 90), ("Save", 190), ("Undo", 270)] { t.add(quick, "AXButton", n, CGFloat(x), 132, 26, 24) }
        t.add(quick, "AXTextField", "Search", 1100, 131, 280, 26)
        let ribbon = t.add(w, "AXTabGroup", "ribbon", 0, 156, 1400, 105)
        let scroll = t.add(ribbon, "AXScrollArea", "Home Tab Commands", 0, 190, 1400, 72)
        let clip = t.add(scroll, "AXGroup", "", 10, 190, 84, 72)
        for (n, y) in [("Paste", 190), ("Cut", 212), ("Copy", 234)] { t.add(clip, "AXMenuButton", n, 10, CGFloat(y), 40, 22) }
        let font = t.add(scroll, "AXGroup", "", 115, 190, 249, 72)
        t.add(font, "AXComboBox", "Font:", 115, 194, 143, 26, value: "Aptos")
        t.add(font, "AXCheckBox", "Bold", 115, 226, 26, 26, value: "0")
        t.add(font, "AXCheckBox", "Italic", 141, 226, 26, 26, value: "1")
        let sens = t.add(scroll, "AXGroup", "", 1200, 190, 57, 72)
        t.add(sens, "AXMenuButton", "Sensitivity", 1200, 190, 50, 74)
        for (n, x) in [("Home", 0), ("Insert", 60), ("Draw", 120)] { t.add(ribbon, "AXRadioButton", n, CGFloat(x), 157, 55, 26, value: n == "Home" ? "1" : "0") }
        t.add(ribbon, "AXButton", "Share", 1300, 159, 90, 26)
        let status = t.add(w, "AXGroup", "Status Bar", 0, 955, 1400, 28)
        let views = t.add(status, "AXRadioGroup", "", 1000, 954, 111, 30)
        for (n, x) in [("Normal", 1000), ("Page Layout", 1040), ("Page Break Preview", 1080)] { t.add(views, "AXRadioButton", n, CGFloat(x), 954, 36, 30) }
        t.add(w, "AXButton", "Enter", 390, 292, 26, 26)
        let areas = AreaMap.classify(t.els, window: win)
        let groups = AreaMap.groups(of: areas[0], in: t.els)
        let names = groups.map { $0.tools.map { t.els[$0].name } }
        let dump = zip(groups, names).map { "\($0.0.name)\($0.0.isTabs ? "*" : ""): \($0.1.joined(separator: ","))" }.joined(separator: " | ")
        expect(dump, "AutoSave group: AutoSave,Save,Undo,Search | Tabs*: Home,Insert,Draw | ribbon: Share | Home Tab Commands: Sensitivity | Paste group: Paste,Cut,Copy | Font group: Font:,Bold,Italic | Normal group: Normal,Page Layout,Page Break Preview | Other: Enter")
    }
    test("areas: an empty window is only Global") {
        expect(AreaMap.classify([], window: CGRect(x: 0, y: 0, width: 100, height: 100)).count, 1)
    }
}
