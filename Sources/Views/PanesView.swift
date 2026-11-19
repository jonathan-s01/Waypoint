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
    /// The parts of the window in front: the recipe's own, or those of an alternate window (Teams' call) while it is
    /// the front one. Kept, not looked up, so reading it costs nothing; `settleParts` is what looks.
    public private(set) var parts: [RecipeView.Panes.Part]
    private let baseParts: [RecipeView.Panes.Part]
    private let alternates: [RecipeView.Panes.Alternate]
    private var variant: String?
    private var variantCheckedAt = Date.distantPast
    /// The front window when the alternates were last looked for: the walk is asked again when it changes.
    private var variantWindow: AXUIElement?
    private var hinted = Set<Int>()
    /// Elements found, kept for a moment: finding one walks the window.
    private var found: [Int: (AXUIElement, Date)] = [:]
    /// Parts looked for and not found, for a moment: a part not on screen walked the whole window again at every
    /// look, several times a Tab (Teams' Tab took 700 ms, about 24,000 accessibility calls, 19 Nov 2026).
    private var missed: [Int: Date] = [:]
    /// The part last moved to when it could not take the keyboard (a web app's message list): the keyboard focus stays
    /// where it was, so Tab would otherwise measure from the old place and go back to the same part (Teams, 9 Nov 2026).
    private var placed: (index: Int, focus: AXUIElement?)?
    /// The page a document part put into browse mode: moving to another part gives the mode back to the focus.
    private var documentEntered: BrowseModeDocument?
    /// Where the keyboard focus last was inside each part (not a document part): a reference and a time, kept as the
    /// focus moves, so the place is known however the user leaves, a key, a click, Return opening a chat, another app.
    private var lastIn: [Int: (element: AXUIElement, at: Date)] = [:]
    /// The element whose place was last written to FocusMemory for each part.
    private var persisted: [Int: AXUIElement] = [:]
    /// The part the focus was last in.
    private var focusPart: Int?
    private var refreshedAt = Date.distantPast
    private var refreshing: Task<Void, Never>?

    private struct WeakView { weak var view: PanesView? }
    /// The view of each app that has one, by process: Describe this app and What changed ask for it. Weak, the app's module owns it.
    private static var registry: [pid_t: WeakView] = [:]
    public static func current(pid: pid_t) -> PanesView? { registry[pid]?.view }

    public init(pid: pid_t, panes: RecipeView.Panes) {
        self.pid = pid; parts = panes.parts; baseParts = panes.parts; alternates = panes.alternates ?? []
        Self.registry[pid] = WeakView(view: self)
    }

    /// The most parts any window of the app has: how many numbered keys the app gets.
    public static func mostParts(_ panes: RecipeView.Panes) -> Int { ([panes.parts.count] + (panes.alternates ?? []).map { $0.parts.count }).max() ?? 0 }

    /// Which window is in front: the recipe's, or an alternate whose `when` is in the front window (Teams' call window
    /// has none of the chat window's parts, 18 Nov 2026). Asked at each command, at most every 1.5 s, as the walk
    /// can take a moment; a change forgets everything kept by part number.
    public func settleParts() {
        guard !alternates.isEmpty, Date().timeIntervalSince(variantCheckedAt) >= 1.5 else { return }
        // The same front window as last time is the same window for ten seconds: in Teams' chat window the call's
        // toolbar is never there, and looking for it walked the window at nearly every Tab (19 Nov 2026).
        let app = AXUIElementCreateApplication(pid)
        let window = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute)
        let sameWindow = window != nil && variantWindow != nil && window!.isSame(variantWindow!)
        if sameWindow, Date().timeIntervalSince(variantCheckedAt) < 10 { return }
        variantCheckedAt = Date(); variantWindow = window
        let hit = alternates.first { Self.find($0.when, pid: pid, budget: 0.4) != nil }
        guard hit?.name != variant else { return }
        variant = hit?.name
        parts = hit?.parts ?? baseParts
        found = [:]; missed = [:]; hinted = []; placed = nil; documentEntered = nil; lastIn = [:]; persisted = [:]; focusPart = nil; documentNewest = [:]
        Log.io("panes: the front window is \(hit?.name ?? "the usual one"): \(parts.count) parts")
    }

    /// The element of a part, now. Parts are containers, so the search never goes into rows, cells, text and the
    /// like, and visits a few hundred elements at most: a search that walked Notes' 800-row list held the main
    /// thread for seconds and the watchdog handed over (8 Oct 2026). Kept for ten seconds once found.
    public func element(of i: Int) -> AXUIElement? {
        guard parts.indices.contains(i) else { return nil }
        if let (e, at) = found[i], Date().timeIntervalSince(at) < 10, e.role != "?" { return e }
        if let at = missed[i], Date().timeIntervalSince(at) < 3 { return nil }
        guard let e = Self.find(parts[i].match, pid: pid) else { found[i] = nil; missed[i] = Date(); return nil }
        found[i] = (e, Date()); missed[i] = nil
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

    /// The keyboard focus is `target` (AXHandler.present, every focus change; `ancestors` are its parents, already read).
    /// Costs one comparison per part against the elements found already, no accessibility call: a focus event must stay
    /// cheap, and `element(of:)` may walk the window. The place is written to FocusMemory when the focus first leaves the
    /// part, one fingerprint per leaving and not per arrow. Parts never found, or kept too long, are found again off the
    /// main thread (at most every 10 s), so a part changed under the cache is picked up by a later focus change.
    public func focusLanded(on target: AXUIElement, ancestors: [AXUIElement]) {
        guard FocusMemory.regionsEnabled else { return }
        var hit: Int?
        var stale = false
        for i in parts.indices {
            guard let (e, at) = found[i] else { stale = true; continue }
            if Date().timeIntervalSince(at) >= 10 { stale = true }
            guard parts[i].read != "document", hit == nil else { continue }
            if CFEqual(target, e) { hit = i } else if ancestors.contains(where: { CFEqual($0, e) }) { hit = i; lastIn[i] = (target, Date()) }
        }
        if let prev = focusPart, prev != hit { persistPlace(of: prev) }
        focusPart = hit
        if hit == nil, stale { refreshParts() }
    }

    /// The app went out of the front: the place the focus had in its part is kept.
    public func leftApp() {
        if let p = focusPart { persistPlace(of: p) }
        focusPart = nil
    }

    /// Writes the place the focus last had in part `i` to FocusMemory, so it outlives the element.
    private func persistPlace(of i: Int) {
        guard FocusMemory.regionsEnabled, let (el, _) = lastIn[i], let root = found[i]?.0 else { return }
        if let p = persisted[i], CFEqual(p, el) { return }
        guard el.role != "?", let fp = FocusMemory.fingerprint(of: el, root: root, budget: 0.25), fp.isUsable else { return }
        persisted[i] = el
        FocusMemory.remember(region: parts[i].name, pid: pid, .element(fp))
        Log.io("focus memory: left \(parts[i].name) at \(el.role) \"\(Log.words(fp.nodes.last?.text ?? ""))\"")
    }

    /// Where the focus last was in part `i`, when that element is still there and still inside the part.
    private func livePlace(of i: Int, in part: AXUIElement) -> (element: AXUIElement, at: Date)? {
        guard let t = lastIn[i], t.element.role != "?", !t.element.isSame(part), isInside(t.element, part) else { return nil }
        return t
    }

    /// Finds the parts again in the background and puts the focus in its part, as the walk may take a while.
    private func refreshParts() {
        guard refreshing == nil, Date().timeIntervalSince(refreshedAt) >= 10 else { return }
        refreshedAt = Date()
        let matches = Handed(parts.map(\.match)), pid = pid
        refreshing = Task {
            let hits = await Task.detached(priority: .utility) { matches.value.map { PanesView.find($0, pid: pid, budget: 0.4).map { Handed($0) } } }.value
            refreshing = nil
            for (i, h) in hits.enumerated() { if let h { found[i] = (h.value, Date()); missed[i] = nil } }
            guard let f = API.focusObject?.element else { return }
            var ancestors: [AXUIElement] = []
            var p = f.element(kAXParentAttribute)
            while let e = p, ancestors.count < 40 { ancestors.append(e); p = e.element(kAXParentAttribute) }
            focusLanded(on: f, ancestors: ancestors)
        }
    }

    /// The pointer put the reading on `target`: that is the part Tab measures from, whatever the keyboard focus is
    /// (a click in a web app's message list leaves the focus in the message box, and Tab went on from there).
    public func readingPlaced(on target: AXUIElement) {
        placed = nil
        for i in parts.indices {
            guard let e = element(of: i), isInside(target, e) else { continue }
            placed = (i, API.focusObject?.element)
            return
        }
    }

    /// The part after or before `cur` (none known: the first or last), round the end; a part not on screen now (a
    /// hidden sidebar) is skipped.
    private func neighbour(of cur: Int?, forward: Bool) -> Int {
        var i = cur.map { ($0 + (forward ? 1 : -1) + parts.count) % parts.count } ?? (forward ? 0 : parts.count - 1)
        var tries = 0
        while element(of: i) == nil, tries < parts.count { i = (i + (forward ? 1 : -1) + parts.count) % parts.count; tries += 1 }
        return i
    }

    /// Tab and Shift Tab: the next or previous part, round the end.
    public func step(forward: Bool) {
        settleParts()
        guard !parts.isEmpty else { return }
        let cur = currentIndex()
        go(to: neighbour(of: cur, forward: forward), from: cur)
    }

    /// The second reader's Tab: the part after the one it is in, which it goes to without moving the keyboard.
    public func stepSecond(forward: Bool) {
        settleParts()
        guard !parts.isEmpty else { return }
        var cur: Int?
        if let at = ReviewLayer.cursorElement() { cur = parts.indices.first { i in element(of: i).map { isInside(at, $0) } ?? false } }
        goSecond(to: neighbour(of: cur, forward: forward))
    }

    /// The second reader to a part: it says the part's name and what is there; the keyboard stays where it is.
    public func goSecond(to i: Int) {
        settleParts()
        guard parts.indices.contains(i) else { Tones.edge(); return }
        guard let e = element(of: i) else { Tones.edge(); Speech.speakMessage(String(localized: "\(parts[i].name) is not on screen", comment: "Spoken message: %@ is a part of the window")); return }
        Speech.speakMessage(parts[i].name)
        ReviewLayer.jump(to: e, area: TurnOverObject.frame(e))
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
        else { target = livePlace(of: c, in: ec)?.element }
        guard let target, let fp = FocusMemory.fingerprint(of: target, root: ec, budget: 0.25), fp.isUsable else { return }
        persisted[c] = target
        FocusMemory.remember(region: part.name, pid: pid, .element(fp))
        Log.io("focus memory: left \(part.name) at \(target.role) \"\(Log.words(fp.nodes.last?.text ?? ""))\"")
    }

    /// Back to the place remembered in the part the user is in (Waypoint: remappable `panes_returnToPlace`).
    public func returnToPlace() {
        guard let i = currentIndex() else { Speech.speakMessage(whereAmI()); return }
        go(to: i, forceRestore: true)
    }

    /// Command Control 1 to 9. `from` is the part the user is in, when the caller has just worked it out.
    public func go(to i: Int, forceRestore: Bool = false, from known: Int?? = nil) {
        settleParts()
        guard parts.indices.contains(i) else { Tones.edge(); return }
        guard let e = element(of: i) else { Tones.edge(); Speech.speakMessage(String(localized: "\(parts[i].name) is not on screen", comment: "Spoken message: %@ is a part of the window")); return }
        let part = parts[i]
        let obj = ObjectFactory.make(e)
        var settable: DarwinBoolean = false
        let takesKeys = AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
        Log.io("panes: to \(part.name) (\(e.role), takes the keyboard \(takesKeys))")
        // Waypoint focus memory: leaving a part keeps its place; entering one with a place restores it.
        let from = known ?? currentIndex()
        if FocusMemory.regionsEnabled, let from, from != i { rememberPlace(of: from) }
        if let from, from != i, let left = element(of: from) { WhatChanged.leaving(region: parts[from], pid: pid, element: left) }
        var recall: (place: FocusPlace, at: Date)?
        var tracked: (element: AXUIElement, at: Date)?
        if (FocusMemory.regionsEnabled && from != i) || forceRestore {
            recall = FocusMemory.recall(region: part.name, pid: pid)
            tracked = part.read == "document" ? nil : livePlace(of: i, in: e)
            if forceRestore, recall == nil, tracked == nil { Speech.speakMessage(String(localized: "nothing remembered for \(part.name)", comment: "Spoken message: %@ is a part of the window")); return }
        }
        var rememberedElement: AXUIElement?
        // Where the keyboard last was in the part, while that element is still there, is the place; FocusMemory's
        // recall is for when it is not, or is newer and was written from some other place.
        if let t = tracked, t.at >= (recall?.at ?? .distantPast) || persisted[i].map({ CFEqual($0, t.element) }) == true {
            rememberedElement = t.element
            Log.io("focus memory: \(part.name): the last focus in it is still there")
        } else if case .element(let fp)? = recall?.place {
            rememberedElement = FocusMemory.find(fp, under: e, budget: 0.4) ?? tracked?.element
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
        } else if takesKeys, case let before = API.focusObject?.element, e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success {
            // The focus event reads the element; the part's name first.
            Speech.speakMessage(part.name)
            AreaMenu.followIfSilent(e, before: before)
        } else if part.read != "document", let t = PartLanding.target(in: e, remembered: rememberedElement), t.element.set(kAXFocusedAttribute, kCFBooleanTrue) == .success {
            // A part that cannot take the keyboard (a web app's bar of apps or list of chats): it goes onto the
            // remembered place, the current item or the first control inside, so the app's own arrows and Return work.
            Log.io("panes: \(part.name): the keyboard goes to \(t.element.role) (\(t.why))")
            Speech.speakMessage(part.name)
            // No focus event comes when that element already had the keyboard.
            if let f = API.focusObject, f.isSameElement(as: t.element) { Speech.speakObject(f, reason: .focus) }
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
        doc.refreshBufferIfNeeded(stale: 2)
        let target = landing(in: e, match: part.land) ?? e
        // The newest message may be past the part of a long page read so far: read on (in the background, as upstream's
        // browse mode does now) and carry on from there.
        func finish(_ start: Int) {
        var at = start
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
        }
        if let at = doc.buffer.offset(of: target) { finish(at); return true }
        doc.readOnUntil({ doc.buffer.offset(of: target) != nil }) { _ in
            guard API.focusTreeInterceptor === doc, let at = doc.buffer.offset(of: target) ?? doc.buffer.offset(of: e) else { return }
            finish(at)
        }
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
