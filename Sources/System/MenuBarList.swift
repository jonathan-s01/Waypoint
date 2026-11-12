import AppKit
import ApplicationServices

/// Waypoint's menu bar (VO-M): the front app's menus in TurnOver's own list, read through accessibility. Right or
/// Enter opens a menu, Left goes back, a letter jumps to the next item starting with it at every level, and
/// VO-F searches every item in every menu. Choosing an item presses it and the list closes. VO-M again (quickly)
/// gives the status menus, and a third time the app's real menu bar.
@MainActor
public enum MenuBarList {

    private static var lastPressAt = Date.distantPast
    private static var presses = 0

    private static var withinRepeat: Bool {
        Date().timeIntervalSince(lastPressAt) * 1000 <= Double(config.keyboard.multiPressTimeoutMs)
    }

    /// VO-M with the list closed.
    public static func pressed() {
        if AXHandler.shared.isMenuOpen { GlobalCommands.toggleMenus(); return }
        if MenuNavigationPlugin.heldBar != nil {
            MenuNavigationPlugin.releaseBar(); Braille.releaseItem()
            // The third press: the app's real menu bar, as before Waypoint.
            if presses == 2, withinRepeat { presses = 3; lastPressAt = Date(); MenuNavigationPlugin.holdMenuBar(); return }
            if let pid = API.focusPid { MenuNavigationPlugin.backFromBar(pid: pid) }
            presses = 0
            return
        }
        presses = 1; lastPressAt = Date()
        open()
    }

    static func open() {
        guard let pid = API.focusPid, let items = barItems(pid: pid) else { Tones.edge(); return }
        TurnOverMenu.shared.openList(verbatim: barListTitle, items: items)
        TurnOverMenu.shared.keyHook = { g in key(g, pid: pid) }
        Hints.schedule(String(localized: "Right opens a menu, letters jump, VO F searches every menu.", comment: "Spoken message"))
    }

    /// Keys the list does not have: VO-F (in the search results, TurnOverMenu's own VO-F switches between typing and
    /// jumping by letter), and VO-M pressed again.
    private static func key(_ g: KeyboardGesture, pid: pid_t) -> Bool {
        if g.modifiers == [.turnover], g.keyName.lowercased() == "f", !TurnOverMenu.shared.isFiltering { search(pid: pid); return true }
        if g.modifiers == [.turnover], g.keyName.lowercased() == "m" {
            TurnOverMenu.shared.close()
            if withinRepeat, presses == 1 {
                presses = 2; lastPressAt = Date()
                if config.general.windowsKeys { StatusMenus.openList() } else { MenuNavigationPlugin.holdStatusItems() }
            } else { presses = 0 }
            return true
        }
        return false
    }

    private static var barListTitle: String { String(localized: "Menu bar", comment: "Waypoint's list of the app's menus") }

    /// The app's menus as list items, nil when it has no menu bar.
    private static func barItems(pid: pid_t) -> [MenuItem]? {
        guard let bar = AXUIElementCreateApplication(pid).element(kAXMenuBarAttribute) else { return nil }
        let menus = bar.elements(kAXChildrenAttribute)
        guard !menus.isEmpty else { return nil }
        return menus.enumerated().compactMap { i, m in
            let name = barTitle(m, index: i)
            guard let menu = m.elements(kAXChildrenAttribute).first(where: { $0.role == "AXMenu" }) else { return nil }
            return MenuItem(verbatim: name, .submenu { entries(of: menu) })
        }
    }

    private static var submenuWord: String { String(localized: "submenu", comment: "A menu item that opens another menu") }

    static func barTitle(_ m: AXUIElement, index: Int) -> String {
        if let t = m.string(kAXTitleAttribute), !t.isEmpty { return t }
        return index == 0 ? "Apple" : Role.menu.displayString
    }

    /// A menu item as read in one question to the app (a menu's items took about six each before, 12 Nov 2026).
    struct Info {
        let element: AXUIElement
        let title: String
        let spoken: String
        let shortcut: String?
        let enabled: Bool
        let submenu: AXUIElement?
    }

    private static let itemAttributes = [kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute,
                                         "AXMenuItemMarkChar", "AXMenuItemCmdChar", "AXMenuItemCmdModifiers"]

    /// The items of a menu with a title; separators and empty items left out.
    static func infos(of menu: AXUIElement) -> [Info] {
        menu.elements(kAXChildrenAttribute).compactMap { c -> Info? in
            let a = c.attrs(itemAttributes)
            guard (a[kAXRoleAttribute] as? String) == "AXMenuItem" else { return nil }
            let title = ((a[kAXTitleAttribute] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let enabled = (a[kAXEnabledAttribute] as? Bool) != false
            let sub = ((a[kAXChildrenAttribute] as? [AXUIElement]) ?? []).first { $0.role == "AXMenu" }
            let keys = shortcut(char: a["AXMenuItemCmdChar"] as? String, modifiers: (a["AXMenuItemCmdModifiers"] as? NSNumber)?.intValue)
            var parts = [title]
            if let m = markWord(a["AXMenuItemMarkChar"] as? String) { parts.append(m) }
            if let sc = keys { parts.append(sc) }
            if !enabled { parts.append(String(localized: "dimmed", comment: "A menu item that can't be chosen now")) }
            return Info(element: c, title: title, spoken: parts.joined(separator: ", "), shortcut: keys, enabled: enabled, submenu: sub)
        }
    }

    /// A menu's items: separators left out, submenus opening as lists.
    static func entries(of menu: AXUIElement) -> [MenuItem] {
        let started = Date()
        let list = infos(of: menu).map { i -> MenuItem in
            if let sub = i.submenu { return MenuItem(verbatim: i.title + ", " + submenuWord, .submenu { entries(of: sub) }) }
            return MenuItem(verbatim: i.spoken, .action { press(i.element, title: i.title) })
        }
        Log.io("menu bar: \(list.count) items read in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return list
    }

    /// A menu item's mark: a tick is checked, a bullet is the chosen one of a group, a dash is mixed.
    nonisolated public static func markWord(_ mark: String?) -> String? {
        guard let m = mark?.trimmingCharacters(in: .whitespaces), !m.isEmpty else { return nil }
        switch m {
        case "•", "◦": return String(localized: "selected", comment: "A menu item that is the chosen one of its group")
        case "-", "–", "—": return String(localized: "mixed", comment: "A menu item that is on for some of the selection")
        default: return String(localized: "checked", comment: "A menu item that is turned on")
        }
    }

    /// Spoken as TurnOver says a menu item's shortcut (TurnOverObject.keyboardShortcut).
    nonisolated public static func shortcut(char: String?, modifiers: Int?) -> String? {
        guard let ch = char, !ch.isEmpty else { return nil }
        let mods = modifiers ?? 0
        var parts: [String] = []
        if mods & 4 != 0 { parts.append("control") }
        if mods & 2 != 0 { parts.append("option") }
        if mods & 1 != 0 { parts.append("shift") }
        if mods & 8 == 0 { parts.append("command") }
        parts.append(ch.count == 1 && ch.first!.isLetter ? ch.uppercased() : ch)
        return parts.joined(separator: " ")
    }

    private static func press(_ item: AXUIElement, title: String) {
        if (item.attr(kAXEnabledAttribute) as? Bool) == false {
            Speech.speakMessage(String(localized: "dimmed", comment: "A menu item that can't be chosen now")); return
        }
        AXUIElementSetMessagingTimeout(item, 0.5)
        let r = AXUIElementPerformAction(item, kAXPressAction as CFString)
        AXUIElementSetMessagingTimeout(item, 0)
        Log.io("menu bar: pressed \"\(Log.words(title))\" → \(r.rawValue)")
        if r != .success, r != .cannotComplete { Speech.speakMessage(String(localized: "\(title) didn't respond", comment: "Spoken message: a menu item's name")) }
    }

    // MARK: Search

    /// One item found by walking every menu: what the search lists, and what Anywhere ranks.
    struct Found {
        let title: String
        let spoken: String
        let path: [String]
        let shortcut: String?
        let enabled: Bool
        /// The menu it is in, as the search says it after a pause.
        let place: String
        let press: () -> Void
        /// Set for a submenu: opens the list inside its parents (a submenu has nothing to press).
        var reveal: (() -> Void)? = nil
    }

    /// Every item in every menu, nil when the app has no menu bar.
    static func allItems(pid: pid_t, budget: TimeInterval = 1.5) -> [Found]? {
        guard let bar = AXUIElementCreateApplication(pid).element(kAXMenuBarAttribute) else { return nil }
        var found: [Found] = []
        // A bounded walk on main (AGENTS.md): Xcode's menus are the largest seen; this stops at 4000 items or the budget.
        let deadline = Date().addingTimeInterval(budget)
        func walk(_ menu: AXUIElement, path: [String], chain: [(title: String, menu: AXUIElement)], depth: Int) {
            for i in infos(of: menu) {
                guard found.count < 4000, Date() < deadline else { return }
                let title = i.title
                let where_ = path.count == 1 ? String(localized: "\(path[0]) menu", comment: "Where a found menu item is: %@ is the menu (File)") : path.joined(separator: ", ")
                if let sub = i.submenu {
                    found.append(Found(title: title, spoken: title + ", " + submenuWord, path: path, shortcut: nil,
                                       enabled: i.enabled, place: where_, press: {},
                                       reveal: { reveal(pid: pid, chain: chain, title: title, menu: sub) }))
                    if depth < 4 { walk(sub, path: path + [title], chain: chain + [(title, sub)], depth: depth + 1) }
                    continue
                }
                let c = i.element
                found.append(Found(title: title, spoken: i.spoken, path: path, shortcut: i.shortcut,
                                   enabled: i.enabled, place: where_, press: { press(c, title: title) }))
            }
        }
        for (i, m) in bar.elements(kAXChildrenAttribute).enumerated() {
            guard let menu = m.elements(kAXChildrenAttribute).first(where: { $0.role == "AXMenu" }) else { continue }
            let name = barTitle(m, index: i)
            walk(menu, path: [name], chain: [(name, menu)], depth: 1)
        }
        return found
    }

    /// Every item in every menu, narrowed as you type: the name and shortcut, then after a pause the menu it is in.
    private static func search(pid: pid_t) {
        guard let all = allItems(pid: pid) else { Tones.edge(); return }
        // A submenu result opens its list inside its parents (Enter or Right) and stays in the menu; any other item runs and closes.
        let found = all.map { f -> MenuItem in
            var item = MenuItem(verbatim: f.spoken, f.reveal.map { MenuItem.Kind.select($0) } ?? .action(f.press), hint: f.place)
            item.onRight = f.reveal
            return item
        }
        Log.io("menu bar: search over \(found.count) items")
        let hook = TurnOverMenu.shared.keyHook
        TurnOverMenu.shared.openChooser(verbatim: String(localized: "Search menus", comment: "Waypoint's search of every menu item"), items: found)
        TurnOverMenu.shared.keyHook = hook
    }

    /// A submenu found by search, opened as the menu bar list would have it: the bar, each menu down to it with the
    /// item on its way selected, then its own items. Left goes back up through the menus it is in.
    private static func reveal(pid: pid_t, chain: [(title: String, menu: AXUIElement)], title: String, menu: AXUIElement) {
        guard let bar = barItems(pid: pid) else { Tones.edge(); return }
        var levels: [(title: String, items: [MenuItem], index: Int)] = [(barListTitle, bar, bar.firstIndex { $0.title == chain[0].title } ?? 0)]
        for (i, level) in chain.enumerated() {
            let items = entries(of: level.menu)
            let next = (i + 1 < chain.count ? chain[i + 1].title : title) + ", " + submenuWord
            levels.append((level.title, items, items.firstIndex { $0.title == next } ?? 0))
        }
        levels.append((title, entries(of: menu), 0))
        Log.io("menu bar: search opened the \"\(Log.words(title))\" submenu")
        TurnOverMenu.shared.revealPath(levels)
    }
}
