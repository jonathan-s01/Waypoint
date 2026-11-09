import AppKit
import ApplicationServices

/// First-letter navigation in any list, outline or table, whatever its sort order (Finder by date, 9 Nov 2026: the
/// app's own type-select only follows the order it is sorted by). A letter selects the next item whose name starts
/// with it, and the same letter again goes on to the next, round to the start again. Letters typed within a second
/// of each other make a prefix ("do" for Documents). Not in text, in pages read as documents, or in web content.
@MainActor
public enum LetterJump {

    private static let containerRoles: Set<String> = ["AXOutline", "AXTable", "AXList"]
    private static let rowRoles: Set<String> = ["AXOutline", "AXTable"]
    private static let stopRoles: Set<String> = ["AXWindow", "AXWebArea", "AXApplication", "AXSheet", "AXPopover"]
    private static let prefixWindow: TimeInterval = 1.0
    private static let deadline: TimeInterval = 1.5

    private static var typed = ""
    private static var typedAt = Date.distantPast

    /// The list the keyboard is in: the focused element, or one a few steps above it (a row, a cell).
    static func container() -> AXUIElement? {
        guard let f = API.focusObject, !f.hasNavigableText, !ObjectNavigator.shared.isHolding else { return nil }
        if let d = API.focusTreeInterceptor, !d.passThrough { return nil }
        if typingPid == f.pid, Date().timeIntervalSince(typingAt) < 20 { return nil }
        var e: AXUIElement? = f.element; var hops = 0
        while let x = e, hops < 4 {
            let role = x.role
            if containerRoles.contains(role) { return x }
            if stopRoles.contains(role) || ItemActions.isText(x) { return nil }
            e = x.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    static func items(of list: AXUIElement) -> [AXUIElement] {
        let rows = list.elements(kAXRowsAttribute)
        if !rows.isEmpty || rowRoles.contains(list.role) { return rows }
        let children = list.elements(kAXChildrenAttribute).filter { !["AXScrollBar", "AXColumn"].contains($0.role) }
        // Finder's icon view is a collection whose only children are sections; the icons are inside them (9 Nov 2026, macOS 27).
        if !children.isEmpty, children.allSatisfy({ $0.role == "AXList" }) { return children.flatMap { $0.elements(kAXChildrenAttribute) } }
        return children
    }

    /// Typing in a text field that shows suggestions moves the accessibility focus to the highlighted suggestion
    /// while the keys still go to the field (OneDrive's share box, 9 Nov 2026). Until Tab, Escape or Return, or
    /// 20 s without typing, letters belong to the field.
    private static var typingAt = Date.distantPast
    private static var typingPid: pid_t = 0

    /// The TurnOver key was pressed: the timers end now, so the next letter is a new jump and letters are not left to
    /// a field that was typed in.
    public static func reset() {
        typed = ""; typedAt = .distantPast; typingAt = .distantPast
    }

    /// Called for each key passed on to the application.
    static func noteKey(_ g: KeyboardGesture) {
        let key = g.keyName
        if ["tab", "escape", "enter", "numpadEnter"].contains(key) || g.modifiers.contains(.command) { typingAt = .distantPast; return }
        guard g.typedCharacter != nil, let f = API.focusObject else { return }
        if f.hasNavigableText || (typingPid == f.pid && Date().timeIntervalSince(typingAt) < 20) {
            typingAt = Date(); typingPid = f.pid
        }
    }

    static func selectedIndex(in items: [AXUIElement], of list: AXUIElement) -> Int? {
        let selected = list.elements(kAXSelectedRowsAttribute) + list.elements(kAXSelectedChildrenAttribute)
        guard let last = selected.last else { return nil }
        return items.firstIndex { $0.isSame(last) }
    }

    /// The text of the letters typed: what to look for, and whether it is one letter pressed again (cycling).
    nonisolated public static func query(typed: String, key: String, within: Bool) -> (text: String, cycling: Bool) {
        let all = within ? typed + key : key
        if all.count > 1, Set(all).count == 1 { return (key, true) }
        return (all, all.count == 1)
    }

    /// Letters compared as a person hears them: no case, no accents, no leading spaces.
    nonisolated public static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The index to go to: the next from `current` (cycling, or a first letter), or from it inclusive (a longer
    /// prefix: "do" stays on Documents), wrapping round. nil: nothing starts with it. `name` is asked only as far as needed.
    nonisolated public static func target(count: Int, current: Int?, text: String, cycling: Bool, name: (Int) -> String, expired: () -> Bool = { false }) -> Int? {
        guard count > 0 else { return nil }
        let want = fold(text)
        guard !want.isEmpty else { return nil }
        let start = (current ?? -1) + (cycling || current == nil ? 1 : 0)
        for step in 0..<count {
            if expired() { return nil }
            let i = ((start + step) % count + count) % count
            if fold(name(i)).hasPrefix(want) { return i }
        }
        return nil
    }

    static func press(_ key: String) {
        guard let list = container() else { return }
        let now = Date()
        let q = query(typed: typed, key: key, within: now.timeIntervalSince(typedAt) < prefixWindow)
        typed = q.cycling ? key : q.text; typedAt = now
        let all = items(of: list)
        guard !all.isEmpty else { Tones.edge(); Speech.speakMessage(String(localized: "empty", comment: "A list with nothing in it")); return }
        let started = Date()
        let current = selectedIndex(in: all, of: list)
        let hit = target(count: all.count, current: current, text: q.text, cycling: q.cycling,
                         name: { ObjectFactory.make(all[$0]).name }, expired: { Date().timeIntervalSince(started) > deadline })
        guard let i = hit else {
            Log.io("letter jump: nothing starts with \(q.text) in \(all.count) items")
            Tones.edge()
            Speech.speakMessage(String(localized: "Nothing starts with \(q.text)", comment: "Spoken message: %@ is the letters typed"))
            return
        }
        select(all[i], in: list)
        let obj = ObjectFactory.make(all[i])
        TurnOverObject.noteSelectionSpoken(all[i])
        Speech.speakObject(obj, reason: .selection)
        Log.io("letter jump: \(q.text) -> item \(i + 1) of \(all.count)")
    }

    private static func select(_ item: AXUIElement, in list: AXUIElement) {
        _ = AXUIElementPerformAction(item, "AXScrollToVisible" as CFString)
        let isRow = rowRoles.contains(list.role) || item.role == "AXRow"
        var err = list.set(isRow ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute, [item] as CFArray)
        if err != .success { err = item.set(kAXSelectedAttribute, kCFBooleanTrue) }
        if err != .success { Log.warning("letter jump: could not select (\(err.rawValue)) in \(list.role)") }
    }
}

/// The letters and digits, bound to LetterJump where the keyboard is in a list.
final class LetterJumpPlugin: GlobalPlugin {
    required init() {
        super.init()
        for key in "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init) {
            script("letterJump_\(key)", String(localized: "In a list: the next item that starts with this letter, round again", comment: "A command, as the key list and keyboard help say it"),
                   gestures: ["kb:\(key)"], category: "Lists") { _ in LetterJump.press(key) }
                .isAvailable = { LetterJump.container() != nil }
        }
    }
}
