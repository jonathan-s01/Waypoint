// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's focus memory (plan 4.4): where you were in an app, and in a part of its window, comes back when you return.
// A place is never a live element: apps rebuild their lists as they scroll, so a place is a fingerprint, the chain of
// nodes from the window (or the part) down to the element, each with its role, identifier, text and place among its
// siblings. Finding it again descends the chain, picking at each level the child that matches best, and answers only
// an exact match at the end: a wrong place is worse than none, so with no confident match the default landing stays.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

/// One step of a fingerprint.
nonisolated public struct FocusNode: Equatable, Sendable {
    public var role: String
    public var id: String
    public var text: String
    public var index: Int
    public init(role: String, id: String = "", text: String = "", index: Int = 0) { self.role = role; self.id = id; self.text = text; self.index = index }
}

/// The chain from a root (a window, or the part of one) down to an element.
nonisolated public struct FocusFingerprint: Equatable, Sendable {
    public var windowTitle: String
    public var nodes: [FocusNode]
    public init(windowTitle: String, nodes: [FocusNode]) { self.windowTitle = windowTitle; self.nodes = nodes }
    /// Only a leaf with an identifier or words can be found again; one with neither would be a guess.
    public var isUsable: Bool { nodes.last.map { !$0.id.isEmpty || !$0.text.isEmpty } ?? false }
}

/// What a region remembers: an element's fingerprint, or a reading position in a document part.
public enum FocusPlace {
    case element(FocusFingerprint)
    case document(offset: Int, line: String, newest: String)
}

public enum FocusMemory {
    // MARK: Settings (UserDefaults; Waypoint-only, default on; the keys are scripts in the key list)

    public static var appEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "waypoint.focusMemory.app") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "waypoint.focusMemory.app") }
    }
    public static var regionsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "waypoint.focusMemory.regions") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "waypoint.focusMemory.regions") }
    }
    /// How long a reading position in a message history is kept ahead of the newest message (plan 4.5).
    public static let documentMemory: TimeInterval = 30 * 60

    // MARK: Pure parts (tested)

    /// Case, spacing and length folded away: the words a node is compared by.
    nonisolated public static func normalise(_ s: String) -> String {
        let words = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(words.lowercased().prefix(80))
    }

    /// How well a child fits a recorded node: nil when it cannot be it. At the leaf an identifier or the words must
    /// agree; on the way down a container may have been retitled, so only the role has to, and the place among the
    /// siblings decides between several.
    nonisolated public static func score(_ want: FocusNode, _ have: FocusNode, isLeaf: Bool) -> Int? {
        guard want.role == have.role else { return nil }
        var s = 0
        if !want.id.isEmpty {
            if have.id == want.id { s += 100 }
            else if !have.id.isEmpty { if isLeaf { return nil }; s -= 40 }
        }
        let w = normalise(want.text), h = normalise(have.text)
        if !w.isEmpty {
            if w == h { s += 60 }
            else if !h.isEmpty, min(w.count, h.count) >= 20, min(w.count, h.count) * 10 >= max(w.count, h.count) * 8, w.hasPrefix(h) || h.hasPrefix(w) { s += 40 }
            else if !h.isEmpty { if isLeaf { return nil }; s -= 30 }
        }
        if isLeaf, (!want.id.isEmpty || !w.isEmpty), s <= 0 { return nil }
        return s + max(0, 10 - abs(want.index - have.index))
    }

    /// The order to look at `count` siblings in, nearest to `index` first: a row that has not moved is found at once.
    nonisolated public static func order(count: Int, around index: Int) -> [Int] {
        guard count > 0 else { return [] }
        let start = min(max(index, 0), count - 1)
        var out = [start]
        var d = 1
        while out.count < count {
            if start - d >= 0 { out.append(start - d) }
            if start + d < count { out.append(start + d) }
            d += 1
        }
        return out
    }

    /// Whether this focus says nothing about where the user was: an app that restored only the window, the page or a
    /// scroll area has not restored a place.
    nonisolated public static func isGeneric(role: String, title: String, description: String) -> Bool {
        if ["AXWindow", "AXWebArea", "AXScrollArea", "AXSplitGroup", "AXToolbar", "AXApplication", "AXLayoutArea"].contains(role) { return true }
        if role == "AXGroup" { return title.trimmingCharacters(in: .whitespaces).isEmpty && description.trimmingCharacters(in: .whitespaces).isEmpty }
        return false
    }

    /// Menus and their items are never a place to go back to.
    nonisolated public static func isMenuRole(_ role: String) -> Bool { role.hasPrefix("AXMenu") }

    // MARK: Fingerprints and finding (any thread)

    nonisolated static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]

    nonisolated static func trimmed(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A node as the fingerprint records it. A leaf, a row or a cell with no title takes its words from its static text;
    /// a field's own value is never used, it changes as the user types.
    nonisolated static func node(of e: AXUIElement, index: Int, isLeaf: Bool) -> FocusNode {
        let role = e.role
        let id = trimmed(e.string(kAXIdentifierAttribute)).isEmpty ? trimmed(e.string("AXDOMIdentifier")) : trimmed(e.string(kAXIdentifierAttribute))
        var text = trimmed(e.string(kAXTitleAttribute))
        if text.isEmpty { text = trimmed(e.string(kAXDescriptionAttribute)) }
        if text.isEmpty, (isLeaf || role == "AXRow" || role == "AXCell"), !textInputRoles.contains(role) {
            text = trimmed(ElementMatcher.text(of: e))
        }
        return FocusNode(role: role, id: id, text: String(text.prefix(120)), index: index)
    }

    /// The fingerprint of `e` under `root` (nil: under its window). nil when `e` is not under the root, or the budget ends.
    nonisolated public static func fingerprint(of e: AXUIElement, root: AXUIElement?, budget: TimeInterval = 0.4) -> FocusFingerprint? {
        let deadline = Date().addingTimeInterval(budget)
        var chain = [e]
        var top: AXUIElement?
        var cur = e
        var hops = 0
        while hops < 40, Date() < deadline, let p = cur.element(kAXParentAttribute) {
            hops += 1
            if let root { if CFEqual(p, root) { top = p; break } }
            else if p.role == "AXWindow" { top = p; break }
            if p.role == "AXApplication" { return nil }
            chain.append(p)
            cur = p
        }
        guard let top else { return nil }
        let ordered = Array(chain.reversed())
        var nodes: [FocusNode] = []
        var parent = top
        for (i, x) in ordered.enumerated() {
            guard Date() < deadline else { return nil }
            let siblings = parent.elements(kAXChildrenAttribute)
            let at = siblings.firstIndex { CFEqual($0, x) } ?? 0
            nodes.append(node(of: x, index: at, isLeaf: i == ordered.count - 1))
            parent = x
        }
        let window = root == nil ? top : (top.element(kAXWindowAttribute))
        return FocusFingerprint(windowTitle: normalise(trimmed(window?.string(kAXTitleAttribute))), nodes: nodes)
    }

    /// The element a fingerprint names under `root`, or nil. At each level the children are looked at nearest their
    /// old place first; the best few are tried in turn, so one wrong turn among nameless groups does not lose the
    /// place. Bounded by `budget` and by 400 children a level.
    nonisolated public static func find(_ fp: FocusFingerprint, under root: AXUIElement, budget: TimeInterval = 0.8) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(budget)
        func descend(_ parent: AXUIElement, _ level: Int) -> AXUIElement? {
            guard level < fp.nodes.count, Date() < deadline else { return nil }
            let want = fp.nodes[level]
            let isLeaf = level == fp.nodes.count - 1
            let kids = parent.elements(kAXChildrenAttribute)
            var found: [(AXUIElement, Int)] = []
            var strong = 0
            for i in order(count: kids.count, around: want.index).prefix(400) {
                if Date() >= deadline { break }
                let have = node(of: kids[i], index: i, isLeaf: isLeaf)
                guard let s = score(want, have, isLeaf: isLeaf) else { continue }
                found.append((kids[i], s))
                if s >= 60 { strong += 1 }
                if strong >= (isLeaf ? 1 : 2) || found.count >= 6 { break }
            }
            found.sort { $0.1 > $1.1 }
            for (child, _) in found.prefix(3) {
                if isLeaf { return child }
                if let hit = descend(child, level + 1) { return hit }
            }
            return nil
        }
        return descend(root, 0)
    }

    // MARK: Per application (main thread)

    /// The last focus of each application, as it was announced: a reference and nothing else, no accessibility call.
    private static var lastFocus: [pid_t: AXUIElement] = [:]
    /// What each application remembered, by window title.
    private static var places: [pid_t: [String: FocusFingerprint]] = [:]
    /// Where a region was left (the key: pid, then the part's name).
    private static var regions: [String: (place: FocusPlace, at: Date)] = [:]

    /// The focus is `e` (AXHandler.present): cheap, called for every focus change.
    public static func note(_ e: AXUIElement, pid: pid_t) { lastFocus[pid] = e }

    /// An application has gone out of the front: its last focus is fingerprinted, unless it was a menu or said nothing
    /// (a window, a page), which also forgets what was remembered for that window.
    static func leaving(pid: pid_t) {
        guard appEnabled, let e = lastFocus[pid] else { return }
        let role = e.role
        guard role != "?" else { return }
        let title = trimmed(e.string(kAXTitleAttribute)), description = trimmed(e.string(kAXDescriptionAttribute))
        if isMenuRole(role) { return }
        if isGeneric(role: role, title: title, description: description) {
            if let w = e.element(kAXWindowAttribute) ?? (role == "AXWindow" ? e : nil) { places[pid]?[normalise(trimmed(w.string(kAXTitleAttribute)))] = nil }
            return
        }
        guard let fp = fingerprint(of: e, root: nil), fp.isUsable else { Log.io("focus memory: no usable fingerprint for \(role) in pid \(pid)"); return }
        places[pid, default: [:]][fp.windowTitle] = fp
        if (places[pid]?.count ?? 0) > 8 { places[pid] = [fp.windowTitle: fp] }
        Log.io("focus memory: remembered \(role) \"\(Log.words(fp.nodes.last?.text ?? ""))\" in window \"\(Log.words(fp.windowTitle))\" of pid \(pid), \(fp.nodes.count) levels")
    }

    /// An application came to the front a moment ago. If it did not restore a place of its own (its focus is a window,
    /// a page or an empty group), and the user has not pressed a key or opened a dialog, the remembered element gets the focus.
    static func returned(pid: pid_t, activatedAt: Date) {
        guard appEnabled, AXHandler.shared.activePid == pid, let known = places[pid], !known.isEmpty else { return }
        guard InputManager.lastKeyDownAt < activatedAt, !AXHandler.modalInFront(pid: pid), !AXHandler.shared.isMenuOpen else { return }
        let app = AXUIElementCreateApplication(pid)
        guard let window = app.element(kAXFocusedWindowAttribute) else { return }
        let title = normalise(trimmed(window.string(kAXTitleAttribute)))
        guard let fp = known[title] else { Log.io("focus memory: nothing remembered for this window of pid \(pid)"); return }
        let now = app.element(kAXFocusedUIElementAttribute)
        if let now, !isGeneric(role: now.role, title: trimmed(now.string(kAXTitleAttribute)), description: trimmed(now.string(kAXDescriptionAttribute))) {
            Log.io("focus memory: pid \(pid) restored its own focus (\(now.role)); left alone")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let hit = find(fp, under: window)
            DispatchQueue.main.async {
                guard AXHandler.shared.activePid == pid, InputManager.lastKeyDownAt < activatedAt, !AXHandler.modalInFront(pid: pid) else { Log.io("focus memory: the user moved on; not restored"); return }
                guard let hit else { Log.io("focus memory: could not find \"\(Log.words(fp.nodes.last?.text ?? ""))\" again; left alone"); return }
                let how = put(hit, pid: pid)
                Log.io("focus memory: back to \(hit.role) \"\(Log.words(fp.nodes.last?.text ?? ""))\" in pid \(pid) (\(how))")
            }
        }
    }

    /// Puts the focus on an element the best way it allows; says how, for the log.
    @discardableResult
    static func put(_ e: AXUIElement, pid: pid_t) -> String {
        func settable(_ x: AXUIElement) -> Bool {
            var s: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(x, kAXFocusedAttribute as CFString, &s) == .success && s.boolValue
        }
        if e.role == "AXRow", let table = e.element(kAXParentAttribute), ["AXTable", "AXOutline", "AXList"].contains(table.role) {
            if !table.elements(kAXSelectedRowsAttribute).contains(where: { CFEqual($0, e) }) { _ = table.set(kAXSelectedRowsAttribute, [e] as CFArray) }
            if settable(table), table.set(kAXFocusedAttribute, kCFBooleanTrue) == .success { return "row selected, list focused" }
            ObjectNavigator.shared.moveTo(e)
            return "row, review cursor"
        }
        if settable(e), e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success { return "focused" }
        ObjectNavigator.shared.moveTo(e)
        return "review cursor"
    }

    // MARK: Per region (PanesView)

    static func remember(region name: String, pid: pid_t, _ place: FocusPlace) { regions["\(pid)|\(name)"] = (place, Date()) }
    static func recall(region name: String, pid: pid_t) -> (place: FocusPlace, at: Date)? { regions["\(pid)|\(name)"] }
    static func forget(pid: pid_t) { lastFocus[pid] = nil; places[pid] = nil; regions = regions.filter { !$0.key.hasPrefix("\(pid)|") } }
}

/// The two switches, as commands in the key list (assign them there; no key by default).
final class FocusMemoryPlugin: GlobalPlugin {
    required init() {
        super.init()
        script("focusMemoryApp", String(localized: "Turns remembering where you were in an app, when you come back to it, on or off", comment: "A command, as the key list and keyboard help say it"), category: "Waypoint") { _ in
            FocusMemory.appEnabled.toggle()
            Speech.speakMessage(FocusMemory.appEnabled ? String(localized: "app focus memory on", comment: "Spoken message") : String(localized: "app focus memory off", comment: "Spoken message"))
        }
        script("focusMemoryRegions", String(localized: "Turns remembering your place in each part of a window on or off", comment: "A command, as the key list and keyboard help say it"), category: "Waypoint") { _ in
            FocusMemory.regionsEnabled.toggle()
            Speech.speakMessage(FocusMemory.regionsEnabled ? String(localized: "part focus memory on", comment: "Spoken message") : String(localized: "part focus memory off", comment: "Spoken message"))
        }
    }
}
