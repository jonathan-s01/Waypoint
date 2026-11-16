// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint: where the keyboard goes when a part or area is jumped to and the part itself cannot take it (a web app's
// bar of apps, its list of chats). Putting only the cursor there left the arrows with the app's old place, or, in a held
// list, made Return do nothing (Teams, 16 Nov 2026). So the keyboard goes onto something inside, and the app's own
// arrows and Return then work as they do in the app. The choice, in order: the place remembered for the part, the
// item that is current in it, the first control, the first row of a list. Used by PanesView and AreaMenu.
import Foundation
import ApplicationServices
import TurnOverAX

public enum PartLanding {
    struct Target {
        let element: AXUIElement
        /// For the log: "remembered", "current", "first control" or "first row".
        let why: String
    }

    /// The item of a part that is current: `isChoice` when it is one of several the part offers and the state says
    /// which (the app you are in, the tab shown), as against a row selected in a list.
    struct Current {
        let element: AXUIElement
        let isChoice: Bool
    }

    nonisolated private static let choiceRoles: Set<String> = ["AXCheckBox", "AXRadioButton"]
    private static let lists: Set<String> = ["AXOutline", "AXTable", "AXList", "AXBrowser"]
    /// A focusable container around a remembered element is the page or the pane, never a place to land.
    private static let notAPlace: Set<String> = ["AXWebArea", "AXScrollArea", "AXSplitGroup", "AXWindow", "AXApplication"]

    /// Whether an item's state marks it as the current one. Teams marks the current app with the toggle's value 1
    /// (the others have none), not with AXSelected (16 Nov 2026). A text field's value is never a state, so only
    /// toggles and radio buttons are read that way. `ariaCurrent` is the page's own "current" (Chromium's AXARIACurrent).
    nonisolated public static func isCurrent(role: String, selected: Bool?, value: Int?, ariaCurrent: String?) -> Bool {
        if selected == true { return true }
        if let c = ariaCurrent?.lowercased(), !c.isEmpty, c != "false" { return true }
        return choiceRoles.contains(role) && value == 1
    }

    /// The nearest element at or above `start`, below `part`, that takes the keyboard.
    static func focusable(from start: AXUIElement, within part: AXUIElement) -> AXUIElement? {
        var x: AXUIElement? = start
        var hops = 0
        while let e = x, hops < 12, !e.isSame(part) {
            if !notAPlace.contains(e.role), AreaMenu.canTakeFocus(e) { return e }
            x = e.element(kAXParentAttribute)
            hops += 1
        }
        return nil
    }

    /// The current item inside `part` that takes the keyboard: breadth first, a few hundred elements at most, within a
    /// time budget. A list answers with its selected row; its rows are not entered.
    static func currentItem(in part: AXUIElement, budget: TimeInterval = 0.4) -> Current? {
        let names = [kAXRoleAttribute, kAXValueAttribute, kAXSelectedAttribute, "AXARIACurrent", kAXChildrenAttribute]
        let started = Date()
        var queue: [(AXUIElement, Int)] = [(part, 0)]
        var head = 0
        var found: Current?
        while head < queue.count, head < 150, Date().timeIntervalSince(started) < budget {
            let (x, depth) = queue[head]
            head += 1
            let a = x.attrs(names)
            let role = a[kAXRoleAttribute] as? String ?? "?"
            if lists.contains(role) {
                if found == nil, let row = x.elements(kAXSelectedRowsAttribute).first(where: AreaMenu.canTakeFocus) { found = Current(element: row, isChoice: false) }
                continue
            }
            let current = isCurrent(role: role, selected: a[kAXSelectedAttribute] as? Bool, value: (a[kAXValueAttribute] as? NSNumber)?.intValue,
                                    ariaCurrent: a["AXARIACurrent"] as? String)
            if head > 1, current, AreaMenu.canTakeFocus(x) {
                if role == "AXRow" { if found == nil { found = Current(element: x, isChoice: false) } }
                else { return Current(element: x, isChoice: true) }
            }
            if depth < 6, !PanesView.leafRoles.contains(role) { queue += ((a[kAXChildrenAttribute] as? [AXUIElement]) ?? []).prefix(40).map { ($0, depth + 1) } }
        }
        return found
    }

    /// The first row of the list in or at `part`, when the app lets it take the keyboard (Teams' chats).
    static func firstRow(in part: AXUIElement) -> AXUIElement? {
        guard let list = AreaMenu.holdableList(in: part),
              let row = (list.attributeValuesResult(kAXRowsAttribute, index: 0, maxValues: 1).value as? [AXUIElement])?.first,
              AreaMenu.canTakeFocus(row) else { return nil }
        return row
    }

    /// Where the keyboard goes in `part`, nil when nothing inside takes it. `remembered`: the element the user last
    /// had there (focus memory). The current item of a set of choices (the app you are in) comes before the
    /// remembered place: you land on where you are, not on where your cursor last strayed; a list's selected row does
    /// not, since the row you last had is the better place.
    static func target(in part: AXUIElement, remembered: AXUIElement?) -> Target? {
        let current = currentItem(in: part)
        if let current, current.isChoice { return Target(element: current.element, why: "current") }
        if let remembered, let e = focusable(from: remembered, within: part) { return Target(element: e, why: "remembered") }
        if let current { return Target(element: current.element, why: "current") }
        if let e = AreaMenu.keyboardTarget(in: part) { return Target(element: e, why: "first control") }
        if let e = firstRow(in: part) { return Target(element: e, why: "first row") }
        return nil
    }
}
