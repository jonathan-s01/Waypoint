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

    /// The words, a pause, then what they are inside. A comma was too short to hear the role as a separate thing, and
    /// the speech has no pause control, so a full stop stands for it (a tester, 13 Nov 2026); words that already end in
    /// punctuation have their own pause.
    package static func said(_ words: String, then context: [String]) -> String {
        guard !context.isEmpty else { return words }
        let tail = context.joined(separator: ", ")
        guard let last = words.last else { return tail }
        return words + (".,;:!?…".contains(last) ? " " : ". ") + tail
    }

    // MARK: Whole paragraphs
    // In a web page a paragraph is a group of text pieces, with the bold, emphasized and linked words as pieces of their
    // own, so a sweep of the pointer along a line stopped at each one. With the setting on, a plain text reads as the
    // paragraph around it (Chrome 13 Nov 2026: an unnamed group of static texts, links, and groups with a subrole
    // ending in StyleGroup for emphasis; a heading holds its pieces the same way).

    /// A paragraph longer than this is not read whole: the piece under the pointer is said as before.
    static let paragraphLimit = 1000
    /// The most pieces joined into one paragraph.
    static let paragraphPieces = 80
    /// How far up from a paragraph the web page is looked for. Other apps' text is never read as a paragraph.
    static let webAreaLevels = 30

    package enum BlockStep: Equatable { case inline, link, block, stop }

    /// How an element above a text counts on the way to its paragraph: a link or emphasis group is part of the
    /// paragraph's own text, a group, heading, list item or cell is the paragraph, and anything else ends the look.
    package static func blockStep(role: String, subrole: String) -> BlockStep {
        if role == "AXLink" { return .link }
        if subrole.hasSuffix("StyleGroup") { return .inline }
        if ["AXGroup", "AXHeading", "AXListItem", "AXCell"].contains(role) || subrole == "AXListItem" { return .block }
        return .stop
    }

    /// The paragraph a text or link is part of, and whether the way to it went through a link. Nil in any app but a web
    /// page, and when the structure is not the usual one.
    package static func paragraph(of e: AXUIElement, deadline: Date) -> (element: AXUIElement, insideLink: Bool)? {
        var link = false
        var cur = e
        for _ in 1...levels {
            guard Date() < deadline, let p = cur.element(kAXParentAttribute) else { return nil }
            AXUIElementSetMessagingTimeout(p, PointerReader.messagingTimeout)
            let a = p.attrs([kAXRoleAttribute, kAXSubroleAttribute])
            let role = (a[kAXRoleAttribute] as? String) ?? "", subrole = (a[kAXSubroleAttribute] as? String) ?? ""
            switch blockStep(role: role, subrole: subrole) {
            case .link: link = true
            case .inline: break
            case .block: return isInWebPage(p, deadline: deadline) ? (p, link) : nil
            case .stop: return nil
            }
            cur = p
        }
        return nil
    }

    private static func isInWebPage(_ e: AXUIElement, deadline: Date) -> Bool {
        var cur = e
        for _ in 1...webAreaLevels {
            guard Date() < deadline, let p = cur.element(kAXParentAttribute) else { return false }
            switch p.role {
            case "AXWebArea": return true
            case "AXWindow", "AXApplication": return false
            default: cur = p
            }
        }
        return false
    }

    /// The words of a paragraph, in order, or nil when it is too long, has none, or the deadline came first.
    package static func paragraphText(_ block: AXUIElement, deadline: Date) -> String? {
        var out = ""
        var pieces = 0
        var ok = true
        func walk(_ e: AXUIElement, depth: Int) {
            for c in e.elements(kAXChildrenAttribute) {
                guard ok, Date() < deadline, pieces < paragraphPieces, out.count <= paragraphLimit else { ok = false; return }
                AXUIElementSetMessagingTimeout(c, PointerReader.messagingTimeout)
                let a = c.attrs([kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute])
                let role = (a[kAXRoleAttribute] as? String) ?? "", subrole = (a[kAXSubroleAttribute] as? String) ?? ""
                if role == "AXStaticText" {
                    if let v = a[kAXValueAttribute] as? String { out += v; pieces += 1 }
                } else if depth < 3, blockStep(role: role, subrole: subrole) == .link || blockStep(role: role, subrole: subrole) == .inline {
                    walk(c, depth: depth + 1)
                }
            }
        }
        walk(block, depth: 0)
        let text = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return ok && !text.isEmpty && text.count <= paragraphLimit ? text : nil
    }

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
                             kAXDescriptionAttribute, kAXValueAttribute, "AXHeadingLevel"])
            func text(_ k: String) -> String { (a[k] as? String) ?? "" }
            let role = text(kAXRoleAttribute)
            if role == "AXWindow" || role == "AXWebArea" || role == "AXApplication" { break }
            let named = !text(kAXTitleAttribute).isEmpty || !text(kAXDescriptionAttribute).isEmpty
            let subrole = text(kAXSubroleAttribute)
            switch kind(role: role, subrole: subrole, named: named, distance: distance) {
            case .control:
                let w = word(role: role, subrole: subrole, roleDescription: text(kAXRoleDescriptionAttribute),
                             headingLevel: ((a["AXHeadingLevel"] ?? a[kAXValueAttribute]) as? NSNumber)?.intValue)
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
