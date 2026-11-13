// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint: the tools of an area as a panel that stays open (14 Nov 2026, "take over the app's functions with one
// screen-reader-native interface"). Left and Right go between the groups the app draws (a ribbon's tabs, then each
// cluster of controls), Up and Down move in a group, Return uses the control and the panel stays: it reads the area
// again, keeps your place, and says the control with its new value. A slider or stepper is adjusted with the arrows,
// a field or combo box is typed into, and the choices of a menu button or pop-up are a list inside the panel. When
// something takes the window away (a dialog, another window) the panel closes and the focus is wherever the app put it.
// The grouping is AreaMap.groups; the list machinery is TurnOverMenu's rotor.
import Foundation
import ApplicationServices
import TurnOverAX

enum AreaPanel {
    nonisolated private enum Mode { case none, adjust, typing }

    private struct Session {
        var id: Int
        var pid: pid_t
        var areaName: String
        var areaKind: Area.Kind
        var areaIndex: Int
        var title: String
        var snap: AreaMenu.Snapshot
        var groups: [AreaMap.ToolGroup]
        var kind: String
        var openMenu: AXUIElement?
        /// The control last used, so a re-read keeps the place when no press led to it (adjusting, typing, a choice).
        var lastKey = ""
    }

    private static var session: Session?
    private static var nextID = 0
    /// Read on the keyboard thread (to decide whether a key is the panel's), written on main.
    nonisolated private static let mode = Locked(Mode.none)
    private static var target: (ref: AXUIElement, name: String)?
    private static var typed = ""

    static var isGlobal: Bool { session?.areaIndex == 0 }

    // MARK: Opening

    static func open(title: String, areaIndex: Int, in snap: AreaMenu.Snapshot) {
        let area = snap.areas[areaIndex]
        var groups = AreaMap.groups(of: area, in: snap.elements)
        guard !groups.isEmpty else { return }
        if groups.count == 1 { groups[0].name = title }
        nextID += 1
        let s = Session(id: nextID, pid: snap.pid, areaName: area.name, areaKind: area.kind, areaIndex: areaIndex, title: title, snap: snap, groups: groups, kind: groups[0].name)
        mode.value = .none; target = nil; typed = ""
        TurnOverMenu.shared.openRotor(categories(for: groups, in: snap), typeToFilter: false, intro: groups.count > 1 ? title : "")
        session = s
        TurnOverMenu.shared.keyHook = { g in hook(g) }
        TurnOverMenu.shared.onClose = { cleanup() }
    }

    private static func cleanup() {
        mode.value = .none; target = nil; typed = ""
        if let menu = session?.openMenu { _ = AXUIElementPerformAction(menu, "AXCancel" as CFString) }
        session = nil
    }

    // MARK: The list

    private static func categories(for groups: [AreaMap.ToolGroup], in snap: AreaMenu.Snapshot) -> [(name: String, items: [MenuItem])] {
        groups.map { g in
            (g.name, g.tools.map { t in
                let e = snap.elements[t]
                var item = MenuItem(verbatim: label(e, tab: g.isTabs), .select { activate(t) })
                if choicesRoles.contains(e.role) { item.onRight = { openChoices(t) } }
                return item
            })
        }
    }

    private static let choicesRoles: Set<String> = ["AXMenuButton", "AXPopUpButton"]

    private static func label(_ e: AreaElement, tab: Bool) -> String {
        guard tab else { return AreaMap.label(e) }
        return e.value == "1" ? "\(e.name), tab, selected" : "\(e.name), tab"
    }

    /// What identifies a control across a re-read: the value is not part of it, it is what changes.
    private static func key(_ e: AreaElement) -> String { "\(e.name)|\(e.role)" }

    // MARK: Keys

    /// The panel's own keys, asked first (the key tap's thread): adjusting and typing take every key; otherwise only
    /// the Tools key, to go between this area's tools and Global's.
    nonisolated private static func hook(_ g: KeyboardGesture) -> Bool {
        if g.modifiers.contains(.command) { return false }
        switch mode.value {
        case .adjust: onMain { adjustKey(g) }; return true
        case .typing: onMain { typingKey(g) }; return true
        case .none:
            guard g.modifiers == [.turnover, .option], g.keyName.lowercased() == "o" else { return false }
            onMain { toggleGlobal() }
            return true
        }
    }

    private static func toggleGlobal() {
        guard let s = session else { return }
        let wantGlobal = s.areaIndex != 0
        let snap = s.snap, pid = s.pid
        TurnOverMenu.shared.close()
        if wantGlobal { AreaMenu.showTools(of: 0, in: snap) } else { AreaMenu.tools(pid: pid, global: false, second: snap.second) }
    }

    // MARK: Using a control

    private static func tool(_ t: Int) -> (e: AreaElement, ref: AXUIElement, tab: Bool)? {
        guard let s = session, s.snap.elements.indices.contains(t) else { return nil }
        let tab = s.groups.first { $0.tools.contains(t) }?.isTabs ?? false
        return (s.snap.elements[t], s.snap.refs[t], tab)
    }

    private static func activate(_ t: Int) {
        guard let (e, ref, tab) = tool(t) else { return }
        session?.lastKey = key(e)
        switch e.role {
        case "AXSlider", "AXIncrementor": beginAdjust(ref, e)
        // For the second reader nothing takes the focus: a search field is typed into like any other.
        case "AXSearchField" where session?.snap.second != true: handOver(ref, e)
        case "AXSearchField": beginTyping(ref, e)
        case "AXTextField", "AXComboBox":
            if session?.snap.second != true, e.subrole == "AXSearchField" || e.name.localizedCaseInsensitiveContains("search") || e.name.localizedCaseInsensitiveContains("find") { handOver(ref, e) }
            else { beginTyping(ref, e) }
        default:
            guard press(ref, role: e.role, mayFocus: session?.snap.second != true) else {
                Speech.speakMessage(String(localized: "that control did not respond", comment: "Spoken message: a control in the tools list could not be pressed or focused"))
                return
            }
            afterPress(t, ref: ref, key: key(e), tab: tab, attempt: 0)
        }
    }

    private static func press(_ ref: AXUIElement, role: String, mayFocus: Bool) -> Bool {
        if AXUIElementPerformAction(ref, kAXPressAction as CFString) == .success { return true }
        if role == "AXPopUpButton", AXUIElementPerformAction(ref, "AXShowMenu" as CFString) == .success { return true }
        return mayFocus && ref.set(kAXFocusedAttribute, kCFBooleanTrue) == .success
    }

    /// A field the panel does not type into (a search box shows results as you type): the panel closes and it has the focus.
    private static func handOver(_ ref: AXUIElement, _ e: AreaElement) {
        TurnOverMenu.shared.close()
        AreaMenu.use(ref, role: e.role)
        Speech.speakMessage(e.name)
    }

    /// Right on a menu button or pop-up: its choices.
    private static func openChoices(_ t: Int) {
        guard let (e, ref, _) = tool(t) else { return }
        if AXUIElementPerformAction(ref, "AXShowMenu" as CFString) != .success, AXUIElementPerformAction(ref, kAXPressAction as CFString) != .success {
            Speech.speakMessage(String(localized: "no choices", comment: "Spoken message: a menu button in the tools panel has no menu to show"))
            return
        }
        lookForMenu(under: ref, then: { afterPress(t, ref: ref, key: key(e), tab: false, attempt: 0) })
    }

    /// The menu a press opened, under the control (Cocoa's pop-ups and menu buttons put it there): shown as a list in the panel.
    private static func lookForMenu(under ref: AXUIElement, attempt: Int = 0, then none: @escaping @MainActor () -> Void) {
        onMain(after: 0.25) {
            guard session != nil else { return }
            if let menu = ref.elements(kAXChildrenAttribute).first(where: { $0.role == "AXMenu" }) { showChoices(menu, title: ref.string(kAXTitleAttribute) ?? ref.string(kAXDescriptionAttribute) ?? ""); return }
            if attempt < 2 { lookForMenu(under: ref, attempt: attempt + 1, then: none) } else { none() }
        }
    }

    private static func showChoices(_ menu: AXUIElement, title: String) {
        let items = choiceItems(menu)
        guard !items.isEmpty else { _ = AXUIElementPerformAction(menu, "AXCancel" as CFString); Speech.speakMessage(String(localized: "no choices", comment: "Spoken message: a menu button in the tools panel has no menu to show")); return }
        session?.openMenu = menu
        TurnOverMenu.shared.pushList(verbatim: title.isEmpty ? String(localized: "choices", comment: "The list of choices of a menu button in the tools panel") : title, items: items, onBack: {
            _ = AXUIElementPerformAction(menu, "AXCancel" as CFString)
            session?.openMenu = nil
        })
    }

    private static func choiceItems(_ menu: AXUIElement) -> [MenuItem] {
        var out: [MenuItem] = []
        for item in menu.elements(kAXChildrenAttribute).prefix(200) where item.role == "AXMenuItem" {
            let a = item.attrs([kAXTitleAttribute, "AXMenuItemMarkChar", kAXEnabledAttribute])
            guard let title = (a[kAXTitleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
            let marked = !((a["AXMenuItemMarkChar"] as? String) ?? "").isEmpty
            let enabled = (a[kAXEnabledAttribute] as? NSNumber)?.boolValue ?? true
            let shown = marked ? "\(title), checked" : (enabled ? title : "\(title), unavailable")
            if let sub = item.elements(kAXChildrenAttribute).first(where: { $0.role == "AXMenu" }), enabled {
                out.append(MenuItem(verbatim: shown, .submenu { choiceItems(sub) }))
            } else {
                out.append(MenuItem(verbatim: shown, .select { choose(item, title: title, enabled: enabled) }))
            }
        }
        return out
    }

    private static func choose(_ item: AXUIElement, title: String, enabled: Bool) {
        guard enabled else { Tones.edge(); return }
        _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
        session?.openMenu = nil
        let pid = session?.pid
        TurnOverMenu.shared.popToTop(say: title)
        guard pid != nil else { return }
        refresh(key: nil, tab: false, say: nil, attempt: 0, before: nil)
    }

    // MARK: After a press: read the area again, stay where you were

    private static func afterPress(_ t: Int, ref: AXUIElement, key k: String, tab: Bool, attempt: Int) {
        guard let s = session else { return }
        let before = s.snap.elements.map { label($0, tab: false) }
        let id = s.id
        onMain(after: 0.3) {
            guard session?.id == id else { return }
            if !tab, let menu = ref.elements(kAXChildrenAttribute).first(where: { $0.role == "AXMenu" }) {
                showChoices(menu, title: ref.string(kAXTitleAttribute) ?? ref.string(kAXDescriptionAttribute) ?? "")
                return
            }
            refresh(key: k, tab: tab, say: nil, attempt: attempt, before: before)
        }
    }

    /// Reads the area again and rebuilds the panel in place. A tab press waits for the app to show the new tab, and
    /// moves to the first group after the tabs.
    private static func refresh(key k: String?, tab: Bool, say: String?, attempt: Int, before: [String]?) {
        guard let s = session else { return }
        let id = s.id
        AreaMenu.snapshot(pid: s.pid, second: s.snap.second) { snap in
            guard let s = session, s.id == id else { return }
            let now = snap.elements.map { label($0, tab: false) }
            if tab, let before, before == now, attempt < 4 {
                onMain(after: 0.3) { refresh(key: k, tab: tab, say: say, attempt: attempt + 1, before: before) }
                return
            }
            let found = snap.areas.firstIndex { $0.name == s.areaName && $0.kind == s.areaKind }
                ?? (snap.areas.indices.contains(s.areaIndex) && snap.areas[s.areaIndex].kind == s.areaKind ? s.areaIndex : nil)
            var groups = found.map { AreaMap.groups(of: snap.areas[$0], in: snap.elements) } ?? []
            guard !groups.isEmpty else {
                TurnOverMenu.shared.close()
                return
            }
            if groups.count == 1 { groups[0].name = s.title }
            var kind = s.kind, position = 0
            let oldKey = k ?? s.lastKey
            if tab, let tabs = groups.firstIndex(where: \.isTabs), tabs + 1 < groups.count {
                kind = groups[tabs + 1].name
                let pressed = groups[tabs].tools.first { key(snap.elements[$0]) == oldKey }.map { snap.elements[$0].name } ?? ""
                session?.snap = snap; session?.groups = groups; session?.kind = kind
                TurnOverMenu.shared.replaceRotor(categories(for: groups, in: snap), kind: kind, index: 0, say: pressed.isEmpty ? nil : String(localized: "\(pressed) tab", comment: "Spoken message: a tab of the tools panel was chosen, %@ is its name"))
                return
            }
            if !groups.contains(where: { $0.name == kind }) { kind = groups.first { !$0.isTabs }?.name ?? groups[0].name }
            let group = groups.first { $0.name == kind }!
            if !oldKey.isEmpty {
                let matches = group.tools.indices.filter { key(snap.elements[group.tools[$0]]) == oldKey }
                let oldPosition = s.groups.first { $0.name == s.kind }?.tools.firstIndex { key(s.snap.elements[$0]) == oldKey } ?? 0
                position = matches.min { abs($0 - oldPosition) < abs($1 - oldPosition) } ?? min(oldPosition, group.tools.count - 1)
            }
            let unchanged = k != nil && (before ?? []) == now
            session?.snap = snap; session?.groups = groups; session?.kind = kind
            TurnOverMenu.shared.replaceRotor(categories(for: groups, in: snap), kind: kind, index: position, say: say ?? (unchanged ? String(localized: "pressed", comment: "Spoken message: a control in the tools panel was pressed and nothing visibly changed") : nil), announceItem: say == nil && !unchanged)
        }
    }

    // MARK: Sliders and steppers

    private static func beginAdjust(_ ref: AXUIElement, _ e: AreaElement) {
        target = (ref, e.name)
        mode.value = .adjust
        Speech.speakMessage(String(localized: "\(e.name), \(valueText(ref)), adjusting: Up and Down change it, Return is done", comment: "Spoken message: a slider or stepper in the tools panel is being adjusted: its name and value"))
    }

    private static func valueText(_ ref: AXUIElement) -> String {
        let a = ref.attrs([kAXValueAttribute, "AXValueDescription"])
        if let d = a["AXValueDescription"] as? String, !d.isEmpty { return d }
        if let s = a[kAXValueAttribute] as? String { return s }
        if let n = a[kAXValueAttribute] as? NSNumber { return n.stringValue }
        return ""
    }

    private static func adjustKey(_ g: KeyboardGesture) {
        guard let (ref, _) = target else { mode.value = .none; return }
        switch g.keyName {
        case "upArrow", "rightArrow": nudge(ref, up: true)
        case "downArrow", "leftArrow": nudge(ref, up: false)
        case "enter", "numpadEnter", "escape", "space":
            mode.value = .none; target = nil
            refresh(key: nil, tab: false, say: nil, attempt: 0, before: nil)
        default: Tones.edge()
        }
    }

    private static func nudge(_ ref: AXUIElement, up: Bool) {
        var names: CFArray?
        AXUIElementCopyActionNames(ref, &names)
        let actions = (names as? [String]) ?? []
        let wanted = up ? "AXIncrement" : "AXDecrement"
        if actions.contains(wanted) { _ = AXUIElementPerformAction(ref, wanted as CFString) }
        else if let v = (ref.attr(kAXValueAttribute) as? NSNumber)?.doubleValue {
            let lo = (ref.attr(kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? v - 10
            let hi = (ref.attr(kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? v + 10
            let range = hi - lo
            let step = range > 0 && range <= 100 && range == range.rounded() ? 1 : range / 20
            _ = ref.set(kAXValueAttribute, NSNumber(value: min(hi, max(lo, v + (up ? step : -step)))))
        } else { Tones.edge(); return }
        onMain(after: 0.12) {
            guard target?.ref != nil else { return }
            Speech.speakMessage(valueText(ref))
        }
    }

    // MARK: Fields and combo boxes

    private static func beginTyping(_ ref: AXUIElement, _ e: AreaElement) {
        target = (ref, e.name)
        typed = ""
        mode.value = .typing
        Speech.speakMessage(String(localized: "\(e.name), now \(valueText(ref)), type a new value, Return sets it, Escape leaves it", comment: "Spoken message: a field in the tools panel is being typed into: its name and value"))
    }

    private static func typingKey(_ g: KeyboardGesture) {
        guard let (ref, _) = target else { mode.value = .none; return }
        switch g.keyName {
        case "enter", "numpadEnter":
            mode.value = .none; target = nil
            let value = typed; typed = ""
            guard !value.isEmpty else { Speech.speakMessage(String(localized: "unchanged", comment: "Spoken message: nothing was typed, so a field keeps its value")); return }
            _ = ref.set(kAXValueAttribute, value as CFString)
            _ = AXUIElementPerformAction(ref, "AXConfirm" as CFString)
            refresh(key: nil, tab: false, say: nil, attempt: 0, before: nil)
        case "escape":
            mode.value = .none; target = nil; typed = ""
            Speech.speakMessage(String(localized: "unchanged", comment: "Spoken message: nothing was typed, so a field keeps its value"))
        case "backspace":
            guard let last = typed.popLast() else { Tones.edge(); return }
            Speech.speakMessage(String(localized: "deleted \(String(last))", comment: "Spoken message: a typed character was deleted"))
        default:
            guard g.modifiers.subtracting(.shift).isEmpty else { Tones.edge(); return }
            var ch = g.characters
            if ch.isEmpty || ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { ch = g.keyName == "space" ? " " : g.keyName.count == 1 ? g.keyName : "" }
            guard ch.count == 1 else { Tones.edge(); return }
            typed += ch
            Speech.speakMessage(ch == " " ? String(localized: "space", comment: "Spoken message: the space key typed") : ch)
        }
    }
}
