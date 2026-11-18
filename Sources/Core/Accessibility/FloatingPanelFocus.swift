// SPDX-License-Identifier: GPL-3.0-or-later
// A panel the user just asked for with a key (Finder's View Options on Command J) is where they mean to be.
// Finder measured 18 Nov 2026 (macOS 27): the panel is an AXSystemFloatingWindow with a title and controls, but Finder
// keeps AXFocusedWindow and AXFocusedUIElement on the folder window while the panel is open, and says nothing about
// the change, so nothing was announced and the arrows kept moving through the file list. AXRaise followed by AXMain
// moves Finder's own focus into the panel; its focus notifications then speak as for any window.
// Helper panels no key asked for (Word's "Cursor Actions", with no title) stay as they were.
import Foundation
import ApplicationServices

extension AXHandler {
    private static let panelSubroles: Set<String> = ["AXSystemFloatingWindow", "AXFloatingWindow"]
    private static let panelControlRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXTextField", "AXSlider", "AXButton", "AXMenuButton"]

    /// A window just created: take the focus into it when it is a titled floating panel with controls that a key
    /// opened in the application in front.
    func panelOpenedByKey(_ window: AXUIElement, pid: pid_t) {
        let keyAt = InputManager.lastKeyDownAt
        guard pid == activePid, Date().timeIntervalSince(keyAt) < 1.5 else { return }
        // A moment on: the panel's controls are not always in place when the window is announced.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.raisePanel(window, pid: pid) }
    }

    private func raisePanel(_ window: AXUIElement, pid: pid_t) {
        guard pid == activePid, window.role == "AXWindow",
              Self.panelSubroles.contains(window.string(kAXSubroleAttribute) ?? ""),
              !(window.string(kAXTitleAttribute) ?? "").isEmpty,
              window.elements(kAXChildrenAttribute).contains(where: { Self.panelControlRoles.contains($0.role) }) else { return }
        // Already the focused window (an app that does say): nothing to do.
        if let focused = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute), focused.isSame(window) { return }
        Log.io("floating panel opened by a key: raised so the focus moves into it")
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = window.set(kAXMainAttribute, kCFBooleanTrue)
    }
}
