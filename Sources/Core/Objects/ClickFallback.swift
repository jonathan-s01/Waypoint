// SPDX-License-Identifier: GPL-3.0-or-later
// Click the item: the last resort when an item has nothing to press and will not take the focus. Copilot's chats
// under each project (16 Nov 2026, macOS 27) have no press action, answer success to a focus request and do not move
// it, ignore a selection, and open only for a real click. The click is the one mechanism here: the safe centre click
// (VO-Shift-Space uses the same), and the per-app switch (a recipe's "clickFallback": false turns it off).
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

public enum ClickFallback {
    /// What is at the item's centre.
    enum Hit { case inside, covered, unknown }

    /// Whether a recipe turns the click off for this app: "clickFallback": false. Absent means on, as it does for an
    /// app with no recipe.
    static func allowed(pid: pid_t) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return true }
        return allowed(recipe: Recipes.recipe(for: bundle))
    }

    public static func allowed(recipe: Recipe?) -> Bool { recipe?.clickFallback ?? true }

    /// The item's centre on screen, nil when it has no usable frame.
    static func centre(of e: AXUIElement) -> CGPoint? {
        guard let f = TurnOverObject.frame(e), f.width > 1, f.height > 1 else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// Whether the thing at `p` is the item or something inside it; `covered` when something else is over it.
    static func hit(_ e: AXUIElement, at p: CGPoint) -> Hit {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &found) == .success, let h = found else { return .unknown }
        var x: AXUIElement? = h; var hops = 0
        while let y = x, hops < 8 { if CFEqual(y, e) { return .inside }; x = y.element(kAXParentAttribute); hops += 1 }
        return .covered
    }

    /// A click (or two) at `p`, the pointer put back after.
    static func perform(at p: CGPoint, count: Int = 1) {
        let back = CGEvent(source: nil)?.location
        Mouse.click(at: p, button: .left, count: count)
        if let b = back { Mouse.move(to: b) }
    }

    /// Click the item's centre when the app allows it and the item is really there: on screen, with nothing else over
    /// it. Says "clicked" (not the press tone) so it is known when this was what worked. False when nothing was done.
    @discardableResult
    static func click(_ e: AXUIElement) -> Bool {
        guard allowed(pid: e.pid) else { return false }
        _ = AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
        guard let p = centre(of: e), hit(e, at: p) == .inside else { return false }
        perform(at: p)
        let app = NSRunningApplication(processIdentifier: e.pid)?.bundleIdentifier ?? "pid \(e.pid)"
        Log.io("click fallback: clicked \(e.role) in \(app)")
        Speech.speakMessage(String(localized: "clicked", comment: "Spoken message: an item was activated by a mouse click because nothing else worked"))
        return true
    }
}
