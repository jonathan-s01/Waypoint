// SPDX-License-Identifier: GPL-3.0-or-later
// A text field the web page throws away and builds again while you type in it.
//
// Editors that offer "@", "#" or "/" menus (Teams, Outlook on the web, Copilot, Gemini, Slack, chat boxes built on
// Lexical, Slate or ProseMirror) often replace the whole field, not only its text, as the text changes. The browser
// then reports a new element with the focus after every key. Taken for a move to another control it was announced
// again ("Message, text area, ..." with the text so far) over the echo of the key, and the old element, no longer
// there, stayed TurnOver's focus: the caret, the word just typed and the changes in its value were all asked of
// something gone. Measured with a test page that rebuilds its editor on each key (Chrome, 12 Nov 2026): a focus loss
// and gain, and the field announced again, after every one of twelve keys.
import Foundation
import ApplicationServices
import TurnOverAX

/// What TurnOver knows of the editable field that has the focus, kept so that its replacement can be recognised after
/// the original is gone and can no longer be asked.
enum RebuiltField {
    struct Fingerprint {
        let element: AXUIElement
        let pid: pid_t
        let role: Role
        let name: String
        let window: AXUIElement?
    }
    private static var last: Fingerprint?
    /// A key and the new field must be this close for the field to count as the same one rebuilt.
    static let patience: TimeInterval = 5

    static let editable: Set<Role> = [.editableText, .searchField, .comboBox]

    /// Called when a focus is presented. Only editable fields are kept.
    static func remember(_ obj: TurnOverObject, window: AXUIElement?) {
        guard editable.contains(obj.role) else { last = nil; return }
        last = Fingerprint(element: obj.element, pid: obj.pid, role: obj.role, name: obj.name, window: window)
    }

    /// Whether an element no longer exists (the page took it away) and not merely does not answer.
    nonisolated static func isGone(_ e: AXUIElement) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v) == .invalidUIElement
    }

    /// Whether the focus reported for `target` is the editable field TurnOver already has, built again: the old
    /// element is gone, and the new one has the same role and name in the same window.
    static func replaces(_ target: AXUIElement, pid: pid_t, role: Role, name: String, window: AXUIElement?) -> Bool {
        guard let was = last, was.pid == pid, was.role == role, was.name == name,
              !was.element.isSame(target), isGone(was.element) else { return false }
        if let a = was.window, let b = window { return a.isSame(b) }
        return was.window == nil && window == nil
    }
}

extension AXHandler {
    /// The focus moved to a field that is the one TurnOver has, rebuilt by the page: no news. The new element takes
    /// the old one's place, so the caret, the value and the word being typed are asked of the field that exists.
    func ruleRebuiltField(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard let cur = API.focusObject, cur.pid == pid, RebuiltField.editable.contains(cur.role),
              Date().timeIntervalSince(InputManager.lastKeyDownAt) < RebuiltField.patience,
              !cur.isSameElement(as: target) else { return .go(target) }
        let obj = ObjectFactory.make(target)
        let window = target.element(kAXWindowAttribute)
        guard RebuiltField.replaces(target, pid: pid, role: obj.role, name: obj.name, window: window) else { return .go(target) }
        let ancestors = obj.ancestors
        Log.io("focus: the \(obj.axRole) was rebuilt by the page (the old one is gone); kept as the focus without a word")
        focusWindow = window
        lastGainFocus = (target, Date())
        API.setFocusObject(obj, ancestors: ancestors, interceptor: BrowseModeHandler.shared.document(for: obj, ancestors: ancestors))
        RebuiltField.remember(obj, window: window)
        return .done
    }
}
