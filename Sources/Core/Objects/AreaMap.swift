// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint: the areas of any app window, worked out from its accessibility tree with no recipe. A pure classifier:
// a flat pre-order list of elements (role, name, frame) in, the areas out, each with the controls that belong to it.
// The walk that builds the list, and the keys, are in AreaMenu.swift.
//
// The model (agreed 2026): area 1 is Global (the app's own bars: top strips, rails, and every toolbar button); then the
// panes and the big bands (a ribbon, a status bar) in layout order; then a side panel (an inspector, Messages'
// details), last so the numbers of the others do not move when it comes and goes. A toolbar is never an area: each
// of its buttons goes to the pane whose column it sits over (Notes, Mail, Messages, 14 Nov 2026), and Global lists
// them all as well. Inside a pane, only toolbars and clusters of buttons (sheet tabs, a message's actions) are tools.
import Foundation
import CoreGraphics

nonisolated public struct AreaElement: Sendable {
    public var parent: Int
    public var role: String
    public var subrole: String
    public var name: String
    public var value: String
    public var frame: CGRect
    public init(parent: Int, role: String, subrole: String = "", name: String = "", value: String = "", frame: CGRect) {
        self.parent = parent; self.role = role; self.subrole = subrole; self.name = name; self.value = value; self.frame = frame
    }
}

nonisolated public struct Area: Sendable {
    public enum Kind: Sendable { case global, band, pane, side }
    public var name: String
    public var kind: Kind
    public var frame: CGRect
    /// The element to go to (nil for Global).
    public var element: Int?
    /// Indices of the tool controls, in layout order.
    public var tools: [Int]
}

nonisolated public enum AreaMap {
    public static let toolRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXComboBox", "AXSlider", "AXDisclosureTriangle", "AXIncrementor", "AXSearchField"]
    /// Where a walk goes no deeper: what is a control or a line of text, and what holds rows.
    public static let leafRoles: Set<String> = toolRoles.union(["AXStaticText", "AXImage", "AXValueIndicator", "AXLink", "AXHeading", "AXRow", "AXCell", "AXMenu", "AXMenuBar", "AXMenuItem", "AXColumn"])
    static let excludedContainers: Set<String> = ["AXRow", "AXCell", "AXTable", "AXOutline", "AXList", "AXMenu", "AXMenuBar", "AXMenuItem", "AXColumn"]
    static let paneRoles: Set<String> = ["AXOutline", "AXTable", "AXList", "AXWebArea", "AXTextArea", "AXScrollArea", "AXLayoutArea", "AXGrid", "AXBrowser"]

    public static let maxTools = 80
    public static let maxBandTools = 150

    // MARK: Words

    public static func kindWord(role: String, subrole: String) -> String {
        if subrole == "AXTabButton" { return "tab" }
        switch role {
        case "AXButton": return "button"
        case "AXMenuButton": return "menu button"
        case "AXPopUpButton": return "pop-up button"
        case "AXCheckBox": return "check box"
        case "AXRadioButton": return "radio button"
        case "AXTextField", "AXSearchField": return "text field"
        case "AXComboBox": return "combo box"
        case "AXSlider": return "slider"
        case "AXDisclosureTriangle": return "disclosure triangle"
        case "AXIncrementor": return "stepper"
        default: return "control"
        }
    }

    /// How a tool is read in the list: "Back, button", "Wrap text, check box, on".
    public static func label(_ e: AreaElement) -> String {
        var parts = [e.name, kindWord(role: e.role, subrole: e.subrole)]
        if !e.value.isEmpty, e.role != "AXButton", e.role != "AXMenuButton" {
            switch e.value {
            case "1": parts.append("on")
            case "0": parts.append("off")
            default: parts.append(e.value)
            }
        }
        return parts.joined(separator: ", ")
    }

    static func fallbackName(_ role: String) -> String {
        switch role {
        case "AXWebArea": return "Page"
        case "AXOutline", "AXTable", "AXList", "AXBrowser": return "List"
        case "AXTextArea": return "Text"
        case "AXGrid": return "Grid"
        default: return "Content"
        }
    }

    // MARK: Geometry

    static func overlap1D(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat { max(0, min(a1, b1) - max(a0, b0)) }

    /// The area (not Global) the point is in: the smallest whose frame holds it.
    public static func area(containing p: CGPoint, in areas: [Area]) -> Int? {
        var best: Int?
        for (i, a) in areas.enumerated() where a.kind != .global && a.frame.contains(p) {
            if best == nil || a.frame.width * a.frame.height < areas[best!].frame.width * areas[best!].frame.height { best = i }
        }
        return best
    }

    // MARK: Classifier

    private enum Mark { case toolbar, strip, global, rail, band(Int), side(Int), pane(Int) }

    public static func classify(_ els: [AreaElement], window: CGRect) -> [Area] {
        let n = els.count
        guard n > 0, window.width > 0, window.height > 0 else { return [Area(name: "Global", kind: .global, frame: window, element: nil, tools: [])] }
        let W = window.width, H = window.height
        var kids = [[Int]](repeating: [], count: n)
        for i in 0..<n { let p = els[i].parent; if p >= 0, p < i { kids[p].append(i) } }
        var end = [Int](repeating: 0, count: n)
        for i in 0..<n { end[i] = i + 1 }
        for i in stride(from: n - 1, through: 0, by: -1) { let p = els[i].parent; if p >= 0, p < i { end[p] = max(end[p], end[i]) } }

        var excluded = [Bool](repeating: false, count: n)
        for i in 0..<n { let p = els[i].parent; if p >= 0, p < i { excluded[i] = excluded[p] || excludedContainers.contains(els[p].role) } }
        func isTool(_ i: Int) -> Bool {
            let e = els[i]
            guard toolRoles.contains(e.role), !excluded[i], !e.name.isEmpty else { return false }
            let f = e.frame
            return f.width > 0 && f.height > 0 && f.width < W * 0.7 && f.intersects(window)
        }
        let tool = (0..<n).map(isTool)
        var count = [Int](repeating: 0, count: n)
        var bigBelow = [Bool](repeating: false, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            if tool[i] { count[i] += 1 }
            let p = els[i].parent
            guard p >= 0, p < i else { continue }
            count[p] += count[i]
            if (paneRoles.contains(els[i].role) && els[i].role != "AXScrollArea" && els[i].frame.height >= 100) || bigBelow[i] { bigBelow[p] = true }
        }

        var marks = [Mark?](repeating: nil, count: n)
        var covered = [Bool](repeating: false, count: n)
        var areas: [Area] = [Area(name: "Global", kind: .global, frame: window, element: nil, tools: [])]
        var sideAreas: [Int] = []
        func cover(_ i: Int) { for j in i..<end[i] { covered[j] = true } }

        var i = 0
        while i < n {
            let e = els[i], f = e.frame
            defer { i += 1 }
            guard !covered[i], f.width > 0, f.height > 0 else { continue }
            if e.role != "AXToolbar", sideAreas.isEmpty, f.maxX >= window.maxX - 4, f.height >= H * 0.7, f.width >= W * 0.12, f.width <= W * 0.35, count[i] >= 3 {
                areas.append(Area(name: e.name.isEmpty ? "Side panel" : e.name, kind: .side, frame: f.intersection(window), element: i, tools: []))
                sideAreas.append(areas.count - 1); marks[i] = .side(areas.count - 1); cover(i); continue
            }
            if e.role != "AXToolbar", f.width >= 48, f.width <= 100, f.height >= H * 0.6, count[i] >= 3 { marks[i] = .rail; cover(i); continue }
            if f.width >= W * 0.6, f.height <= 150, count[i] >= 2, !bigBelow[i] || e.role == "AXToolbar" {
                if e.role == "AXToolbar" { marks[i] = .toolbar }
                else if count[i] >= 12 {
                    areas.append(Area(name: e.name.isEmpty ? "Bar" : e.name, kind: .band, frame: f.intersection(window), element: i, tools: []))
                    marks[i] = .band(areas.count - 1)
                } else if f.minY - window.minY <= H * 0.15 { marks[i] = .global }
                else { marks[i] = .strip }
                cover(i); continue
            }
            if e.role == "AXToolbar" { marks[i] = .toolbar; cover(i); continue }
        }

        // Pane candidates: the outermost, unless it holds panes side by side (a web app's one big page).
        func isCandidate(_ i: Int) -> Bool {
            let e = els[i]
            guard !covered[i] else { return false }
            let f = e.frame.intersection(window)
            guard f.width >= 120, f.height >= 100 else { return false }
            if paneRoles.contains(e.role) { return true }
            return e.role == "AXGroup" && !e.name.isEmpty && f.width >= W * 0.15 && f.height >= H * 0.4
        }
        let candidates = (0..<n).filter(isCandidate)
        var dropped = Set<Int>()
        for c in candidates {
            let inner = candidates.filter { $0 > c && $0 < end[c] }
            guard inner.count >= 2 else { continue }
            outer: for a in inner { for b in inner where b > a {
                let fa = els[a].frame, fb = els[b].frame
                let shared = overlap1D(fa.minX, fa.maxX, fb.minX, fb.maxX)
                if shared < min(fa.width, fb.width) * 0.5 { dropped.insert(c); break outer }
            } }
        }
        var panes: [Int] = []
        var isPane = Set<Int>()
        for c in candidates where !dropped.contains(c) {
            var p = els[c].parent, inside = false
            while p >= 0 { if isPane.contains(p) { inside = true; break }; p = els[p].parent }
            if inside { continue }
            isPane.insert(c); panes.append(c)
        }

        var paneAreaIndex: [Int: Int] = [:]
        for c in panes {
            var name = els[c].name
            if name.isEmpty, let inner = (c + 1..<end[c]).first(where: { paneRoles.contains(els[$0].role) && !els[$0].name.isEmpty }) { name = els[inner].name }
            if name.isEmpty { name = fallbackName(els[c].role) }
            areas.append(Area(name: name, kind: .pane, frame: els[c].frame.intersection(window), element: c, tools: []))
            paneAreaIndex[c] = areas.count - 1
            marks[c] = .pane(areas.count - 1)
        }
        // A pane's frame can run under its neighbours (Messages' transcript spans the whole window): cut it back.
        let originals = areas.map(\.frame)
        for a in areas.indices where areas[a].kind == .pane {
            for b in areas.indices where b != a && (areas[b].kind == .pane || areas[b].kind == .side) {
                let fa = originals[a], fb = originals[b]
                guard fb.width * fb.height < fa.width * fa.height else { continue }
                guard overlap1D(fa.minX, fa.maxX, fb.minX, fb.maxX) > 0, overlap1D(fa.minY, fa.maxY, fb.minY, fb.maxY) >= fb.height * 0.5 else { continue }
                if fb.minX <= fa.minX + 2 { let right = areas[a].frame.maxX; areas[a].frame.origin.x = max(areas[a].frame.minX, fb.maxX); areas[a].frame.size.width = right - areas[a].frame.minX }
                else if fb.maxX >= fa.maxX - 2 { areas[a].frame.size.width = min(areas[a].frame.maxX, fb.minX) - areas[a].frame.minX }
            }
        }
        for a in areas.indices where areas[a].kind == .pane && areas[a].frame.width < 60 { areas[a].frame = .zero }
        let columns = areas.indices.filter { (areas[$0].kind == .pane || areas[$0].kind == .side) && areas[$0].frame.width >= 60 }
        let paneCount = columns.filter { areas[$0].kind == .pane }.count

        let soleWebPage = paneCount == 1 && columns.count == 1 && columns.first.flatMap { areas[$0].element }.map { els[$0].role == "AXWebArea" } == true

        // Which area owns a control that sits in a strip, a toolbar or loose.
        func geometric(_ i: Int, loose: Bool) -> Int {
            let f = els[i].frame, c = CGPoint(x: f.midX, y: f.midY)
            if let inside = columns.filter({ areas[$0].frame.contains(c) }).min(by: { areas[$0].frame.width * areas[$0].frame.height < areas[$1].frame.width * areas[$1].frame.height }) { return inside }
            if loose, f.minY - window.minY <= H * 0.15 { return 0 }
            // A page and nothing else (a browser): its toolbar is the app's, not the page's.
            if soleWebPage { return 0 }
            var best: (Int, CGFloat)?
            for a in columns {
                let af = areas[a].frame
                guard c.x >= af.minX, c.x <= af.maxX else { continue }
                let gap = c.y < af.minY ? af.minY - c.y : (c.y > af.maxY ? c.y - af.maxY : 0)
                if gap <= 100, best == nil || gap < best!.1 { best = (a, gap) }
            }
            return best?.0 ?? 0
        }

        var toolbarTools = Set<Int>()
        for t in 0..<n where tool[t] {
            var cur = els[t].parent
            var owner: Int?
            while cur >= 0 {
                if let m = marks[cur] {
                    switch m {
                    case .side(let a), .band(let a): owner = a
                    case .rail, .global: owner = 0
                    case .toolbar: toolbarTools.insert(t); owner = geometric(t, loose: false)
                    case .strip: owner = geometric(t, loose: false)
                    case .pane(let a):
                        let p = els[t].parent
                        let controls = kids[p].filter { tool[$0] }.count
                        if p >= 0, controls >= 2, Double(controls) >= Double(kids[p].count) * 0.6 { owner = a }
                    }
                    break
                }
                cur = els[cur].parent
            }
            if owner == nil, cur < 0 { owner = geometric(t, loose: true) }
            if let owner { areas[owner].tools.append(t) }
        }
        for t in toolbarTools where !areas[0].tools.contains(t) { areas[0].tools.append(t) }

        // Tools in layout order; the same control seen twice (Chrome's tree repeats its toolbar) once.
        for a in areas.indices {
            var seen = Set<String>()
            let ordered = areas[a].tools.sorted {
                let f = els[$0].frame, g = els[$1].frame
                let fy = Int(f.minY / 8), gy = Int(g.minY / 8)
                return fy != gy ? fy < gy : f.minX < g.minX
            }.filter { t in
                let f = els[t].frame
                return seen.insert("\(els[t].name)|\(els[t].role)|\(Int(f.minX / 4))|\(Int(f.minY / 4))").inserted
            }
            areas[a].tools = Array(ordered.prefix(areas[a].kind == .band ? maxBandTools : maxTools))
        }

        // Order: Global, then by layout (the top row first, left to right), the side panel last.
        let rest = areas.indices.dropFirst().filter { areas[$0].kind != .side && areas[$0].frame != .zero }
        let ordered = rest.sorted {
            let f = areas[$0].frame, g = areas[$1].frame
            let fy = Int((f.minY - window.minY) / (H * 0.25)), gy = Int((g.minY - window.minY) / (H * 0.25))
            if fy != gy { return fy < gy }
            return f.minX != g.minX ? f.minX < g.minX : f.minY < g.minY
        }
        var result = [areas[0]] + ordered.map { areas[$0] } + areas.indices.dropFirst().filter { areas[$0].kind == .side }.map { areas[$0] }
        // The same name twice: numbered, so the list and the jump keys can tell them apart.
        var seenNames: [String: Int] = [:]
        for k in result.indices {
            let base = result[k].name
            seenNames[base, default: 0] += 1
            if seenNames[base]! > 1 { result[k].name = "\(base) \(seenNames[base]!)" }
        }
        return result
    }

    /// The indices of records given with their parents (parents before children, as a level by level read gives
    /// them), in depth-first order with siblings as they came.
    public static func preOrder(parents: [Int]) -> [Int] {
        var kids = [[Int]](repeating: [], count: parents.count)
        var roots: [Int] = []
        for (i, p) in parents.enumerated() { if p >= 0 { kids[p].append(i) } else { roots.append(i) } }
        var order: [Int] = []
        var stack = roots.reversed() as [Int]
        while let i = stack.popLast() {
            order.append(i)
            stack.append(contentsOf: kids[i].reversed())
        }
        return order
    }

    /// A group of an area's controls, as the tools panel offers them: Left and Right go between groups.
    nonisolated public struct ToolGroup: Sendable {
        public var name: String
        public var tools: [Int]
        /// The tabs of a ribbon or a formatter: pressing one changes what the other groups hold.
        public var isTabs: Bool
    }

    static let clusterRoles: Set<String> = ["AXGroup", "AXToolbar", "AXRadioGroup", "AXTabGroup", "AXScrollArea", "AXSplitGroup"]

    /// The controls of an area split into the groups the app itself draws (14 Nov 2026, Excel's ribbon and Numbers' formatter):
    /// the tabs, then each cluster of controls (the smallest container holding at least two of them) in layout order, and
    /// what belongs to no cluster as "Other". A radio button in a tab group, or the first group of radio buttons when
    /// there is none, is a tab.
    public static func groups(of area: Area, in els: [AreaElement]) -> [ToolGroup] {
        let tools = area.tools
        guard !tools.isEmpty else { return [] }
        func chain(_ t: Int) -> [Int] {
            var out: [Int] = [], p = els[t].parent
            while p >= 0 {
                if clusterRoles.contains(els[p].role) { out.append(p) }
                p = els[p].parent
            }
            return out
        }
        var chains: [Int: [Int]] = [:]
        var counts: [Int: Int] = [:]
        for t in tools { let c = chain(t); chains[t] = c; for x in c { counts[x, default: 0] += 1 } }

        func parentRole(_ t: Int) -> String { els[t].parent >= 0 ? els[els[t].parent].role : "" }
        var tabs = Set(tools.filter { els[$0].role == "AXRadioButton" && (els[$0].subrole == "AXTabButton" || parentRole($0) == "AXTabGroup") })
        if tabs.isEmpty, let first = tools.first(where: { t in
            let p = els[t].parent
            return els[t].role == "AXRadioButton" && p >= 0 && els[p].role == "AXRadioGroup" && counts[p, default: 0] >= 2
        }) {
            tabs = Set(tools.filter { els[$0].role == "AXRadioButton" && els[$0].parent == els[first].parent })
        }

        var byKey: [Int: [Int]] = [:]
        var order: [Int] = []
        for t in tools {
            let key = tabs.contains(t) ? -2 : (chains[t]?.first { counts[$0, default: 0] >= 2 } ?? -1)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(t)
        }
        func position(_ key: Int) -> (Int, CGFloat, Int) {
            if key == -1 { return (Int.max, 0, 0) }
            let f = key == -2 ? els[byKey[key]![0]].frame : els[key].frame
            return (Int(f.minY / 8), f.minX, key)
        }
        let sorted = order.sorted { a, b in
            let pa = position(a), pb = position(b)
            return pa.0 != pb.0 ? pa.0 < pb.0 : (pa.1 != pb.1 ? pa.1 < pb.1 : pa.2 < pb.2)
        }
        var usedNames: [String: Int] = [:]
        return sorted.map { key in
            let members = byKey[key]!
            var name: String
            switch key {
            case -2: name = String(localized: "Tabs", comment: "A group of controls in the tools panel: the tabs of a ribbon or a formatter")
            case -1: name = String(localized: "Other", comment: "A group of controls in the tools panel: the ones that belong to no cluster")
            default:
                let own = els[key].name
                var first = els[members[0]].name
                while first.hasSuffix(":") { first.removeLast() }
                name = !own.isEmpty && own.count <= 30 ? own : String(localized: "\(first) group", comment: "A cluster of controls in the tools panel, named by its first control: %@ is that control's name")
            }
            usedNames[name, default: 0] += 1
            if usedNames[name]! > 1 { name += " \(usedNames[name]!)" }
            return ToolGroup(name: name, tools: members, isTabs: key == -2)
        }
    }

    /// An area to be moved around with arrows and Return whatever the app does with them: bars, ribbons, side panels
    /// full of controls. A list, text or page keeps its own keys and takes the focus instead.
    public static func isToolArea(_ area: Area) -> Bool {
        switch area.kind {
        case .global: return true
        case .band, .side: return !area.tools.isEmpty
        case .pane: return false
        }
    }
}
