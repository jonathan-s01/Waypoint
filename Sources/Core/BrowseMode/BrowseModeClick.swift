// SPDX-License-Identifier: GPL-3.0-or-later
// Browse mode: a mouse click on a text field is the person going into it to type (Waypoint).
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

extension BrowseModeDocument {
    private static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static var clickMonitor: Any?

    /// A field the keyboard types into: what a click on it means focus mode, however the mode was set before.
    static func isTextEntry(_ obj: TurnOverObject) -> Bool {
        let s = obj.states
        if s.contains(.unavailable) { return false }
        return s.contains(.editable) || textEntryRoles.contains(obj.axRole)
    }

    /// Whether the left button went down a moment ago: a focus that arrives now is the click's.
    static func clickedJustNow() -> Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown) < 0.7
    }

    /// A click on the field that already has the focus makes no focus event, so the click itself is watched (once, for
    /// every document): browse mode with a field focused and clicked is focus mode. Passive; the click is not touched.
    func watchClicks() {
        guard Self.clickMonitor == nil else { return }
        Self.clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            let location = NSEvent.mouseLocation
            onMain(after: 0.25) { Self.clickedField(at: location) }
        }
    }

    private static func clickedField(at location: NSPoint) {
        guard let d = API.focusTreeInterceptor, !d.passThrough,
              let f = API.focusObject, f.pid == d.webArea.pid, !f.isSameElement(as: d.webArea), isTextEntry(f),
              let screen = NSScreen.screens.first, let frame = TurnOverObject.frame(f.element) else { return }
        let point = CGPoint(x: location.x, y: screen.frame.height - location.y)
        guard frame.insetBy(dx: -2, dy: -2).contains(point) else { return }
        Log.io("browse mode: clicked in \(f.axRole); focus mode (was browse mode, manual \(d.disableAutoPassThrough))")
        d.disableAutoPassThrough = false
        d.setPassThrough(true, announce: true)
    }
}
