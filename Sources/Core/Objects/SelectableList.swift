// SPDX-License-Identifier: GPL-3.0-or-later
// Lists, tables and outlines: the arrows, Home and End, the selection events, and the lists that will not move their own selection.
// Behaviours (NVDA: NVDAObjects.behaviors): the object classes every application shares; app modules subclass them.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

/// A list, table or outline that takes focus and moves its own selection (NVDA: list items gain focus;
/// here the arrows go to the control, and a move that changes nothing is an edge — with a bump).
open class SelectableList: TurnOverObject {
    open override func initOverlay() {
        super.initOverlay()
        let cat = "Lists"
        for key in ["upArrow", "downArrow", "home", "end", "pageUp", "pageDown", "option+upArrow", "option+downArrow"] {
            script("list_\(key.replacingOccurrences(of: "+", with: "_"))", "Moves the selection and reads it", gestures: ["kb:\(key)"], category: cat) { [weak self] g in self?.moveSelection(g) }
        }
        script("list_activate", String(localized: "Opens the selected item: the application's own Return, or a press when Return does nothing", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter"], category: cat) { [weak self] g in self?.activate(g) }
        script("list_toggleCheckBox", String(localized: "Ticks or unticks the check box in the selected row", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:space"], category: cat) { [weak self] g in self?.toggleRowCheckBox(g) }
        // Only when the row has a check box to tick. Otherwise Space is the application's: play and pause in
        // Podcasts and Music, Quick Look in Finder (10 Oct 2026: Space did nothing in Podcasts).
        script(named: "list_toggleCheckBox")?.isAvailable = { [weak self] in self?.selectedRowCheckBox() != nil }
        if axRole == "AXOutline" {
            script("tree_expandCollapse", String(localized: "Expands or collapses the item, and says which", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:rightArrow", "kb:leftArrow"], category: cat) { [weak self] g in self?.expandOrCollapse(g) }
        }
    }

    /// Return in a list (Windows: Enter opens the item). Mac lists often ignore it (Safari's Reading List opens an
    /// item only by a click), so when nothing answers the key, the selected item is pressed.
    private func activate(_ g: KeyboardGesture) {
        // The row TurnOver walked to, when the list won't select (Freeform's boards).
        let walked = virtualRow.flatMap { i -> AXUIElement? in let rows = rowsAndKey.0; return rows.indices.contains(i) ? rows[i] : nil }
        func pressable(_ e: AXUIElement) -> Bool {
            var names: CFArray?
            return AXUIElementCopyActionNames(e, &names) == .success && ((names as? [String]) ?? []).contains(kAXPressAction as String)
        }
        // The list's own selection is not on the row TurnOver walked to (Copilot's session list, 13 Nov 2026: the
        // arrows said each chat, and Return opened the one the app still had selected): the row heard is the one opened.
        if let walked, !(element.elements(rowsAndKey.1).first?.isSame(walked) ?? false),
           let target = pressable(walked) ? walked : walked.elements(kAXChildrenAttribute).first(where: pressable) {
            Log.io("list: Return on the row TurnOver walked to; pressing it")
            if AXUIElementPerformAction(target, kAXPressAction as CFString) == .success { Tones.press(); return }
        }
        // A walked row with nothing to press: a click opens it. Copilot's chats under each project have no press
        // action and refuse the focus; Return went to the message box behind the list (16 Nov 2026, macOS 27).
        if let walked, !(element.elements(rowsAndKey.1).first?.isSame(walked) ?? false),
           !pressable(walked), !walked.elements(kAXChildrenAttribute).contains(where: pressable), ClickFallback.click(walked) {
            Log.io("list: Return on the row TurnOver walked to; clicking it")
            return
        }
        g.send()
        if Poll.pumping(every: 0.01, limit: 0.5, { EventHandler.isPending(.gainFocus) || EventHandler.isPending(.selection) || EventHandler.isPending(.foreground) || EventHandler.isPending(.valueChange) }) { return }
        guard let row = element.elements(rowsAndKey.1).first ?? walked else { return }
        guard let target = pressable(row) ? row : row.elements(kAXChildrenAttribute).first(where: pressable) else { return }
        Log.io("list: Return did nothing; pressing the selected item")
        if AXUIElementPerformAction(target, kAXPressAction as CFString) == .success { Tones.press() }
    }

    /// Right and Left in an outline (Safari's bookmarks, Finder's sidebar): NVDA says "expanded" / "collapsed".
    /// A move instead (Left on a child goes to its parent) is read by the selection event.
    private func expandOrCollapse(_ g: KeyboardGesture) {
        guard let row = element.elements(kAXSelectedRowsAttribute).first else { g.send(); return }
        let before = row.attr("AXDisclosing") as? Bool
        g.send()
        // Answered as soon as the row opens or closes, or the selection moves; it used to wait the whole 0.3 s each
        // time and then, on a row with nothing to open, say nothing (Reminders' sidebar, 10 Oct 2026).
        var after = before
        let moved = Poll.pumping(every: 0.03, limit: 0.3) {
            after = row.attr("AXDisclosing") as? Bool
            return after != before || EventHandler.isPending(.selection) || EventHandler.isPending(.gainFocus)
        }
        if let after, after != before { Speech.speakMessage(after ? String(localized: "expanded", comment: "Spoken message") : String(localized: "collapsed", comment: "Spoken message")); return }
        if !moved { Tones.edge(keySent: true) }   // nothing to open or close here
    }

    /// The rows, and whatever holds the selection: a table's rows, or a plain list's children.
    private var rowsAndKey: ([AXUIElement], String) { Self.rowsAndKey(of: element, role: axRole, subrole: axSubrole) }

    static func rowsAndKey(of element: AXUIElement, role axRole: String, subrole axSubrole: String?) -> ([AXUIElement], String) {
        let rows = element.elements(kAXRowsAttribute)
        if !rows.isEmpty { return (rows, kAXSelectedRowsAttribute) }
        // A table or outline with no rows is empty: its children are its columns and header, not rows. Finder's list
        // view of an empty folder was "5 items", and Down arrow walked "column, 1 of 5" (Oliver, 21 Oct 2026).
        if ["AXOutline", "AXTable"].contains(axRole) {
            return (element.elements(kAXChildrenAttribute).filter { $0.role == "AXRow" }, kAXSelectedRowsAttribute)
        }
        let children = element.elements(kAXChildrenAttribute)
        // A collection (AppKit's NSCollectionView) holds its items in section lists: the items are the rows, not the
        // sections. Freeform's boards were "list, 1 of 1", the section, and the arrows went no further (parts sweep,
        // 14 Oct 2026). A section's header is an empty group; a header with text stays, read as it's passed.
        if axSubrole == "AXCollectionList", children.contains(where: { $0.string(kAXSubroleAttribute) == "AXSectionList" }) {
            var items: [AXUIElement] = []
            for c in children {
                guard c.string(kAXSubroleAttribute) == "AXSectionList" else { items.append(c); continue }
                for i in c.elements(kAXChildrenAttribute) where items.count < 3000 {
                    if i.role == "AXGroup", i.elements(kAXChildrenAttribute).isEmpty, (i.string(kAXDescriptionAttribute) ?? "").isEmpty { continue }
                    items.append(i)
                }
            }
            return (items, kAXSelectedChildrenAttribute)
        }
        return (children, kAXSelectedChildrenAttribute)
    }

    /// Select the first or last row through accessibility (NVDA: Home and End in a list). Mac lists only scroll on
    /// Home and End, and Up with nothing selected jumps to the last row, so TurnOver moves the selection itself.
    private func selectEnd(first: Bool) -> Bool {
        let (rows, key) = rowsAndKey
        guard !rows.isEmpty else { return false }
        let selected = element.elements(key)
        // The first row may refuse the selection (Safari's Reading List starts with an empty spacer row): try the next.
        let candidates = first ? Array(rows.prefix(3)) : Array(rows.suffix(3).reversed())
        for target in candidates {
            if selected.count == 1, selected[0].isSame(target) { return false }   // already there: the edge
            guard select(target, key: key, was: selected) else { continue }
            Log.io("list: selected the \(first ? "first" : "last") of \(rows.count) rows")
            ListPlace.note(list: element, row: target, index: rows.firstIndex { $0.isSame(target) })
            return true
        }
        return false
    }

    /// Set the selection to one row and check it took (a row may refuse), then scroll to it.
    private func select(_ target: AXUIElement, key: String, was selected: [AXUIElement]) -> Bool {
        guard element.set(key, [target] as CFArray) == .success else { return false }
        guard element.elements(key).contains(where: { $0.isSame(target) }) else {
            if !selected.isEmpty { _ = element.set(key, selected as CFArray) }   // the refusal cleared the selection
            return false
        }
        _ = AXUIElementPerformAction(target, "AXScrollToVisible" as CFString)
        return true
    }

    /// With nothing selected, go back to where the selection last was in this list: the row itself if it is still
    /// there, else the row now at its place. False when this list has no remembered place or the row will not select.
    private func restorePlace() -> Bool {
        guard let place = ListPlace.place(of: element) else { return false }
        let (rows, key) = rowsAndKey
        let found = place.row.flatMap { r in rows.firstIndex { $0.isSame(r) } }
        guard let i = ListPlace.restoreIndex(remembered: place.index, found: found, rowCount: rows.count),
              select(rows[i], key: key, was: []) else { return false }
        Log.io("list: nothing selected; back to row \(i + 1) of \(rows.count)")
        ListPlace.note(list: element, row: rows[i], index: i)
        return true
    }

    /// The list takes the focus again (a window switched back to): its selection may have gone while it was away.
    open override func event_gainFocus() {
        super.event_gainFocus()
        // Back in a list TurnOver walks itself: on the row it was on, said after the list (Copilot's sessions started
        // at the top again each time, 16 Nov 2026).
        if virtualRow == nil, resumeWalk() {
            if let i = virtualRow { sayWalked(i, of: rowsAndKey.0, interrupt: false) }
            return
        }
        guard virtualRow == nil else { return }
        if let row = element.elements(rowsAndKey.1).first {
            ListPlace.note(list: element, row: row)
        } else if ListPlace.place(of: element) != nil, restorePlace() {
            if !waitForSelection() { readSelection() }
        }
    }

    private func waitForSelection() -> Bool {
        Poll.pumping(limit: 0.3) { EventHandler.isPending(.selection) || EventHandler.isPending(.gainFocus) }
    }

    private func moveSelection(_ g: KeyboardGesture) {
        let key = g.keyName
        let toTop = key == "home" || (key == "upArrow" && g.modifiers.contains(.option))
        let toBottom = key == "end" || (key == "downArrow" && g.modifiers.contains(.option))
        if toTop || toBottom {
            if selectEnd(first: toTop) {
                if !waitForSelection() { readSelection() }   // some lists post nothing when the selection is set for them
            } else {
                Log.io("list: already at the \(toTop ? "top" : "bottom")")
                readSelection()
            }
            return
        }
        let plainArrow = (key == "upArrow" || key == "downArrow") && g.modifiers.isEmpty
        // A held arrow: send the key and go on without waiting or reading. In Finder's list view going Up, the selection
        // event came 300 ms late; each repeat then held the main thread for the wait, the keyboard thread's 150 ms
        // limit ran out for the ones behind it, and they burst out together (16 Nov 2026, macOS 27). Finder served
        // TurnOver's row reads on its own main thread too, and its selection froze while the key was held. The event
        // that arrives reads the row. The first press of the hold has checked that there is a selection and an
        // end to move to; a repeat at an end is sent to the application, as the end check would have done.
        if plainArrow, g.isRepeat, virtualRow == nil, let at = heldSelectionAt, Date().timeIntervalSince(at) < 1 {
            heldSelectionAt = Date()
            g.send()
            return
        }
        // Nothing selected yet: either arrow starts at the top, not at the far end where Mail puts Up. A list that
        // remembers where its selection was goes back there first (an item moved away from another window).
        if plainArrow, virtualRow == nil, resumeWalk() { moveVirtually(key); return }
        if plainArrow, virtualRow == nil {
            let hasSelection = !element.elements(rowsAndKey.1).isEmpty
            heldSelectionAt = hasSelection ? Date() : nil
            if !hasSelection, restorePlace() || selectEnd(first: true) {
                if !waitForSelection() { readSelection() }
                return
            }
        }
        // Already on the first or last row: the key goes on to the application (the system plays its own bump) without
        // waiting for a change that will not come; each wait held up the keys behind it (up to the top fast, then down
        // fast, was silent, 3 Oct 2026).
        if g.modifiers.isEmpty, key == "upArrow" || key == "downArrow", atEnd(top: key == "upArrow") {
            g.send()
            Log.io("list: at the \(key == "upArrow" ? "top" : "bottom")")
            return
        }
        if virtualRow != nil, g.modifiers.isEmpty, ["upArrow", "downArrow", "home", "end"].contains(key) { moveVirtually(key); return }
        g.send()
        if waitForSelection() { return }   // the selection event reads the row
        // An empty list: the arrow has nothing to move to; say so rather than nothing (Finder's empty folder).
        if g.modifiers.isEmpty, ["upArrow", "downArrow"].contains(key), rowsAndKey.0.isEmpty {
            Log.io("list: empty")
            Speech.speakMessage(String(localized: "empty", comment: "Spoken message"))
            return
        }
        // A list that ignores the arrows and has nothing selected (Safari's Feature Flags: 228 rows, every arrow did
        // nothing, 4 Oct 2026): TurnOver walks its rows itself, as VoiceOver does, from now on in this list.
        if g.modifiers.isEmpty, ["upArrow", "downArrow"].contains(key), element.elements(rowsAndKey.1).isEmpty, !rowsAndKey.0.isEmpty {
            Log.io("list: the list does not move its selection; TurnOver walks the rows itself")
            virtualRow = -1
            moveVirtually(key)
            return
        }
        // Not at an end, but nothing yet: the application is slow (Mail fetching a message); its event reads the row
        // when it comes. In a grid, Up and Down at the top or bottom row do nothing: the edge (Freeform's boards).
        Log.io("list: no selection change yet after \(g.keyName)")
        if axSubrole == "AXCollectionList" { Tones.edge(keySent: true) }
    }

    /// When a plain arrow last found a selection, or a held arrow was last sent on: a repeat within a second of it skips the reads.
    private var heldSelectionAt: Date?

    /// The row TurnOver is on, in a list that will not move its own selection (-1: before the first).
    private var virtualRow: Int?

    private func moveVirtually(_ key: String) {
        let rows = rowsAndKey.0
        guard !rows.isEmpty, let at = virtualRow else { return }
        var i = at
        switch key {
        case "downArrow": i = at + 1
        case "upArrow": i = at < 0 ? 0 : at - 1
        case "home": i = 0
        case "end": i = rows.count - 1
        default: break
        }
        guard rows.indices.contains(i) else { Tones.edge(keySent: true); return }
        virtualRow = i
        ListPlace.note(list: element, row: rows[i], index: i, walked: true)
        _ = rows[i].set(kAXSelectedAttribute, kCFBooleanTrue)   // the list's own selection follows, where it will
        sayWalked(i, of: rows, interrupt: true)
    }

    private func sayWalked(_ i: Int, of rows: [AXUIElement], interrupt: Bool) {
        guard rows.indices.contains(i) else { return }
        let obj = ObjectFactory.make(rows[i])
        var parts = Speech.objectPropertiesSpeech(obj, reason: .focus).filter { !Phrases.isPosition($0) }
        parts.append(Phrases.position(i + 1, of: rows.count))
        if interrupt { Speech.cancel() }
        Speech.speakMessage(parts.joined(separator: ", "))
    }

    /// Takes up TurnOver's own walk where it was in this list, when the list still has nothing selected.
    private func resumeWalk() -> Bool {
        guard let place = ListPlace.place(of: element), place.walked else { return false }
        let (rows, key) = rowsAndKey
        guard element.elements(key).isEmpty else { return false }
        let found = place.row.flatMap { r in rows.firstIndex { $0.isSame(r) } }
        guard let i = ListPlace.restoreIndex(remembered: place.index, found: found, rowCount: rows.count) else { return false }
        Log.io("list: back to row \(i + 1) of \(rows.count) in TurnOver's own walk")
        virtualRow = i
        return true
    }

    /// Whether the selection is on the first (or last) row.
    private func atEnd(top: Bool) -> Bool {
        let (rows, key) = rowsAndKey
        guard let end = top ? rows.first : rows.last, let selected = element.elements(key).first else { return false }
        return selected.isSame(end)
    }

    /// Space on a row that holds a check box (Safari's Feature Flags): press the check box and say how it is now.
    /// A row without one keeps Space for the application.
    /// The check box in the selected row, if it has one (a bounded walk: twenty elements at most).
    private func selectedRowCheckBox() -> AXUIElement? {
        let rows = rowsAndKey.0
        guard let row = virtualRow.flatMap({ rows.indices.contains($0) ? rows[$0] : nil }) ?? element.elements(rowsAndKey.1).first else { return nil }
        var queue = row.elements(kAXChildrenAttribute); var n = 0
        while !queue.isEmpty, n < 20 { let e = queue.removeFirst(); n += 1; if e.role == "AXCheckBox" { return e }; queue.append(contentsOf: e.elements(kAXChildrenAttribute)) }
        return nil
    }

    private func toggleRowCheckBox(_ g: KeyboardGesture) {
        guard let box = selectedRowCheckBox() else { g.send(); return }
        AXUIElementPerformAction(box, kAXPressAction as CFString)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Speech.speakCheckState(of: box) }
    }

    /// Speak the selected row, as a selection event would.
    private func readSelection() {
        guard let row = element.elements(rowsAndKey.1).first else { Speech.speakMessage(String(localized: "nothing selected", comment: "Spoken message")); return }
        EventHandler.queue(Event(.selection, ObjectFactory.make(row)))
    }
}
