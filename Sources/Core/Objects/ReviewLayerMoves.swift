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

    /// The review layer's interact (Right and Down): into the list, table or other container that begins on this line or
    /// the next, on its first item. The nearest, outermost one when several begin together.
    func reviewInteract() {
        guard ensureContent(), let i = buffer.lineIndex(at: position) else { Tones.edge(); return }
        let reach = i + 2 < buffer.lines.count ? buffer.lines[i + 2].start : buffer.text.length
        let inside = buffer.containers.filter { $0.start > position && $0.start < reach }
        guard let c = inside.min(by: { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }) else {
            Tones.edge()
            Speech.speakMessage(String(localized: "no items inside", comment: "Spoken message"))
            return
        }
        if !VoiceOverSounds.play("DrillIn.aiff") { Tones.beep(660, 30) }
        position = c.start
        speakUnit(.line)
    }

    /// The review layer's stop interacting (Left and Down): out of the innermost container holding the cursor, onto the
    /// line before it, where it began; the top of the page is the top level.
    func reviewStopInteracting() {
        guard ensureContent() else { Tones.edge(); return }
        guard let c = buffer.containers.filter({ $0.start <= position && position < $0.end }).min(by: { $0.end - $0.start < $1.end - $1.start }),
              c.start > 0, let at = buffer.lineIndex(at: c.start), at > 0 else {
            Tones.edge()
            Speech.speakMessage(String(localized: "top level", comment: "Spoken message"))
            return
        }
        if !VoiceOverSounds.play("DrillOut.aiff") { Tones.beep(440, 30) }
        position = buffer.lines[at - 1].start
        speakUnit(.line)
    }
}
