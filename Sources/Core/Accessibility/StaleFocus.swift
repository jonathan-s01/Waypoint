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

    /// Whether the focus the application names should replace the one held: the held one has no text of its own
    /// and the application's is an editable field.
    public static func shouldTake(heldIsEditable: Bool, heldHasText: Bool, namedIsEditable: Bool, same: Bool) -> Bool {
        !same && !heldIsEditable && !heldHasText && namedIsEditable
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
        guard StaleFocus.actsOnField(typedCharacter: gesture.typedCharacter, keyName: gesture.keyName),
              let held = API.focusObject, !RebuiltField.editable.contains(held.role), !held.hasNavigableText,
              API.focusTreeInterceptor?.passThrough ?? true,
              MenuNavigationPlugin.heldBar == nil, MenuNavigationPlugin.heldStatus == nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == held.pid,
              StaleFocus.due() else { return }
        guard let named = AXUIElementCreateApplication(held.pid).element(kAXFocusedUIElementAttribute) else { return }
        let obj = ObjectFactory.make(named)
        guard StaleFocus.shouldTake(heldIsEditable: false, heldHasText: false,
                                    namedIsEditable: RebuiltField.editable.contains(obj.role), same: held.isSameElement(as: named)) else { return }
        Log.io("focus: the keys go to the \(obj.axRole), and TurnOver held the \(held.axRole); the field is the focus now, without a word")
        let window = named.element(kAXWindowAttribute)
        let ancestors = obj.ancestors
        focusWindow = window
        lastGainFocus = (named, Date())
        API.setFocusObject(obj, ancestors: ancestors, interceptor: BrowseModeHandler.shared.document(for: obj, ancestors: ancestors))
        RebuiltField.remember(obj, window: window)
    }
}
