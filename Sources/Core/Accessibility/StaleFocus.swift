// SPDX-License-Identifier: GPL-3.0-or-later
// The focus TurnOver holds is not the field that has the keys.
//
// Teams (the Chat box, "Type a message", 13 Nov 2026) reported the focus on the page's group ("Chat | Name - Web
// content") a moment after a key and a transient window opened. The text area never reported the focus again, though
// the application still named it the focused element: the keys went on to it for thirty seconds, its caret and value
// events were set aside as another element's, and the typed characters were asked of a group that has no text, so
// nothing typed was read. A key that goes to the application checks, then, that the field it types into is the focus.
import AppKit
import ApplicationServices
import TurnOverAX

public enum StaleFocus {
    /// The keys that act on a field's text or caret: typed characters, Backspace and the arrows.
    public static func actsOnField(typedCharacter: Character?, keyName: String) -> Bool {
        typedCharacter != nil || ["backspace", "leftArrow", "rightArrow", "upArrow", "downArrow"].contains(keyName)
    }

    /// Whether the focus the application names should replace the one held: the application's is an editable field,
    /// and the held one is gone (the page threw it away and sent no news, GitHub Copilot's chat box, 13 Nov 2026) or
    /// has no text of its own.
    public static func shouldTake(heldIsEditable: Bool, heldHasText: Bool, heldIsGone: Bool = false, namedIsEditable: Bool, same: Bool) -> Bool {
        !same && namedIsEditable && (heldIsGone || (!heldIsEditable && !heldHasText))
    }

    /// The keys a field gets while a popup holds the focus. Up and Down are the popup's own (its list of suggestions).
    public static func actsOnFieldBehindPopup(typedCharacter: Character?, keyName: String) -> Bool {
        typedCharacter != nil || ["backspace", "leftArrow", "rightArrow"].contains(keyName)
    }

    /// A field still has the keys when its news followed a key lately and the popup it was news behind is still the focus.
    public static func fieldHasKeysBehind(sameHeld: Bool, newsAge: TimeInterval) -> Bool { sameHeld && newsAge < behindPatience }
    static let behindPatience: TimeInterval = 30

    /// The field whose caret or value moved just after a key, while something else without text held the focus.
    private static var behind: (field: AXUIElement, held: AXUIElement, at: Date)?

    /// Teams' suggestion list (the focus goes to its group, 16 Nov 2026) takes the focus while the text area goes on
    /// receiving the keys, and says so only by its news: its caret and value moved after each key.
    static func noteFieldNews(_ event: Event) {
        guard event.kind == .caret || event.kind == .valueChange,
              RebuiltField.editable.contains(event.obj.role),
              Date().timeIntervalSince(InputManager.lastKeyDownAt) < 0.5,
              let held = API.focusObject, held.pid == event.obj.pid, !held.isSameElement(as: event.obj),
              !RebuiltField.editable.contains(held.role), !held.hasNavigableText else { return }
        if behind == nil || !(behind!.held.isSame(held.element)) { Log.io("focus: news from the \(event.obj.axRole) after a key while the \(held.axRole) holds the focus") }
        behind = (event.obj.element, held.element, Date())
    }

    static func fieldBehind(held: AXUIElement) -> AXUIElement? {
        guard let b = behind, fieldHasKeysBehind(sameHeld: b.held.isSame(held), newsAge: Date().timeIntervalSince(b.at)),
              b.field.attr(kAXSelectedTextRangeAttribute) != nil else { return nil }
        return b.field
    }

    /// Asking the application costs a call to it, so not on every key while nothing is wrong.
    private static var lastLook = Date.distantPast
    static let spacing: TimeInterval = 0.25
    static func due(_ now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastLook) >= spacing else { return false }
        lastLook = now
        return true
    }
}

extension AXHandler {
    /// Before a key for a field's text goes to the application: if the application's focused element is an editable
    /// field that TurnOver does not hold, and what it holds has no text, the field takes the place, without a word.
    func followFieldKeysGoTo(_ gesture: KeyboardGesture) {
        if StaleFocus.actsOnFieldBehindPopup(typedCharacter: gesture.typedCharacter, keyName: gesture.keyName),
           let held = API.focusObject, !RebuiltField.editable.contains(held.role), !held.hasNavigableText,
           API.focusTreeInterceptor?.passThrough ?? true, MenuNavigationPlugin.heldBar == nil, MenuNavigationPlugin.heldStatus == nil,
           isInFront(pid: held.pid),
           let field = StaleFocus.fieldBehind(held: held.element) {
            Log.io("focus: the \(held.axRole) holds the focus, but the keys go to the field behind it; the field is the focus now, without a word")
            takeFocusQuietly(field)
            return
        }
        guard StaleFocus.actsOnField(typedCharacter: gesture.typedCharacter, keyName: gesture.keyName),
              let held = API.focusObject,
              API.focusTreeInterceptor?.passThrough ?? true,
              MenuNavigationPlugin.heldBar == nil, MenuNavigationPlugin.heldStatus == nil,
              isInFront(pid: held.pid),
              StaleFocus.due() else { return }
        let gone = RebuiltField.isGone(held.element)
        guard gone || (!RebuiltField.editable.contains(held.role) && !held.hasNavigableText) else { return }
        guard let named = AXUIElementCreateApplication(held.pid).element(kAXFocusedUIElementAttribute) else { return }
        let obj = ObjectFactory.make(named)
        guard StaleFocus.shouldTake(heldIsEditable: false, heldHasText: false, heldIsGone: gone,
                                    namedIsEditable: RebuiltField.editable.contains(obj.role), same: held.isSameElement(as: named)) else { return }
        Log.io("focus: the keys go to the \(obj.axRole), and TurnOver held the \(held.axRole)\(gone ? " (gone)" : ""); the field is the focus now, without a word")
        takeFocusQuietly(named, as: obj)
    }

    /// The application in front, or a helper process of it: Teams' page lives in "com.microsoft.teams2.helper", and the
    /// focus held there is never the pid of the app in front (16 Nov 2026), so the check never passed for it.
    private func isInFront(pid: pid_t) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if front.processIdentifier == pid { return true }
        guard let helper = NSRunningApplication(processIdentifier: pid) else { return false }
        guard let f = front.bundleIdentifier, let b = helper.bundleIdentifier else { return false }
        return b.hasPrefix(f + ".")
    }

    private func takeFocusQuietly(_ element: AXUIElement, as made: TurnOverObject? = nil) {
        let obj = made ?? ObjectFactory.make(element)
        let window = element.element(kAXWindowAttribute)
        let ancestors = obj.ancestors
        focusWindow = window
        lastGainFocus = (element, Date())
        API.setFocusObject(obj, ancestors: ancestors, interceptor: BrowseModeHandler.shared.document(for: obj, ancestors: ancestors))
        RebuiltField.remember(obj, window: window)
    }
}
