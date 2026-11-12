import ApplicationServices

// What the review layer does on its own account, apart from the document's quick keys: where it starts in a chat, and
// its Tab, which moves the review cursor and never the real focus.

/// Where a chat's messages begin. Observed in the GitHub Copilot app on 12 Nov 2026: each message is a level 2
/// heading titled "You said: ..." or "Copilot said: ...", and the tool calls inside a message are level 3.
nonisolated public enum ReviewStart {
    public static func isMessageHeading(title: String?, level: Int?) -> Bool {
        guard level == 2, let title else { return false }
        return title.hasPrefix("You said:") || title.hasPrefix("Copilot said:")
    }
}

extension BrowseModeDocument {

    /// The start of the last message before `offset`, nil when the page has no such headings above it.
    func lastMessageStart(before offset: Int) -> Int? {
        guard var i = buffer.lineIndex(at: offset) else { return nil }
        while i >= 0 {
            let line = buffer.lines[i]
            let heading = line.element?.role == "AXHeading" ? line.element : line.entering.first { $0.role == "AXHeading" }
            if let heading,
               ReviewStart.isMessageHeading(title: heading.string(kAXTitleAttribute), level: (heading.attr(kAXValueAttribute) as? NSNumber)?.intValue) {
                return line.start
            }
            i -= 1
        }
        return nil
    }

    /// The review layer's Tab: the next (or previous) link or control after the review cursor. Unlike the document's own
    /// Tab, the real focus stays where it is.
    func reviewTab(forward: Bool) {
        guard ensureContent() else { return }
        let roles: Set<String> = ["AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXMenuButton", "AXDisclosureTriangle"]
        guard let (at, el) = buffer.find(from: position, forward: forward, roles: roles) else {
            Tones.edge()
            Speech.speakMessage(Phrases.noNext(String(localized: "link or control", comment: "A kind of thing to find, after next or previous"), forward: forward))
            return
        }
        position = at
        lastQuickNavTarget = el
        if BrowseModeDocument.controlRoles.contains(el.role), !(el.role == "AXLink" && buffer.linkEnd(at: at) != nil) {
            Speech.speakMessage(Speech.objectPropertiesSpeech(ObjectFactory.make(el), reason: .focus).joined(separator: ", "))
            lastChain = []
        } else {
            speakQuickNavText(at: at, link: el.role == "AXLink", element: el)
        }
    }
}
