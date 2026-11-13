// SPDX-License-Identifier: GPL-3.0-or-later
// What the text or image under the mouse pointer sits inside. Browsers (Safari and Chrome) and many apps put the
// words in a plain text element inside the link, heading or button, so the pointer reading said only the words and
// never "link" or "heading level 2". The words of the item around it are found here and said after the content, as
// VoiceOver does: "Discover, heading level 2". Runs on the lookup queue only, like the rest of the pointer's reading.
import Foundation
import ApplicationServices

nonisolated package enum PointerContext {
    /// How many levels above the text or image are looked at. A text is at most a few levels inside its link or
    /// heading; going further would name far-off groups for every paragraph.
    static let levels = 4
    /// The most words said after the content (a heading that is also a link: "heading level 2, link").
    static let mostWords = 2

    /// Roles that say what an item does or is: all of those found on the way up are said.
    private static let controls: Set<String> = ["AXLink", "AXHeading", "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem",
        "AXTab", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle"]
    /// Roles that only say where the text is (a cell, a list item): said when no control is around the text, and the
    /// walk ends at the first one.
    private static let containers: Set<String> = ["AXRow", "AXCell"]

    package enum Kind: Equatable { case control, container, none }

    /// How an element above the text counts. `distance` is how many levels above the text it is (1 is the parent). A
    /// group says something only when it has a name and is the parent itself: a web page nests groups many deep, and a
    /// named landmark far above would be said for every paragraph.
    package static func kind(role: String, subrole: String, named: Bool, distance: Int) -> Kind {
        if controls.contains(role) { return .control }
        if containers.contains(role) || role == "AXListItem" || subrole == "AXListItem" { return .container }
        if role == "AXGroup", named, distance == 1 { return .container }
        return .none
    }

    /// The words for one element above the text: its role in the app's own words, and a heading's level.
    package static func word(role: String, subrole: String, roleDescription: String, headingLevel: Int?) -> String {
        if role == "AXHeading", let level = headingLevel, level > 0 { return Phrases.headingLevel(level) }
        var s = PointerSnapshot()
        s.axRole = role; s.subrole = subrole; s.roleDescription = roleDescription
        let word = PointerReader.roleWord(s)
        if word.isEmpty, subrole == "AXListItem" || role == "AXListItem" {
            return String(localized: "list item", comment: "A role, spoken after the words of an item in a list")
        }
        return word
    }

    /// The words of what `e` (a text or image) is inside, nearest first, or none. Stops at the deadline.
    package static func words(above e: AXUIElement, deadline: Date) -> [String] {
        var found: [String] = []
        var container: String?
        var cur = e
        for distance in 1...levels {
            guard Date() < deadline, let p = cur.element(kAXParentAttribute) else { break }
            AXUIElementSetMessagingTimeout(p, PointerReader.messagingTimeout)
            let a = p.attrs([kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute,
                             kAXDescriptionAttribute, "AXHeadingLevel"])
            func text(_ k: String) -> String { (a[k] as? String) ?? "" }
            let role = text(kAXRoleAttribute)
            if role == "AXWindow" || role == "AXWebArea" || role == "AXApplication" { break }
            let named = !text(kAXTitleAttribute).isEmpty || !text(kAXDescriptionAttribute).isEmpty
            let subrole = text(kAXSubroleAttribute)
            switch kind(role: role, subrole: subrole, named: named, distance: distance) {
            case .control:
                let w = word(role: role, subrole: subrole, roleDescription: text(kAXRoleDescriptionAttribute),
                             headingLevel: (a["AXHeadingLevel"] as? NSNumber)?.intValue)
                if !w.isEmpty, !found.contains(w) { found.append(w) }
            case .container:
                container = word(role: role, subrole: subrole, roleDescription: text(kAXRoleDescriptionAttribute), headingLevel: nil)
            case .none: break
            }
            if container != nil { break }
            cur = p
        }
        if !found.isEmpty { return Array(found.prefix(mostWords)) }
        return container.flatMap { $0.isEmpty ? nil : [$0] } ?? []
    }
}
