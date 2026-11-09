// SPDX-License-Identifier: GPL-3.0-or-later
// An app as named parts (docs/APP-RECIPES-PLAN.md: the sidebar, list, detail shape, 8 Oct 2026). The recipe names the
// parts in order with a match for each; Tab and Shift Tab go round them, Command Control 1 to 9 straight to one. Moving to
// a part: one that takes the keyboard gets it (a table, an outline, a text area, a field), and TurnOver reads it as
// any focus; a list that cannot take it is held by TurnOver's cursor, row by row (as Finder's sidebar); anything
// else (a toolbar, a group) is put under the cursor and read. Nothing else changes: inside a part the app's own
// keys work as they do.
import Foundation
import ApplicationServices

public final class PanesView {
    public let pid: pid_t
    public let parts: [RecipeView.Panes.Part]
    private var hinted = Set<Int>()
    /// Elements found, kept for a moment: finding one walks the window.
    private var found: [Int: (AXUIElement, Date)] = [:]
    /// The part last moved to when it could not take the keyboard (a web app's message list): the keyboard focus stays
    /// where it was, so Tab would otherwise measure from the old place and go back to the same part (Teams, 9 Nov 2026).
    private var placed: (index: Int, focus: AXUIElement?)?
    /// The page a document part put into browse mode: moving to another part gives the mode back to the focus.
    private var documentEntered: BrowseModeDocument?

    private struct WeakView { weak var view: PanesView? }
    /// The view of each app that has one, by process: Describe this app and What changed ask for it. Weak, the app's module owns it.
    private static var registry: [pid_t: WeakView] = [:]
    public static func current(pid: pid_t) -> PanesView? { registry[pid]?.view }

    public init(pid: pid_t, panes: RecipeView.Panes) { self.pid = pid; parts = panes.parts; Self.registry[pid] = WeakView(view: self) }

    /// The element of a part, now. Parts are containers, so the search never goes into rows, cells, text and the
    /// like, and visits a few hundred elements at most: a search that walked Notes' 800-row list held the main
    /// thread for seconds and the watchdog handed over (8 Oct 2026). Kept for ten seconds once found.
    public func element(of i: Int) -> AXUIElement? {
        guard parts.indices.contains(i) else { return nil }
        if let (e, at) = found[i], Date().timeIntervalSince(at) < 10, e.role != "?" { return e }
        guard let e = Self.find(parts[i].match, pid: pid) else { found[i] = nil; return nil }
        found[i] = (e, Date())
        return e
    }

    /// Roles a part is never inside: the search stops at them.
    nonisolated static let leafRoles: Set<String> = ["AXRow", "AXCell", "AXStaticText", "AXImage", "AXButton", "AXMenuBar", "AXMenu", "AXTextField", "AXCheckBox",
                                         "AXRadioButton", "AXPopUpButton", "AXSlider", "AXLink", "AXHeading", "AXColumn", "AXDisclosureTriangle"]
    /// The first element in the app's front window that matches, breadth first, without entering leaves or
    /// the rows of a list, and within a time budget (any thread).
    nonisolated static func find(_ m: ElementMatch, pid: pid_t, budget: TimeInterval = 0.9) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        let started = Date()
        var queue = [app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute)].compactMap { $0 }
        if queue.isEmpty { queue = app.elements(kAXWindowsAttribute) }
        var visited = 0
        // 3,000 and a longer budget: Libation's grid (.NET's Avalonia) sits deep under layers of nameless groups and
        // was never found within 800 (parts request #6, 14 Oct 2026). The result is cached per part.
        while !queue.isEmpty, visited < 3000, Date().timeIntervalSince(started) < budget {
            let e = queue.removeFirst(); visited += 1
            if ElementMatcher.matches(e, m) { return e }
            let role = e.role
            if leafRoles.contains(role) { continue }
            // A table or outline is a part itself; its rows are not where another part lives.
            if ["AXTable", "AXOutline", "AXList"].contains(role) { continue }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    /// Which part the user is in: the one holding the keyboard focus, or TurnOver's cursor.
    public func currentIndex() -> Int? {
        let nav = ObjectNavigator.shared
        if let p = placed, parts.indices.contains(p.index) {
            let focusNow = API.focusObject?.element
            let unchanged = (focusNow == nil && p.focus == nil) || (focusNow != nil && p.focus != nil && focusNow!.isSame(p.focus!))
            if unchanged { return p.index }
        }
        for i in parts.indices {
            guard let e = element(of: i) else { continue }
            // (element(of:) is bounded and cached, so this is a few calls per part.)
            if let f = API.focusObject, isInside(f.element, e) { return i }
            if nav.isHolding, let h = nav.heldList, h.isSame(e) { return i }
        }
        for i in parts.indices { if let e = element(of: i), nav.isWithin(e), nav.isHolding == false, nav.cursorWindow != nil { return i } }
        return nil
    }

    private func isInside(_ x: AXUIElement, _ root: AXUIElement) -> Bool {
        var p: AXUIElement? = x; var hops = 0
        while let e = p, hops < 40 { if e.isSame(root) { return true }; p = e.element(kAXParentAttribute); hops += 1 }
        return false
    }

    /// Tab and Shift Tab: the next or previous part, round the end.
    public func step(forward: Bool) {
        guard !parts.isEmpty else { return }
        let cur = currentIndex()
        var i = cur.map { ($0 + (forward ? 1 : -1) + parts.count) % parts.count } ?? (forward ? 0 : parts.count - 1)
        // A part not on screen now (a hidden sidebar) is skipped.
        var tries = 0
        while element(of: i) == nil, tries < parts.count { i = (i + (forward ? 1 : -1) + parts.count) % parts.count; tries += 1 }
        go(to: i)
    }

    /// The newest message's words in each document part when it was entered: a reading position is only worth
    /// going back to while the newest message is still the same (Waypoint focus memory).
    private var documentNewest: [Int: String] = [:]

    /// Remembers where the user is in part `c` before leaving it (Waypoint focus memory).
    private func rememberPlace(of c: Int) {
        guard let ec = element(of: c) else { return }
        let part = parts[c]
        if part.read == "document" {
            guard let doc = documentEntered, doc.isAlive else { return }
            let line = doc.lineText(at: doc.position)
            guard !line.isEmpty else { return }
            FocusMemory.remember(region: part.name, pid: pid, .document(offset: doc.position, line: line, newest: documentNewest[c] ?? ""))
            Log.io("focus memory: left \(part.name) at \"\(Log.words(line))\"")
            return
        }
        let nav = ObjectNavigator.shared
        var target: AXUIElement?
        if nav.isHolding, let h = nav.heldList, h.isSame(ec) { target = nav.reviewElement }
        else if let f = API.focusObject?.element, isInside(f, ec), !f.isSame(ec) { target = f }
        else if let r = nav.reviewElement, !r.isSame(ec), isInside(r, ec) { target = r }
        guard let target, let fp = FocusMemory.fingerprint(of: target, root: ec, budget: 0.25), fp.isUsable else { return }
        FocusMemory.remember(region: part.name, pid: pid, .element(fp))
        Log.io("focus memory: left \(part.name) at \(target.role) \"\(Log.words(fp.nodes.last?.text ?? ""))\"")
    }

    /// Back to the place remembered in the part the user is in (Waypoint: remappable `panes_returnToPlace`).
    public func returnToPlace() {
        guard let i = currentIndex() else { Speech.speakMessage(whereAmI()); return }
        go(to: i, forceRestore: true)
    }

    /// Command Control 1 to 9.
    public func go(to i: Int, forceRestore: Bool = false) {
        guard parts.indices.contains(i) else { Tones.edge(); return }
        guard let e = element(of: i) else { Tones.edge(); Speech.speakMessage(String(localized: "\(parts[i].name) is not on screen", comment: "Spoken message: %@ is a part of the window")); return }
        let part = parts[i]
        let obj = ObjectFactory.make(e)
        var settable: DarwinBoolean = false
        let takesKeys = AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
        Log.io("panes: to \(part.name) (\(e.role), takes the keyboard \(takesKeys))")
        // Waypoint focus memory: leaving a part keeps its place; entering one with a place restores it.
        let from = currentIndex()
        if FocusMemory.regionsEnabled, let from, from != i { rememberPlace(of: from) }
        if let from, from != i, let left = element(of: from) { WhatChanged.leaving(region: parts[from], pid: pid, element: left) }
        var recall: (place: FocusPlace, at: Date)?
        if (FocusMemory.regionsEnabled && from != i) || forceRestore {
            recall = FocusMemory.recall(region: part.name, pid: pid)
            if forceRestore, recall == nil { Speech.speakMessage(String(localized: "nothing remembered for \(part.name)", comment: "Spoken message: %@ is a part of the window")); return }
        }
        var rememberedElement: AXUIElement?
        if case .element(let fp)? = recall?.place {
            rememberedElement = FocusMemory.find(fp, under: e, budget: 0.4)
            if rememberedElement == nil { Log.io("focus memory: \(part.name): could not find the place again; default landing") }
        }
        ObjectNavigator.shared.releaseHold()
        placed = nil
        let leaving = documentEntered
        documentEntered = nil
        if part.read == "document", readAsDocument(e, part: part, index: i, recall: recall) {
            placed = (i, API.focusObject?.element)
            return
        }
        defer {
            // Out of a document part: the mode is the focus's again. The focus may not have moved (the message box
            // already had it), so no focus event would switch it back to focus mode.
            if let doc = leaving, API.focusTreeInterceptor === doc, let f = API.focusObject { doc.setPassThrough(doc.shouldPassThrough(f), announce: true) }
        }
        if takesKeys, let r = rememberedElement, FocusMemory.put(r, pid: pid) != "review cursor" {
            Log.io("focus memory: \(part.name): back to \(r.role)")
            Speech.speakMessage(part.name)
        } else if takesKeys, e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success {
            // The focus event reads the element; the part's name first.
            Speech.speakMessage(part.name)
        } else if !e.elements(kAXRowsAttribute).isEmpty {
            ObjectNavigator.shared.enterHold(e, name: part.name, row: rememberedElement)
            if rememberedElement != nil { Log.io("focus memory: \(part.name): back to the remembered row") }
            placed = (i, API.focusObject?.element)
        } else {
            Speech.speakMessage(part.name)
            ObjectNavigator.shared.focusMoved(to: rememberedElement ?? e, pid: pid)
            ObjectNavigator.shared.reportCurrent()
            placed = (i, API.focusObject?.element)
        }
        if let h = part.hint, !hinted.contains(i) { hinted.insert(i); Hints.schedule(h) }
        _ = obj
    }

    /// A document part (plan 4.0): its page goes to browse mode, the reading position to the newest message in it
    /// (the last element matching the recipe's `land`, by default the last heading), and that line is read at once,
    /// so the arrows read the message by line, word and character with no key to get in. The keyboard focus is left
    /// where it was: focusing the part moved the reading position to its top, the oldest message (GitHub Copilot,
    /// 9 Nov 2026). False when the part is not in a page TurnOver reads in browse mode.
    private func readAsDocument(_ e: AXUIElement, part: RecipeView.Panes.Part, index: Int, recall: (place: FocusPlace, at: Date)?) -> Bool {
        guard let doc = document(containing: e), API.focusTreeInterceptor === doc else { return false }
        doc.rebuildIfCheap(stale: 2)
        let target = landing(in: e, match: part.land) ?? e
        guard var at = doc.buffer.offset(of: target) ?? doc.readingOn({ doc.buffer.offset(of: target) }) ?? doc.buffer.offset(of: e) else { return false }
        let newest = FocusMemory.normalise(ElementMatcher.text(of: target))
        // Waypoint focus memory: resume where the user was while the newest message is still the one they left under.
        var note: String?
        if case .document(let offset, let line, let was)? = recall?.place {
            if Date().timeIntervalSince(recall!.at) < FocusMemory.documentMemory, !was.isEmpty, was == newest {
                let back = doc.resumeOffset(BrowseModeHandler.Saved(offset: offset, text: line, at: recall!.at))
                if doc.lineText(at: back) == line { at = back; note = String(localized: "back where you were", comment: "Spoken message: returning to a remembered place") }
            }
            if note == nil {
                note = String(localized: "at the newest message", comment: "Spoken message: the remembered place could not be found, so the reading starts at the newest message")
                Log.io("focus memory: \(part.name): place not confirmed; newest message")
            }
        }
        documentNewest[index] = newest
        Log.io("panes: \(part.name) read as a document from \(at) (\(target.role))")
        doc.setPassThrough(false, announce: true)
        doc.position = at
        doc.lastChain = []
        documentEntered = doc
        Speech.speakMessage(part.name)
        if let note { Speech.speakMessage(note) }
        doc.speakUnit(.line)
        return true
    }

    /// The browse mode document of the outermost web area around an element, if TurnOver has one.
    private func document(containing e: AXUIElement) -> BrowseModeDocument? {
        var p: AXUIElement? = e, hops = 0, outermost: AXUIElement?
        while let x = p, hops < 60 { if x.role == "AXWebArea" { outermost = x }; p = x.element(kAXParentAttribute); hops += 1 }
        guard let w = outermost, let d = BrowseModeHandler.shared.existingDocument(for: w), d.isAlive else { return nil }
        return d
    }

    /// The last element inside `root`, in reading order, that matches: children are taken from the end, so the
    /// first match is the newest message. Bounded, as the part search is.
    private func landing(in root: AXUIElement, match: ElementMatch?) -> AXUIElement? {
        var heading = ElementMatch(); heading.role = "AXHeading"
        let want = match ?? heading
        var stack = root.elements(kAXChildrenAttribute)
        var visited = 0
        while let e = stack.popLast(), visited < 2000 {
            visited += 1
            if ElementMatcher.matches(e, want) { return e }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    /// Where you are, in words.
    public func whereAmI() -> String {
        guard let i = currentIndex() else { return "not in a part of \(parts.map(\.name).joined(separator: ", "))" }
        return "\(parts[i].name), part \(i + 1) of \(parts.count)"
    }
}
