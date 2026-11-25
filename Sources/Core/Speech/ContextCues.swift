// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint (25 Nov 2026, the owner: "1 sound when I enter an edit field, 1 where Quick Nav is on, one for reading text,
// one for arrow-key lists like Finder, one for menus ... so that whenever I go somewhere, I instantly know what type of
// interaction I can expect"). One short cue, before the words, when the focus enters a different kind of place.
// It plays only when the kind changes: moving between two rows of one list is silent. A plain control (a button, a
// checkbox) is a place with no cue, so the next field or list after it is cued again.
import Foundation

public enum ContextCues {
    public enum Kind: String, CaseIterable {
        /// Keys type: a text field, or focus mode on a page.
        case edit
        /// Quick Nav keys work: a page in browse mode.
        case quickNav
        /// Text to read, not to type in.
        case reading
        /// A list, table or outline moved through with the arrows (Finder, Mail, Settings).
        case list
        case menu
        case terminal
        case secure
        case dialog
    }

    /// What one focused object says about the place it is in.
    package enum Place: Equatable {
        case cue(Kind)
        /// A control with no cue of its own: it ends the place before it.
        case plain
        /// A container, or something that says nothing about the place: it changes nothing.
        case ignore
    }

    private static var last: Kind?
    private static var lastPlayedAt = Date.distantPast

    /// Cues are on, and Waypoint's own sounds are the ones chosen (VoiceOver's set plays none of Waypoint's inventions).
    static var active: Bool { config.general.contextCues && Tones.chosen }

    /// A cue played in the last tenth of a second: the focus tick leaves it alone.
    static var justPlayed: Bool { Date().timeIntervalSince(lastPlayedAt) < 0.1 }

    /// Forgets the place, when another app comes to the front: its first place is cued again.
    package static func reset() { last = nil }

    /// Enters a place. True if cues handled it (so an older sound for the same thing stays quiet), whether or not a
    /// cue played; false if cues are off, and the older sound plays as before.
    @discardableResult
    package static func enter(_ kind: Kind) -> Bool {
        guard active else { return false }
        guard last != kind else { return true }
        last = kind
        lastPlayedAt = Date()
        Tones.contextCue(kind)
        return true
    }

    /// Browse or focus mode changed in a page (FocusModePolicy.modeSound).
    package static func mode(focus: Bool) {
        if !enter(focus ? .edit : .quickNav) { focus ? Tones.focusMode() : Tones.browseMode() }
    }

    /// The focus landed on an object (before its words).
    package static func focusGained(_ obj: TurnOverObject) {
        switch place(of: obj) {
        case .cue(let kind): enter(kind)
        case .plain: last = nil
        case .ignore: break
        }
    }

    package static func place(of obj: TurnOverObject) -> Place {
        if obj.roleText == "terminal" { return .cue(.terminal) }
        let role = obj.role
        if role == .passwordEdit { return .cue(.secure) }
        let editable = obj.states.contains(.editable) && !obj.states.contains(.readOnly)
        if let page = API.focusTreeInterceptor, EventHandler.sameDocumentProcess(obj.pid, page.webArea.pid) {
            if role == .webArea { return .cue(page.passThrough ? .edit : .quickNav) }
            if editable || [.editableText, .searchField, .comboBox].contains(role) { return .cue(.edit) }
            return .cue(page.passThrough ? .edit : .quickNav)
        }
        switch role {
        case .editableText, .searchField, .comboBox, .dateEditor, .timeEditor:
            return obj.states.contains(.readOnly) ? .cue(.reading) : .cue(.edit)
        case .document, .textFrame:
            return editable ? .cue(.edit) : .cue(.reading)
        case .staticText, .heading, .label:
            return .cue(.reading)
        case .list, .listItem, .table, .tableRow, .tableColumn, .tableCell, .tableHeader, .treeView, .treeViewItem, .outline, .browser, .grid, .cell:
            return .cue(.list)
        case .menu, .menuItem, .checkMenuItem, .radioMenuItem, .popupMenu:
            return .cue(.menu)
        case .dialog, .sheet:
            return .cue(.dialog)
        case .unknown, .window, .drawer, .application, .pane, .groupBox, .splitPane, .separator, .toolBar, .scrollPane, .scrollBar,
             .statusBar, .menuBar, .layoutArea, .layoutItem, .section, .page, .matte, .ruler, .tabControl, .embeddedObject:
            return .ignore
        default:
            return .plain
        }
    }
}
