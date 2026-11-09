// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's "Describe this app" (plan 4.3): a short overview of the app in front, so the user who has just opened an
// unfamiliar app can learn its layout without exploring it. Once: the app, the window, and the parts of the window (an
// app with a panes recipe) with the one you are in, or else the item you are on. Twice quickly: the same as a list, in
// TurnOver's own list, where Return goes to a part.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

nonisolated public enum DescribeApp {
    /// "1, Sidebar", and for the part the user is in "2, Messages, you are here".
    public static func regionLines(regions: [String], current: Int?) -> [String] {
        regions.enumerated().map { i, name in
            let line = "\(i + 1), \(name)"
            return i == current ? String(localized: "\(line), you are here", comment: "Spoken in the overview of an app: %@ is the number and name of a part of the window") : line
        }
    }

    /// What kind of window, in a word, when it has no title: nil for an ordinary window.
    public static func windowKind(role: String?, subrole: String?) -> String? {
        switch subrole ?? "" {
        case "AXDialog", "AXSystemDialog": return String(localized: "dialog", comment: "A kind of window")
        case "AXFloatingWindow", "AXSystemFloatingWindow": return String(localized: "floating window", comment: "A kind of window")
        default: break
        }
        switch role ?? "" {
        case "AXSheet": return String(localized: "sheet", comment: "A kind of window")
        case "AXDrawer": return String(localized: "drawer", comment: "A kind of window")
        default: return nil
        }
    }

    /// The overview, as one text to speak: sentences joined by ". ". `focus` is said when the window has no parts, or
    /// the part the user is in is not known.
    public static func overview(app: String, window: String?, kind: String?, regions: [String], current: Int?, focus: String?) -> String {
        var out: [String] = [app]
        let title = window?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            out.append(String(localized: "window: \(title)", comment: "Spoken in the overview of an app: %@ is the title of its front window"))
        } else if let kind {
            out.append(kind)
        }
        if !regions.isEmpty {
            out.append(regions.count == 1 ? String(localized: "1 part", comment: "Spoken in the overview of an app: how many parts the window has")
                       : String(localized: "\(String(regions.count)) parts", comment: "Spoken in the overview of an app: how many parts the window has"))
            out.append(contentsOf: regionLines(regions: regions, current: current))
        }
        if regions.isEmpty || current == nil, let focus, !focus.isEmpty {
            out.append(String(localized: "focus: \(focus)", comment: "Spoken in the overview of an app: %@ is the item that has the keyboard focus"))
        }
        return out.joined(separator: ". ")
    }
}

/// Describe this app: once, an overview; twice, the overview as a list.
final class DescribeAppPlugin: GlobalPlugin {
    required init() {
        super.init()
        script("describeApp", String(localized: "Describes the app in front: its window and the parts of it; pressed twice, as a list to move to a part", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:control+command+0"], category: "Waypoint") { _ in
            guard let pid = API.focusPid else { Speech.speakMessage(String(localized: "no app in front", comment: "Spoken message")); return }
            Self.describe(pid: pid, asList: ScriptHandler.lastScriptRepeatCount > 0)
        }
    }

    private static func describe(pid: pid_t, asList: Bool) {
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? String(localized: "this app", comment: "An app whose name is not known")
        let ax = AXUIElementCreateApplication(pid)
        let window = API.focusObject?.element.element(kAXWindowAttribute) ?? ax.element(kAXFocusedWindowAttribute) ?? ax.element(kAXMainWindowAttribute)
        let title = window?.string(kAXTitleAttribute)
        let kind = DescribeApp.windowKind(role: window?.string(kAXRoleAttribute), subrole: window?.string(kAXSubroleAttribute))
        let view = PanesView.current(pid: pid)
        let regions = view?.parts.map(\.name) ?? []
        let current = view?.currentIndex()
        var focus: String?
        if let f = API.focusObject {
            let name = f.name, role = f.role.displayString
            focus = name.isEmpty ? role : "\(name), \(role)"
        }
        let text = DescribeApp.overview(app: appName, window: title, kind: kind, regions: regions, current: current, focus: focus)
        guard asList else { Speech.speakMessage(text); return }

        var items: [MenuItem] = []
        if let view, !regions.isEmpty {
            let lines = DescribeApp.regionLines(regions: regions, current: current)
            items = lines.enumerated().map { i, line in MenuItem(verbatim: line, .action { view.go(to: i) }) }
        } else {
            let head = DescribeApp.overview(app: appName, window: title, kind: kind, regions: [], current: nil, focus: focus)
            items = head.components(separatedBy: ". ").map { MenuItem(verbatim: $0, .action {}) }
            items.append(MenuItem(verbatim: String(localized: "Items in this window", comment: "An entry in the overview list of an app: opens the list of every item in the window"), .action { ItemChooser.open() }))
        }
        TurnOverMenu.shared.openList(verbatim: String(localized: "About \(appName)", comment: "Title of the overview list of an app: %@ is the app's name"), items: items)
    }
}
