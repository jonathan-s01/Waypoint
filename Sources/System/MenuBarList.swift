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
        guard let pid = API.focusPid, let bar = AXUIElementCreateApplication(pid).element(kAXMenuBarAttribute) else { Tones.edge(); return }
        let menus = bar.elements(kAXChildrenAttribute)
        guard !menus.isEmpty else { Tones.edge(); return }
        let items: [MenuItem] = menus.enumerated().compactMap { i, m in
            let name = barTitle(m, index: i)
            guard let menu = m.elements(kAXChildrenAttribute).first(where: { $0.role == "AXMenu" }) else { return nil }
            return MenuItem(verbatim: name, .submenu { entries(of: menu) })
        }
        TurnOverMenu.shared.openList(verbatim: String(localized: "Menu bar", comment: "Waypoint's list of the app's menus"), items: items)
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

    static func barTitle(_ m: AXUIElement, index: Int) -> String {
        if let t = m.string(kAXTitleAttribute), !t.isEmpty { return t }
        return index == 0 ? "Apple" : Role.menu.displayString
    }

    /// A menu's items: separators left out, submenus opening as lists.
    static func entries(of menu: AXUIElement) -> [MenuItem] {
        menu.elements(kAXChildrenAttribute).compactMap { c -> MenuItem? in
            guard c.role == "AXMenuItem" else { return nil }
            let title = (c.string(kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            if let sub = c.elements(kAXChildrenAttribute).first(where: { $0.role == "AXMenu" }) {
                return MenuItem(verbatim: title + ", " + String(localized: "submenu", comment: "A menu item that opens another menu"), .submenu { entries(of: sub) })
            }
            return MenuItem(verbatim: spokenTitle(c, title: title), .action { press(c, title: title) })
        }
    }

    /// "New Folder, shift command N", and dimmed if it can't be chosen now.
    static func spokenTitle(_ item: AXUIElement, title: String) -> String {
        var parts = [title]
        if let m = markWord(item.string("AXMenuItemMarkChar")) { parts.append(m) }
        if let s = shortcut(char: item.string("AXMenuItemCmdChar"), modifiers: item.int("AXMenuItemCmdModifiers")) { parts.append(s) }
        if (item.attr(kAXEnabledAttribute) as? Bool) == false { parts.append(String(localized: "dimmed", comment: "A menu item that can't be chosen now")) }
        return parts.joined(separator: ", ")
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

    /// Every item in every menu, narrowed as you type: the name and shortcut, then after a pause the menu it is in.
    private static func search(pid: pid_t) {
        guard let bar = AXUIElementCreateApplication(pid).element(kAXMenuBarAttribute) else { Tones.edge(); return }
        var found: [MenuItem] = []
        // A bounded walk on main (AGENTS.md): Xcode's menus are the largest seen; this stops at 4000 items or 1.5 s.
        let deadline = Date().addingTimeInterval(1.5)
        func walk(_ menu: AXUIElement, path: [String], depth: Int) {
            for c in menu.elements(kAXChildrenAttribute) {
                guard found.count < 4000, Date() < deadline else { return }
                guard c.role == "AXMenuItem" else { continue }
                let title = (c.string(kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                if let sub = c.elements(kAXChildrenAttribute).first(where: { $0.role == "AXMenu" }) {
                    if depth < 4 { walk(sub, path: path + [title], depth: depth + 1) }
                    continue
                }
                let where_ = path.count == 1 ? String(localized: "\(path[0]) menu", comment: "Where a found menu item is: %@ is the menu (File)") : path.joined(separator: ", ")
                found.append(MenuItem(verbatim: spokenTitle(c, title: title), .action { press(c, title: title) }, hint: where_))
            }
        }
        for (i, m) in bar.elements(kAXChildrenAttribute).enumerated() {
            guard let menu = m.elements(kAXChildrenAttribute).first(where: { $0.role == "AXMenu" }) else { continue }
            walk(menu, path: [barTitle(m, index: i)], depth: 1)
        }
        Log.io("menu bar: search over \(found.count) items")
        let hook = TurnOverMenu.shared.keyHook
        TurnOverMenu.shared.openChooser(verbatim: String(localized: "Search menus", comment: "Waypoint's search of every menu item"), items: found)
        TurnOverMenu.shared.keyHook = hook
    }
}
