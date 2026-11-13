// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint: the areas of any window, and the controls of each, with no recipe (AreaMap.swift decides what they are).
// Right Option 0 to 9 go to the areas (0 is Global: the app's own bars and every toolbar button, as a list); the
// Tools key lists the controls of the area you are in, as a menu, and pressed twice those of Global. Return uses a
// control (presses it, or puts the focus in a field); Escape closes the list and leaves the focus where it was.
// An app with a panes recipe (PanesAppModule) is gone to by its recipe's parts, with the same keys; Control Command and a number still work there too.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

public enum AreaMenu {
    struct Snapshot: Sendable {
        var elements: [AreaElement]
        var refs: [AXUIElement]
        var areas: [Area]
        var truncated: Bool
        var pid: pid_t
        /// Read for the second reader: what it does stays in the window it is reading and never moves the keyboard's focus.
        var second = false
    }

    private static let walkQueue = DispatchQueue(label: "turnover.areamenu", qos: .userInitiated)
    nonisolated private static let walkDeadline: TimeInterval = 2.5
    nonisolated private static let walkCap = 8000
    private static var generation = 0

    // MARK: The walk

    nonisolated private static func frame(of value: AnyObject?) -> CGRect {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return .zero }
        var r = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &r) ? r : .zero
    }

    nonisolated private static func text(_ value: AnyObject?) -> String {
        if let s = value as? String { return s.count > 60 ? String(s.prefix(60)) : s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    /// The tree under `root` as flat pre-order records. Off the main thread, with a deadline and a cap (Teams' tree is
    /// very deep, Logic's lists have a thousand rows); the rows of a list are not entered. It is read level by level,
    /// so when the cap or the deadline cuts it the app's bars (shallow) are in and the depths of a page are what is
    /// lost: read depth-first, Mail's message pages used the whole cap before its toolbar, last in its window, was reached
    /// (12 Nov 2026). The records are put into pre-order afterwards, which the classifier needs.
    nonisolated static func walk(root: AXUIElement) -> (elements: [AreaElement], refs: [AXUIElement], window: CGRect, truncated: Bool) {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute, "AXFrame", kAXChildrenAttribute]
        let started = Date()
        var elements: [AreaElement] = [], refs: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, -1)]
        var head = 0
        var window = CGRect.zero, truncated = false
        let noRows: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser"]
        while head < queue.count {
            if elements.count >= walkCap || Date().timeIntervalSince(started) > walkDeadline { truncated = true; break }
            let (e, parent) = queue[head]
            head += 1
            let a = e.attrs(names)
            let role = a[kAXRoleAttribute] as? String ?? "?"
            let sub = a[kAXSubroleAttribute] as? String ?? ""
            let f = frame(of: a["AXFrame"])
            if parent < 0 { window = f }
            var name = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute].lazy.compactMap { (a[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            if name.count > 80 { name = String(name.prefix(80)) }
            let value = AreaMap.toolRoles.contains(role) ? text(a[kAXValueAttribute]) : ""
            elements.append(AreaElement(parent: parent, role: role, subrole: sub, name: name, value: value, frame: f))
            refs.append(e)
            let index = elements.count - 1
            if AreaMap.leafRoles.contains(role) || noRows.contains(role) { continue }
            for k in (a[kAXChildrenAttribute] as? [AXUIElement]) ?? [] { queue.append((k, index)) }
        }
        let order = AreaMap.preOrder(parents: elements.map(\.parent))
        var newIndex = [Int](repeating: 0, count: elements.count)
        for (n, old) in order.enumerated() { newIndex[old] = n }
        let sorted = order.map { old -> AreaElement in
            var e = elements[old]
            if e.parent >= 0 { e.parent = newIndex[e.parent] }
            return e
        }
        return (sorted, order.map { refs[$0] }, window, truncated)
    }

    static func snapshot(pid: pid_t, second: Bool = false, done: @escaping @MainActor (Snapshot) -> Void) {
        var pid = pid
        let ax = AXUIElementCreateApplication(pid)
        var root = API.focusObject?.element.element(kAXWindowAttribute) ?? ax.element(kAXFocusedWindowAttribute) ?? ax.element(kAXMainWindowAttribute)
        if second, let w = ReviewLayer.windowAndPid() { root = w.window; pid = w.pid }
        // A sheet or a dialog on the window is the only area there is while it is up.
        if let w = root, let sheet = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXSheet" }) { root = sheet }
        guard let root else { Speech.speakMessage(String(localized: "no window", comment: "Spoken message: the app in front has no window")); return }
        generation += 1
        let mine = generation
        walkQueue.async {
            let w = walk(root: root)
            let areas = AreaMap.classify(w.elements, window: w.window)
            let snap = Snapshot(elements: w.elements, refs: w.refs, areas: areas, truncated: w.truncated, pid: pid, second: second)
            let summary = areas.map { "\($0.name) (\($0.kind), \($0.tools.count) tools)" }.joined(separator: "; ")
            Log.io("areas: \(w.elements.count) elements\(w.truncated ? ", cut short" : ""), \(areas.count) areas: \(summary)")
            onMain { if mine == generation { done(snap) } }
        }
    }

    // MARK: Using what the lists find

    /// Go to an area's element: the keyboard focus if it takes it, the rows of a list as a held list, otherwise the cursor.
    static func go(to e: AXUIElement, name: String, second: Bool = false, area: CGRect? = nil) {
        if second { ReviewLayer.jump(to: e, area: area); return }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue,
           e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success { Speech.speakMessage(name); return }
        if !e.elements(kAXRowsAttribute).isEmpty { ObjectNavigator.shared.enterHold(e, name: name, row: nil); return }
        Speech.speakMessage(name)
        ObjectNavigator.shared.focusMoved(to: e, pid: e.pid)
        ObjectNavigator.shared.reportCurrent()
    }

    /// Return on a control: fields take the focus; everything else is pressed (a press an app refuses but takes, as
    /// Excel's "rejected" did on 14 Nov 2026, still works); a control that cannot be pressed gets the focus.
    static func use(_ e: AXUIElement, role: String) {
        // A slider or stepper is adjusted with the arrows, so it takes the focus rather than a press.
        if ["AXTextField", "AXSearchField", "AXComboBox", "AXTextArea", "AXSlider", "AXIncrementor"].contains(role), e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success { return }
        if AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { return }
        if e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success { return }
        Speech.speakMessage(String(localized: "that control did not respond", comment: "Spoken message: a control in the tools list could not be pressed or focused"))
    }

    // MARK: Commands

    /// The area the focus is in (an index into the areas), nil when it cannot be told.
    private static func currentArea(_ snap: Snapshot) -> Int? {
        guard let at = snap.second ? ReviewLayer.cursorElement() : API.focusObject?.element, let r = TurnOverObject.frame(at), r.width > 0 || r.height > 0 else { return nil }
        return AreaMap.area(containing: CGPoint(x: r.midX, y: r.midY), in: snap.areas)
    }

    static func showTools(of index: Int, in snap: Snapshot) {
        let area = snap.areas[index]
        let title = String(localized: "\(area.name) tools", comment: "Title of the tools list: %@ is an area of the window")
        if area.tools.isEmpty {
            if index != 0 { Speech.speakMessage(String(localized: "no tools in \(area.name), so the global tools", comment: "Spoken message: %@ is an area of the window")); showTools(of: 0, in: snap) }
            else { Speech.speakMessage(String(localized: "no tools in this window", comment: "Spoken message")) }
            return
        }
        AreaPanel.open(title: title, areaIndex: index, in: snap)
    }

    static func tools(pid: pid_t, global: Bool, second: Bool = false) {
        snapshot(pid: pid, second: second) { snap in
            showTools(of: global ? 0 : (currentArea(snap) ?? 0), in: snap)
        }
    }

    /// An area key. `second`: the second reader goes there and the keyboard stays where it is.
    static func command(number n: Int, second: Bool) {
        guard var pid = API.focusPid, pid != ProcessInfo.processInfo.processIdentifier,
              !AXHandler.shared.isMenuOpen, !TurnOverMenu.shared.isOpen else { return }
        if second, let w = ReviewLayer.windowAndPid() { pid = w.pid }
        // An app with a panes recipe keeps its parts, numbered from 1; 0 is still the global area.
        if n > 0, let view = PanesView.current(pid: pid) {
            guard view.parts.indices.contains(n - 1) else {
                Speech.speakMessage(String(localized: "this window has \(view.parts.count) parts", comment: "Spoken message: %lld is how many parts"))
                return
            }
            if second { if let e = view.element(of: n - 1) { ReviewLayer.jump(to: e, area: TurnOverObject.frame(e)) } }
            else { view.go(to: n - 1) }
            return
        }
        jump(pid: pid, number: n, second: second)
    }

    static func jump(pid: pid_t, number: Int, second: Bool = false) {
        snapshot(pid: pid, second: second) { snap in
            guard snap.areas.indices.contains(number) else {
                Speech.speakMessage(String(localized: "this window has \(snap.areas.count) areas", comment: "Spoken message: %lld is how many areas"))
                return
            }
            let area = snap.areas[number]
            if AreaMap.isToolArea(area) { showTools(of: number, in: snap); return }
            guard let i = area.element else { showTools(of: 0, in: snap); return }
            go(to: snap.refs[i], name: area.name, second: second, area: area.frame)
        }
    }

    /// The biggest pane: where the content is, whatever the view.
    static func mainContent(pid: pid_t, second: Bool = false) {
        snapshot(pid: pid, second: second) { snap in
            let panes = snap.areas.filter { $0.kind == .pane }
            guard let best = panes.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }), let i = best.element else {
                Speech.speakMessage(String(localized: "no main content found", comment: "Spoken message")); return
            }
            go(to: snap.refs[i], name: best.name, second: second, area: best.frame)
        }
    }

    /// The first list, table or outline: a sidebar, the chats, the mailboxes.
    static func navigation(pid: pid_t, second: Bool = false) {
        snapshot(pid: pid, second: second) { snap in
            let lists: Set<String> = ["AXOutline", "AXTable", "AXList", "AXBrowser"]
            guard let area = snap.areas.first(where: { $0.kind == .pane && $0.element.map { lists.contains(snap.elements[$0].role) } == true }), let i = area.element else {
                Speech.speakMessage(String(localized: "no list found", comment: "Spoken message")); return
            }
            go(to: snap.refs[i], name: area.name, second: second)
        }
    }

    /// The window's search field: pressed, it takes the focus.
    static func search(pid: pid_t, second: Bool = false) {
        snapshot(pid: pid, second: second) { snap in
            let fields: Set<String> = ["AXSearchField", "AXTextField", "AXComboBox"]
            let found = snap.elements.indices.first { i in
                let e = snap.elements[i]
                return fields.contains(e.role) && (e.subrole == "AXSearchField" || e.role == "AXSearchField" || e.name.localizedCaseInsensitiveContains("search") || e.name.localizedCaseInsensitiveContains("find"))
            }
            guard let found else { Speech.speakMessage(String(localized: "no search field found", comment: "Spoken message")); return }
            if second { ReviewLayer.jump(to: snap.refs[found]); return }
            use(snap.refs[found], role: snap.elements[found].role)
            Speech.speakMessage(snap.elements[found].name)
        }
    }
}

/// Right Option 0 to 9 to the areas (0 is Global; the keys are in UserGestures.defaults), Tools, Main content, Search and Navigation, in any app, and the parts of a panes recipe (Teams, GitHub Copilot).
final class AreaMenuPlugin: GlobalPlugin {
    required init() {
        super.init()
        for n in 0...9 {
            let what = n == 0 ? String(localized: "Straight to the global area of the window: the app's own bars and toolbars, as a list", comment: "A command, as the key list and keyboard help say it")
                : String(localized: "Straight to part or area \(n) of the window (an app with a recipe, such as Teams, goes by its recipe's parts)", comment: "A command, as the key list and keyboard help say it: %lld is a number")
            // Always available, and the key never goes on to the app: Right Option keys are the user's keys (UserGestures),
            // which find a command by name and would type the character if it said no.
            script("area\(n)", what, category: "Waypoint") { g in
                AreaMenu.command(number: n, second: ReviewLayer.isSecond(g))
            }
        }
        script("areaTools", String(localized: "The controls of the area you are in, as a menu; pressed twice, those of the global area", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:turnover+option+o"], category: "Waypoint") { g in
            guard let pid = API.focusPid else { return }
            AreaMenu.tools(pid: pid, global: ScriptHandler.lastScriptRepeatCount > 0, second: ReviewLayer.isSecond(g))
        }.isAvailable = { API.focusPid != nil && !TurnOverMenu.shared.isOpen }
        script("areaMain", String(localized: "Straight to the main content of the window, whatever view the app is showing", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:turnover+option+m"], category: "Waypoint") { g in
            guard let pid = API.focusPid else { return }
            AreaMenu.mainContent(pid: pid, second: ReviewLayer.isSecond(g))
        }.isAvailable = { API.focusPid != nil && !TurnOverMenu.shared.isOpen }
        script("areaNavigation", String(localized: "Straight to the first list of the window: the sidebar, the chats, the mailboxes", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:turnover+option+a"], category: "Waypoint") { g in
            guard let pid = API.focusPid else { return }
            AreaMenu.navigation(pid: pid, second: ReviewLayer.isSecond(g))
        }.isAvailable = { API.focusPid != nil && !TurnOverMenu.shared.isOpen }
        script("areaSearch", String(localized: "Straight to the search field of the window", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:turnover+option+f"], category: "Waypoint") { g in
            guard let pid = API.focusPid else { return }
            AreaMenu.search(pid: pid, second: ReviewLayer.isSecond(g))
        }.isAvailable = { API.focusPid != nil && !TurnOverMenu.shared.isOpen }
    }
}
