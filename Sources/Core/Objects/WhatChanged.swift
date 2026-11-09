// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's "what changed" (plan 14.1): what is new in a part of a window, or in a window, since the user left it.
// Leaving a part (PanesView.go) or the app (FocusMemory.leaving) takes a cheap snapshot: how many items the part holds
// (rows of a list, or the headings of a page, the recipe's landing match for a document part) and the words of the
// first and the newest few. Asking compares the part as it is now with that snapshot. Walks run off the main thread
// with a deadline and speak back on main. A snapshot is never a live element: apps rebuild their lists, so only words
// and a count are kept, in memory, for this run of the reader.
import Foundation
import ApplicationServices
import TurnOverAX

/// What a list or a page held at a moment: the count, and the words of the first few items and of the last few.
/// `complete` is false when the walk of a page stopped before its start (its count is then only a lower bound).
nonisolated public struct ListState: Equatable, Sendable {
    public var count: Int
    public var head: [String]
    public var tail: [String]
    public var complete: Bool
    public init(count: Int, head: [String], tail: [String], complete: Bool = true) {
        self.count = count; self.head = head; self.tail = tail; self.complete = complete
    }
}

/// How a part differs from the snapshot.
nonisolated public enum WhatChange: Equatable, Sendable {
    case same
    /// `newest`: the words of the newest of them, which may be empty.
    case added(Int, newest: String)
    case removed(Int)
    case changed(newest: String)
}

/// A part's change, for the summary of the whole app.
nonisolated public struct RegionChange: Equatable, Sendable {
    public var name: String
    public var change: WhatChange
    public var ago: TimeInterval
    public init(name: String, change: WhatChange, ago: TimeInterval) { self.name = name; self.change = change; self.ago = ago }
}

nonisolated public enum WhatChanged {
    // MARK: Pure parts (tested)

    /// How the part is now against what it was. Items arrive at the top (mail) or at the bottom (a chat), and the first
    /// or last item remembered is found among the new ones, so how far it moved says how many arrived. A count is
    /// believed only when both walks reached the start of the page.
    public static func compare(_ old: ListState, _ new: ListState) -> WhatChange {
        func norm(_ a: [String]) -> [String] { a.map { FocusMemory.normalise($0) } }
        let oh = norm(old.head), nh = norm(new.head), ot = norm(old.tail), nt = norm(new.tail)
        let counted = old.complete && new.complete
        if ot == nt, !counted || (old.count == new.count && oh == nh) { return .same }
        let delta = counted ? new.count - old.count : 0
        var topShift = 0, bottomShift = 0
        if let f = oh.first, !f.isEmpty, let i = nh.firstIndex(of: f) { topShift = i }
        if let l = ot.last, !l.isEmpty, let i = nt.lastIndex(of: l) { bottomShift = nt.count - 1 - i }
        let newestTop = new.head.first ?? "", newestBottom = new.tail.last ?? ""
        if topShift > 0, bottomShift == 0 { return .added(delta > 0 ? delta : topShift, newest: newestTop) }
        if bottomShift > 0, topShift == 0 { return .added(delta > 0 ? delta : bottomShift, newest: newestBottom) }
        let newest = nt.last != ot.last ? newestBottom : newestTop
        if delta > 0 { return .added(delta, newest: newest) }
        if delta < 0 { return .removed(-delta) }
        return .changed(newest: newest)
    }

    /// The first words of an item, for speaking.
    public static func firstWords(_ s: String, words: Int = 8) -> String {
        let all = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = all.prefix(words).joined(separator: " ")
        return all.count > words ? joined + "…" : joined
    }

    /// How long ago, in words.
    public static func agoText(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 45 { return String(localized: "a moment ago", comment: "How long ago something was, under a minute") }
        let minutes = Int((s / 60).rounded())
        if minutes < 2 { return String(localized: "1 minute ago", comment: "How long ago something was") }
        if minutes < 60 { return String(localized: "\(String(minutes)) minutes ago", comment: "How long ago something was") }
        let hours = Int((s / 3600).rounded())
        if hours < 2 { return String(localized: "1 hour ago", comment: "How long ago something was") }
        if hours < 24 { return String(localized: "\(String(hours)) hours ago", comment: "How long ago something was") }
        let days = max(1, Int((s / 86400).rounded()))
        if days < 2 { return String(localized: "1 day ago", comment: "How long ago something was") }
        return String(localized: "\(String(days)) days ago", comment: "How long ago something was")
    }

    /// What is spoken for one part. nil: there is no earlier visit to compare with.
    public static func sentence(_ change: WhatChange?, ago: TimeInterval) -> String {
        guard let change else { return String(localized: "no earlier visit remembered", comment: "Spoken message: what changed cannot be said, as the user has not left this part before") }
        switch change {
        case .same:
            return String(localized: "nothing new since you left, \(agoText(ago))", comment: "Spoken message: %@ is how long ago, for example 12 minutes ago")
        case .added(let n, let newest):
            let count = n == 1 ? String(localized: "1 new item", comment: "Spoken message: what changed in a part") : String(localized: "\(String(n)) new items", comment: "Spoken message: what changed in a part")
            let words = firstWords(newest)
            return words.isEmpty ? count : String(localized: "\(count), newest: \(words)", comment: "Spoken message: %@ is the count of new items, then the first words of the newest")
        case .removed(let n):
            return n == 1 ? String(localized: "1 item fewer than when you left", comment: "Spoken message: what changed in a part")
                : String(localized: "\(String(n)) items fewer than when you left", comment: "Spoken message: what changed in a part")
        case .changed(let newest):
            let words = firstWords(newest)
            return words.isEmpty ? String(localized: "changed since you left", comment: "Spoken message: what changed in a part")
                : String(localized: "changed since you left, newest: \(words)", comment: "Spoken message: %@ is the first words of the newest item")
        }
    }

    /// The answer for a part, from the snapshot (nil: none) and the part as it is now (nil: it could not be read).
    public static func answer(old: ListState?, ago: TimeInterval, now: ListState?) -> String {
        guard let old else { return sentence(nil, ago: ago) }
        guard let now else { return String(localized: "cannot read this part just now", comment: "Spoken message: what changed cannot be said, as the part did not answer") }
        return sentence(compare(old, now), ago: ago)
    }

    /// The whole app: the parts that changed first, then the ones that did not.
    public static func appSummary(_ rows: [RegionChange]) -> String {
        guard !rows.isEmpty else { return sentence(nil, ago: 0) }
        let changed = rows.filter { $0.change != .same }
        let same = rows.filter { $0.change == .same }
        if changed.isEmpty {
            return String(localized: "nothing new anywhere since you left, \(agoText(rows.map(\.ago).min() ?? 0))", comment: "Spoken message: %@ is how long ago, for example 12 minutes ago")
        }
        var parts = changed.map { "\($0.name): \(sentence($0.change, ago: $0.ago))" }
        if !same.isEmpty { parts.append(String(localized: "nothing new in \(same.map(\.name).joined(separator: ", "))", comment: "Spoken message: %@ lists the parts of the window that did not change")) }
        return parts.joined(separator: ". ")
    }

    // MARK: Snapshots (any thread)

    /// On unless the `waypoint.whatChanged` default is turned off.
    public static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "waypoint.whatChanged") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "waypoint.whatChanged") }
    }

    private struct Snapshot { var state: ListState; var at: Date }
    private static let store = Locked<[String: Snapshot]>([:])
    /// Concurrent: a slow walk of one app must not hold up the answer for another.
    private static let queue = DispatchQueue(label: "waypoint.whatchanged", qos: .userInitiated, attributes: .concurrent)

    static func regionKey(pid: pid_t, name: String) -> String { "\(pid)|r|\(name)" }
    static func windowKey(pid: pid_t, title: String) -> String { "\(pid)|w|\(FocusMemory.normalise(title))" }

    private static func snapshot(for key: String) -> Snapshot? { store.value[key] }

    /// A state that could not be read, or that is empty, is not recorded: an app busy answering blank must not
    /// replace what was known.
    private static func record(_ key: String, _ state: ListState?) {
        guard let state else { return }
        store.lock.lock()
        defer { store.lock.unlock() }
        store.unsafeValue[key] = Snapshot(state: state, at: Date())
        if store.unsafeValue.count > 200, let oldest = store.unsafeValue.min(by: { $0.value.at < $1.value.at })?.key { store.unsafeValue[oldest] = nil }
    }

    static func forget(pid: pid_t) {
        store.lock.lock()
        defer { store.lock.unlock() }
        store.unsafeValue = store.unsafeValue.filter { !$0.key.hasPrefix("\(pid)|") }
    }

    /// The user left a part of a panes window (PanesView.go). The walk is off the main thread, within 0.3 s.
    public static func leaving(region part: RecipeView.Panes.Part, pid: pid_t, element: AXUIElement) {
        guard enabled else { return }
        let handed = Handed(part)
        queue.async {
            let p = handed.value
            record(regionKey(pid: pid, name: p.name), state(of: element, part: p, budget: 0.3))
        }
    }

    /// An app went out of the front (FocusMemory.leaving): every part of a panes app that is on screen, or the front
    /// window of another app. Within 1.5 s in all, off the main thread.
    @MainActor
    public static func leaving(app pid: pid_t) {
        guard enabled else { return }
        let parts = PanesView.current(pid: pid).map { Handed($0.parts) }
        queue.async {
            let end = Date().addingTimeInterval(1.5)
            if let parts {
                for p in parts.value {
                    guard Date() < end else { break }
                    guard let e = PanesView.find(p.match, pid: pid, budget: 0.25) else { continue }
                    record(regionKey(pid: pid, name: p.name), state(of: e, part: p, budget: 0.3))
                }
            } else if let window = frontWindow(of: pid) {
                record(windowKey(pid: pid, title: window.string(kAXTitleAttribute) ?? ""), state(of: window, part: nil, budget: 0.3))
            }
        }
    }

    private static func frontWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        return app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute)
    }

    // MARK: Asking

    /// What changed in the part (or window) `key` names: the part as it is now is read off the main thread, and the
    /// answer is spoken on main, if the user is still in that app.
    public static func report(key: String, element: AXUIElement, part: RecipeView.Panes.Part?, pid: pid_t) {
        let old = snapshot(for: key)
        let handed = Handed(part)
        queue.async {
            let now = state(of: element, part: handed.value, budget: 0.5)
            let text = answer(old: old?.state, ago: old.map { Date().timeIntervalSince($0.at) } ?? 0, now: now)
            onMain {
                guard API.focusPid == pid else { return }
                Speech.speakMessage(text)
            }
        }
    }

    /// The same for every part that has a snapshot, in the recipe's order (or the front window): within 2 s.
    @MainActor
    public static func reportApp(pid: pid_t) {
        let parts = PanesView.current(pid: pid).map { Handed($0.parts) }
        queue.async {
            let end = Date().addingTimeInterval(2)
            var rows: [RegionChange] = []
            if let parts {
                for p in parts.value {
                    guard Date() < end else { break }
                    guard let old = snapshot(for: regionKey(pid: pid, name: p.name)),
                          let e = PanesView.find(p.match, pid: pid, budget: 0.25),
                          let now = state(of: e, part: p, budget: 0.3) else { continue }
                    rows.append(RegionChange(name: p.name, change: compare(old.state, now), ago: Date().timeIntervalSince(old.at)))
                }
            } else if let window = frontWindow(of: pid) {
                let title = window.string(kAXTitleAttribute) ?? ""
                if let old = snapshot(for: windowKey(pid: pid, title: title)), let now = state(of: window, part: nil, budget: 0.5) {
                    rows.append(RegionChange(name: title.isEmpty ? String(localized: "window", comment: "A window, when it has no title") : title, change: compare(old.state, now), ago: Date().timeIntervalSince(old.at)))
                }
            }
            let text = appSummary(rows)
            onMain {
                guard API.focusPid == pid else { return }
                Speech.speakMessage(text)
            }
        }
    }

    // MARK: Reading a part (any thread, bounded)

    /// How many items of each end are kept as words.
    static let headSize = 4
    static let tailSize = 6

    /// The part as it is now: a document part by the recipe's landing match, any other by the biggest list in it. nil
    /// when nothing countable is there, or the time ran out before the words of its items were read. The words of the
    /// items may be read up to 0.2 s after the walk's own budget.
    public static func state(of root: AXUIElement, part: RecipeView.Panes.Part?, budget: TimeInterval) -> ListState? {
        let deadline = Date().addingTimeInterval(budget)
        if let part, part.read == "document" { return documentState(in: root, match: part.land, deadline: deadline) }
        return bestState(under: root, deadline: deadline)
    }

    /// The words an item is known by: its title or description, else its static text.
    private static func words(of e: AXUIElement) -> String {
        let t = FocusMemory.node(of: e, index: 0, isLeaf: true).text
        return t.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static let listRoles: Set<String> = ["AXTable", "AXOutline", "AXList"]

    /// A list's items: its rows, or the children of a plain list.
    private static func items(of list: AXUIElement) -> [AXUIElement] {
        let rows = list.elements(kAXRowsAttribute)
        if !rows.isEmpty { return rows }
        if list.role != "AXList" { return [] }
        return list.elements(kAXChildrenAttribute).filter { !["AXScrollBar", "AXColumn"].contains($0.role) }
    }

    /// The biggest list at or under `root`, else the first web page there. Breadth first, never into rows or leaves.
    private static func bestState(under root: AXUIElement, deadline: Date) -> ListState? {
        var queue = [root], lists: [AXUIElement] = [], web: AXUIElement?, visited = 0
        while !queue.isEmpty, visited < 600, lists.count < 8, Date() < deadline {
            let e = queue.removeFirst(); visited += 1
            let role = e.role
            if listRoles.contains(role) { lists.append(e); continue }
            if role == "AXWebArea" { if web == nil { web = e }; continue }
            if PanesView.leafRoles.contains(role) { continue }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        var best: [AXUIElement] = []
        for l in lists where Date() < deadline {
            let found = items(of: l)
            if found.count > best.count { best = found }
        }
        if !best.isEmpty { return listState(of: best, deadline: deadline.addingTimeInterval(0.2)) }
        if let web { return documentState(in: web, match: nil, deadline: deadline) }
        return nil
    }

    private static func listState(of items: [AXUIElement], deadline: Date) -> ListState? {
        guard !items.isEmpty else { return nil }
        var head: [String] = [], tail: [String] = []
        for e in items.prefix(headSize) { guard Date() < deadline else { return nil }; head.append(words(of: e)) }
        for e in items.suffix(tailSize) { guard Date() < deadline else { return nil }; tail.append(words(of: e)) }
        return ListState(count: items.count, head: head, tail: tail)
    }

    /// The elements under `root` that match the recipe's landing match (by default headings, which are the messages
    /// of a chat page), newest first: the walk goes from the end, as the landing does, so the newest are always found
    /// even when a long history is not walked to its start.
    private static func documentState(in root: AXUIElement, match: ElementMatch?, deadline: Date) -> ListState? {
        var heading = ElementMatch(); heading.role = "AXHeading"
        let want = match ?? heading
        var stack = root.elements(kAXChildrenAttribute)
        var found: [AXUIElement] = []
        var visited = 0
        while found.count < 300, visited < 3000, Date() < deadline, let e = stack.popLast() {
            visited += 1
            if ElementMatcher.matches(e, want) { found.append(e); continue }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        guard !found.isEmpty else { return nil }
        let complete = stack.isEmpty
        let inOrder = Array(found.reversed())
        let textDeadline = deadline.addingTimeInterval(0.2)
        var head: [String] = [], tail: [String] = []
        for e in inOrder.prefix(headSize) { guard Date() < textDeadline else { return nil }; head.append(words(of: e)) }
        for e in inOrder.suffix(tailSize) { guard Date() < textDeadline else { return nil }; tail.append(words(of: e)) }
        return ListState(count: inOrder.count, head: head, tail: tail, complete: complete)
    }
}

/// What changed here: the part of the window you are in (or the window), since you left it; twice, every part of the app.
final class WhatChangedPlugin: GlobalPlugin {
    required init() {
        super.init()
        script("whatChanged", String(localized: "Says what is new in this part of the window since you left it; pressed twice, in every part of the app", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:control+command+w"], category: "Waypoint") { _ in
            guard WhatChanged.enabled else { Speech.speakMessage(String(localized: "what changed is off", comment: "Spoken message")); return }
            guard let pid = API.focusPid else { Speech.speakMessage(String(localized: "no app in front", comment: "Spoken message")); return }
            if ScriptHandler.lastScriptRepeatCount > 0 { WhatChanged.reportApp(pid: pid); return }
            Self.reportHere(pid: pid)
        }
    }

    private static func reportHere(pid: pid_t) {
        if let view = PanesView.current(pid: pid), let i = view.currentIndex(), let e = view.element(of: i) {
            let part = view.parts[i]
            WhatChanged.report(key: WhatChanged.regionKey(pid: pid, name: part.name), element: e, part: part, pid: pid)
            return
        }
        let app = AXUIElementCreateApplication(pid)
        guard let window = API.focusObject?.element.element(kAXWindowAttribute) ?? app.element(kAXFocusedWindowAttribute) else {
            Speech.speakMessage(String(localized: "no window", comment: "Spoken message")); return
        }
        WhatChanged.report(key: WhatChanged.windowKey(pid: pid, title: window.string(kAXTitleAttribute) ?? ""), element: window, part: nil, pid: pid)
    }
}
