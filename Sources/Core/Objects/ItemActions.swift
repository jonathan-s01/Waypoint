import AppKit
import ApplicationServices

/// Waypoint's actions menu (VO-Command-Space): everything that can be done to the item you are on, in one list the
/// arrows move through. The item's own actions come first, then its right-click menu, read through accessibility and
/// closed again, so a menu that ignores the arrows (the GitHub Copilot app's, 9 Nov 2026) still works. Choosing an
/// entry opens the menu again and presses it.
///
/// The item is the one you are on, however you got there: the text selection or caret in a field; the reading
/// position in a page read as a document; the item you arrowed to, or the selected row of a list; or where the
/// VoiceOver cursor was moved. A notification's Options button stands in for a menu it doesn't have.
@MainActor
public enum ItemActions {

    /// Sources of the item's menu, tried in turn until one opens.
    enum MenuSource {
        case showMenu(AXUIElement)
        case pressButton(AXUIElement)
        case rightClick(CGPoint)
    }

    struct Target {
        let element: AXUIElement
        let pid: pid_t
        var ownActions: [(owner: AXUIElement, action: String, title: String)] = []
        var buttons: [(element: AXUIElement, title: String)] = []
        var menuSources: [MenuSource] = []
        /// The menu of the list the item is in (Finder's New Folder, View, Sort By), listed after the item's own.
        var containerSources: [MenuSource] = []
    }

    struct Harvested { let title: String; let enabled: Bool; let submenu: Bool }

    /// While the menu opens and closes in the background, its focus moves and menu events are not said.
    private static var quietPid: pid_t = 0
    private static var quietUntil = Date.distantPast
    public static func isQuiet(_ pid: pid_t) -> Bool { pid == quietPid && Date() < quietUntil }
    private static func beQuiet(_ pid: pid_t) { quietPid = pid; quietUntil = Date().addingTimeInterval(3) }
    private static func endQuiet() { quietUntil = .distantPast }

    private static var generation = 0

    public static func open() {
        // A chat app's own message list keeps its own actions (WhatsApp, Messages).
        if GlobalCommands.contextMenuHandler?() == true { return }
        guard let target = resolve() else {
            Speech.speakMessage(String(localized: "No item to open a menu for", comment: "Spoken message")); return
        }
        generation += 1
        let gen = generation
        Log.io("actions: \(target.element.role), \(target.ownActions.count) own, \(target.buttons.count) buttons, \(target.menuSources.count) menu sources, \(target.containerSources.count) for its list")
        harvest(target.menuSources, pid: target.pid) { found, source in
            guard gen == generation else { return }
            harvest(target.containerSources, pid: target.pid) { general, generalSource in
                guard gen == generation else { return }
                show(target, menu: found, source: source, general: general, generalSource: generalSource)
            }
        }
    }

    // MARK: The item

    static func resolve() -> Target? {
        let nav = ObjectNavigator.shared
        // Text: the selection or caret, as a right click there opens the corrections and Cut, Copy, Paste.
        if let f = API.focusObject, isText(f.element), API.focusTreeInterceptor?.passThrough ?? true,
           let p = GlobalCommands.caretMenuPoint() {
            var t = Target(element: f.element, pid: f.pid)
            t.menuSources = [.rightClick(p)]
            return t
        }
        // A page read as a document: what is at the reading position.
        if let d = API.focusTreeInterceptor, !d.passThrough, nav.isWithin(d.webArea) {
            _ = d.refreshIfNavigated()
            if let at = (try? d.rootObject.makeTextInfo(.caret) as? BufferTextInfo)?.element(at: d.position) {
                return documentTarget(at, root: d.webArea)
            }
        }
        guard var e = nav.reviewElement ?? API.focusObject?.element, e.role != "?" else { return nil }
        // In a list, outline or table the item is the selected row, not the list (Finder, arrowed through).
        if listRoles.contains(e.role),
           let row = e.elements(kAXSelectedRowsAttribute).first ?? e.elements(kAXSelectedChildrenAttribute).first { e = row }
        var t = Target(element: e, pid: e.pid)
        t.ownActions = ownActions(of: e)
        t.menuSources = menuSources(for: e)
        if let list = containingList(of: e) { t.containerSources = [.showMenu(list)] }
        return t
    }

    private static let listRoles: Set<String> = ["AXOutline", "AXTable", "AXList", "AXBrowser"]

    /// The list, outline or table the item is in, when it has a menu of its own: Finder's icon view (an
    /// AXCollectionList) takes AXShowMenu for the folder's menu (probed 9 Nov 2026, macOS 27).
    static func containingList(of e: AXUIElement) -> AXUIElement? {
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 4, x.role != "AXWindow" {
            if listRoles.contains(x.role) {
                var names: CFArray?
                AXUIElementCopyActionNames(x, &names)
                return ((names as? [String]) ?? []).contains("AXShowMenu") ? x : nil
            }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    static func isText(_ e: AXUIElement) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(e.role) || e.string(kAXSubroleAttribute) == "AXSearchField"
    }

    private static let actionableRoles: Set<String> = ["AXLink", "AXButton", "AXImage", "AXTextField", "AXTextArea", "AXCheckBox",
                                                       "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXMenuButton"]
    private static let buttonRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton"]

    /// A link or control at the reading position is the item; otherwise the block of text, with the buttons that go
    /// with it (a chat message's Copy, Reply and the rest), which reading leaves out until asked for.
    static func documentTarget(_ at: AXUIElement, root: AXUIElement) -> Target {
        var e: AXUIElement? = at; var hops = 0
        while let x = e, hops < 6, !x.isSame(root) {
            if actionableRoles.contains(x.role) {
                var t = Target(element: x, pid: x.pid)
                t.ownActions = ownActions(of: x)
                t.menuSources = menuSources(for: x)
                return t
            }
            e = x.element(kAXParentAttribute); hops += 1
        }
        var block = at
        while ["AXStaticText", "AXInlineTextBox"].contains(block.role), let p = block.element(kAXParentAttribute), !p.isSame(root) { block = p }
        var t = Target(element: block, pid: block.pid)
        t.ownActions = ownActions(of: block)
        t.buttons = nearbyButtons(from: at, root: root)
        t.menuSources = menuSources(for: block)
        return t
    }

    /// The buttons of the nearest container that has a few: climbing from the text, the first ancestor holding 1 to
    /// 15 buttons is the message (more is the whole conversation, or the page).
    static func nearbyButtons(from at: AXUIElement, root: AXUIElement) -> [(element: AXUIElement, title: String)] {
        var e = at.element(kAXParentAttribute); var hops = 0
        while let x = e, hops < 8, !x.isSame(root) {
            if x.string(kAXSubroleAttribute)?.hasPrefix("AXLandmark") == true { return [] }
            let found = buttons(in: x)
            if found.count > 15 { return [] }
            if !found.isEmpty { return found }
            e = x.element(kAXParentAttribute); hops += 1
        }
        return []
    }

    private static func buttons(in root: AXUIElement) -> [(element: AXUIElement, title: String)] {
        var out: [(element: AXUIElement, title: String)] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]; var visited = 0
        while !queue.isEmpty, visited < 400, out.count <= 15 {
            let (x, depth) = queue.removeFirst(); visited += 1
            if buttonRoles.contains(x.role) {
                let name = title(of: x)
                if !name.isEmpty { out.append((x, name)) }
                continue
            }
            if depth < 6 { queue.append(contentsOf: x.elements(kAXChildrenAttribute).map { ($0, depth + 1) }) }
        }
        return out
    }

    private static let skippedActions: Set<String> = ["AXPress", "AXShowMenu", "AXCancel", "AXRaise", "AXConfirm", "AXPick",
                                                      "AXShowDefaultUI", "AXShowAlternateUI"]

    /// The item's actions and its parts' named ones (a notification's Close and Show, a message's reactions).
    static func ownActions(of e: AXUIElement) -> [(owner: AXUIElement, action: String, title: String)] {
        var found: [(owner: AXUIElement, action: String, title: String)] = []
        func collect(_ x: AXUIElement, _ depth: Int) {
            var names: CFArray?
            AXUIElementCopyActionNames(x, &names)
            for a in ((names as? [String]) ?? []) {
                let custom = a.components(separatedBy: "\n").first { $0.hasPrefix("Name:") }.map { String($0.dropFirst(5)).replacingOccurrences(of: "\u{200E}", with: "") }
                if custom == nil && (depth > 0 || a.hasPrefix("AXScroll") || skippedActions.contains(a)) { continue }
                var desc: CFString?
                AXUIElementCopyActionDescription(x, a as CFString, &desc)
                let t = custom ?? ((desc as String?).flatMap { $0.isEmpty ? nil : $0 } ?? a.replacingOccurrences(of: "AX", with: ""))
                if !found.contains(where: { $0.title.caseInsensitiveCompare(t) == .orderedSame }) { found.append((x, a, t)) }
            }
            if depth < 3 { for c in x.elements(kAXChildrenAttribute).prefix(40) { collect(c, depth + 1) } }
        }
        collect(e, 0)
        return found
    }

    /// Its own menu action; else an Options-style menu button inside it (a notification's); else a right click in
    /// its middle. Never a right click on a whole window or page, which would open whatever is under its centre.
    static func menuSources(for e: AXUIElement) -> [MenuSource] {
        var out: [MenuSource] = []
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        if ((names as? [String]) ?? []).contains("AXShowMenu") { out.append(.showMenu(e)) }
        // A part that fills the item and has the menu: Finder's icon inside the selected item's group. A right
        // click at the group's centre opened the folder's menu instead (9 Nov 2026, macOS 27).
        else if let part = fillingPartWithMenu(of: e) { out.append(.showMenu(part)) }
        var queue: [(AXUIElement, Int)] = e.elements(kAXChildrenAttribute).map { ($0, 1) }; var visited = 0
        while !queue.isEmpty, visited < 120 {
            let (x, depth) = queue.removeFirst(); visited += 1
            if ["AXMenuButton", "AXPopUpButton"].contains(x.role) { out.append(.pressButton(x)); break }
            if depth < 3 { queue.append(contentsOf: x.elements(kAXChildrenAttribute).map { ($0, depth + 1) }) }
        }
        if !["AXWindow", "AXWebArea", "AXScrollArea", "AXApplication", "AXSplitGroup"].contains(e.role),
           let f = TurnOverObject.frame(e), f.width > 0, f.height > 0, f.width * f.height < 900 * 700 {
            out.append(.rightClick(CGPoint(x: f.midX, y: f.midY)))
        }
        return out
    }

    static func fillingPartWithMenu(of e: AXUIElement) -> AXUIElement? {
        guard let f = TurnOverObject.frame(e), f.width > 0, f.height > 0 else { return nil }
        var queue: [(AXUIElement, Int)] = e.elements(kAXChildrenAttribute).prefix(20).map { ($0, 1) }
        while !queue.isEmpty {
            let (x, depth) = queue.removeFirst()
            var names: CFArray?
            AXUIElementCopyActionNames(x, &names)
            if ((names as? [String]) ?? []).contains("AXShowMenu"), let g = TurnOverObject.frame(x),
               g.width * g.height >= 0.5 * f.width * f.height { return x }
            if depth < 2 { queue.append(contentsOf: x.elements(kAXChildrenAttribute).prefix(20).map { ($0, depth + 1) }) }
        }
        return nil
    }

    static func title(of e: AXUIElement) -> String {
        for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let s = e.string(a)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        }
        return e.elements(kAXChildrenAttribute).prefix(4).compactMap { $0.string(kAXValueAttribute) ?? $0.string(kAXTitleAttribute) }
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The menu, opened in the background

    private static func trigger(_ s: MenuSource) {
        TurnOverObject.contextMenuRequestedAt = Date()
        switch s {
        case .showMenu(let e):
            AXUIElementSetMessagingTimeout(e, 0.3)   // a native menu's AXShowMenu waits for it to close (AGENTS.md: no long wait on main)
            let r = AXUIElementPerformAction(e, "AXShowMenu" as CFString)
            AXUIElementSetMessagingTimeout(e, 0)
            Log.io("actions: AXShowMenu on \(e.role) → \(r.rawValue)")
        case .pressButton(let b):
            AXUIElementSetMessagingTimeout(b, 0.3)
            let r = AXUIElementPerformAction(b, kAXPressAction as CFString)
            AXUIElementSetMessagingTimeout(b, 0)
            Log.io("actions: pressed the \(b.role) for its menu → \(r.rawValue)")
        case .rightClick(let p):
            Log.io("actions: right click at (\(Int(p.x)), \(Int(p.y)))")
            GlobalCommands.rightClick(at: p)
        }
    }

    /// The menu open in the app now: one macOS said opened, the focus on a menu item (a menu drawn in a web page), or
    /// a menu hanging off the app itself (a native context menu).
    static func openMenu(pid: pid_t) -> AXUIElement? {
        if let m = AXHandler.shared.openMenus.last(where: { $0.pid == pid && $0.role == "AXMenu" }) { return m }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        defer { AXUIElementSetMessagingTimeout(app, 0) }
        if let f = app.element(kAXFocusedUIElementAttribute), f.role == "AXMenuItem" {
            var p = f.element(kAXParentAttribute); var hops = 0
            while let x = p, hops < 3 { if x.role == "AXMenu" { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        }
        return app.elements(kAXChildrenAttribute).first { $0.role == "AXMenu" }
    }

    /// The menu's items, through the groups some pages put them in; separators (no title) left out.
    static func menuItems(_ menu: AXUIElement) -> [(element: AXUIElement, item: Harvested)] {
        var out: [(element: AXUIElement, item: Harvested)] = []
        func walk(_ x: AXUIElement, _ depth: Int) {
            for c in x.elements(kAXChildrenAttribute) {
                if c.role == "AXMenuItem" {
                    let t = title(of: c)
                    guard !t.isEmpty else { continue }
                    let submenu = c.elements(kAXChildrenAttribute).contains { $0.role == "AXMenu" }
                    out.append((c, Harvested(title: t, enabled: (c.attr(kAXEnabledAttribute) as? Bool) ?? true, submenu: submenu)))
                } else if depth < 3, c.role != "AXMenu" { walk(c, depth + 1) }
            }
        }
        walk(menu, 0)
        return out
    }

    /// Waits up to `limit` seconds for a menu, without holding up main.
    private static func waitForMenu(pid: pid_t, limit: TimeInterval, _ done: @escaping (AXUIElement?) -> Void) {
        let deadline = Date().addingTimeInterval(limit)
        func poll() {
            if let m = openMenu(pid: pid), !menuItems(m).isEmpty { done(m); return }
            if Date() >= deadline { done(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
    }

    /// Opens the menu from each source in turn until one opens, reads it, and closes it. Nothing found: no menu.
    private static func harvest(_ sources: [MenuSource], pid: pid_t, _ done: @escaping ([Harvested], MenuSource?) -> Void) {
        guard let first = sources.first else { done([], nil); return }
        beQuiet(pid)
        trigger(first)
        waitForMenu(pid: pid, limit: 0.45) { menu in
            guard let menu else {
                if sources.count > 1 { harvest(Array(sources.dropFirst()), pid: pid, done) } else { endQuiet(); done([], nil) }
                return
            }
            let found = menuItems(menu).map(\.item)
            Log.io("actions: the menu has \(found.count) items")
            close(menu, pid: pid) { endQuiet(); done(found, first) }
        }
    }

    private static func close(_ menu: AXUIElement, pid: pid_t, _ then: @escaping () -> Void) {
        _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            // A menu drawn in a web page takes no Cancel: Escape, sent to the app only.
            if openMenu(pid: pid) != nil {
                for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(pid) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if openMenu(pid: pid) == nil { AXHandler.shared.openMenus.removeAll { $0.pid == pid } }
                then()
            }
        }
    }

    // MARK: The list

    private static func show(_ t: Target, menu: [Harvested], source: MenuSource?, general: [Harvested], generalSource: MenuSource?) {
        var items: [MenuItem] = []
        var seen = Set<String>()
        func add(_ title: String, hint: String? = nil, _ run: @escaping () -> Void) {
            guard seen.insert(title.lowercased()).inserted else { return }
            items.append(MenuItem(verbatim: title, .action(run), hint: hint))
        }
        for a in t.ownActions { add(a.title) { _ = AXUIElementPerformAction(a.owner, a.action as CFString) } }
        for b in t.buttons { add(b.title) { _ = AXUIElementPerformAction(b.element, kAXPressAction as CFString) } }
        func addMenu(_ menu: [Harvested], from source: MenuSource?, whole: Bool) {
            let wholeList = String(localized: "whole list", comment: "After a menu item from the list's own menu, not the item's: Get Info, whole list")
            for (i, m) in menu.enumerated() {
                var title = m.title
                // The list's Get Info is the folder's, not the file's: said apart when both menus have it.
                if whole, seen.contains(title.lowercased()) { title += ", " + wholeList }
                if !m.enabled { title += ", " + String(localized: "dimmed", comment: "A menu item that can't be chosen now") }
                if m.submenu { title += ", " + String(localized: "submenu", comment: "A menu item that opens another menu") }
                add(title, hint: whole ? String(localized: "From the whole list's menu", comment: "Hint on a menu item from the list's menu, not the item's") : nil) {
                    guard m.enabled else { Speech.speakMessage(String(localized: "dimmed", comment: "A menu item that can't be chosen now")); return }
                    if let source { choose(m.title, index: i, from: source, pid: t.pid) }
                }
            }
        }
        addMenu(menu, from: source, whole: false)
        // Finder's list view gives the selected rows' menu for the list's own (9 Nov 2026, macOS 27): the same
        // menu again is not the list's.
        let mine = Set(menu.map { $0.title.lowercased() })
        let overlap = general.filter { mine.contains($0.title.lowercased()) }.count
        if !general.isEmpty, Double(overlap) < 0.6 * Double(general.count) { addMenu(general, from: generalSource, whole: true) }
        else if !general.isEmpty { Log.io("actions: the list's menu is the item's again; left out") }
        guard !items.isEmpty else { Speech.speakMessage(String(localized: "no actions", comment: "Spoken message")); return }
        TurnOverMenu.shared.openList("Actions", items: items)
    }

    /// The menu opened again and the item with that title pressed (the one at the same place, if two share it).
    private static func choose(_ title: String, index: Int, from source: MenuSource, pid: pid_t) {
        generation += 1
        let gen = generation
        // TurnOver's list has just closed, and the app's focus is coming back: let it settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard gen == generation else { return }
            beQuiet(pid)
            trigger(source)
            waitForMenu(pid: pid, limit: 0.8) { menu in
                endQuiet()
                guard gen == generation, let menu else {
                    Log.io("actions: the menu did not open again for \"\(Log.words(title))\"")
                    Speech.speakMessage(String(localized: "The menu didn't open", comment: "Spoken message")); return
                }
                let items = menuItems(menu)
                let match = (index < items.count && items[index].item.title == title) ? items[index] : items.first { $0.item.title == title }
                guard let match else {
                    Log.io("actions: \"\(Log.words(title))\" is no longer in the menu")
                    Speech.speakMessage(String(localized: "\(title) is no longer in the menu", comment: "Spoken message: a menu item's name"))
                    close(menu, pid: pid) {}
                    return
                }
                let r = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
                Log.io("actions: pressed \"\(Log.words(title))\" → \(r.rawValue)")
            }
        }
    }
}
