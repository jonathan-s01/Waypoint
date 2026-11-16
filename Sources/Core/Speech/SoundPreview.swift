// SPDX-License-Identifier: GPL-3.0-or-later
// The Sounds list in the Waypoint menu (16 Nov 2026: "a quick way to preview all sounds from within Waypoint"). Each item
// plays one sound through the code that plays it in use, so with the sounds setting as it is now it is what is heard
// there: VoiceOver's own files where VoiceOver marks an event with one, Waypoint's own set for the rest, the plain tones
// where a file is missing. The items run and stay in the menu (.select), so the list can be walked and played again.
// Where an event plays a sound from a file name or a tone of its own (a skim tick, VoiceOver's drill in), the same
// call is made here; keep the two together if either changes.
import Foundation
import AppKit

package enum SoundPreview {
    private typealias Entry = (title: String, when: String, play: () -> Void)

    /// The groups, each a list of sounds, as menu items.
    package static func menuItems() -> [MenuItem] {
        var items: [MenuItem] = []
        if !config.general.navigationSounds {
            items.append(note("Navigation sounds are off in Settings",
                              "The browse, focus and menu sounds are silent in use, and so in this list. Waypoint says the words instead. Turn them on under Settings, Sounds"))
        }
        if Coexist.on, !Tones.own {
            items.append(note("CoExist is on with VoiceOver's sounds",
                              "VoiceOver plays its own sounds where it reads, so Waypoint's own are silent here and in this list. Only VoiceOver's files play"))
        }
        for (name, entries) in groups {
            items.append(MenuItem(verbatim: name, .submenu { entries.map(item) }))
        }
        return items
    }

    private static func note(_ title: String, _ hint: String) -> MenuItem {
        MenuItem(verbatim: title, .select { Speech.speakMessage(hint) })
    }

    private static func item(_ e: Entry) -> MenuItem {
        MenuItem(verbatim: e.title, .select(e.play), hint: e.when)
    }

    private static func voiceOver(_ file: String, else fallback: @escaping () -> Void = {}) -> () -> Void {
        { if !VoiceOverSounds.play(file) { fallback() } }
    }

    private static var groups: [(String, [Entry])] {
        [
            ("Modes", [
                ("Browse mode", "When a page takes over from a field, and Escape in focus mode", { Tones.browseMode() }),
                ("Focus mode", "When the focus lands in a field and keys go to the page", { Tones.focusMode() }),
                ("Browse mode, switched by hand", "The Waypoint key with Space or Z: VoiceOver's Quick Nav on sound, or the words Quick Nav on",
                 voiceOver("QuickNavOn.wav") { Speech.speakMessage("Quick Nav on") }),
                ("Focus mode, switched by hand", "The same switch the other way: Quick Nav off",
                 voiceOver("QuickNavOff.wav") { Speech.speakMessage("Quick Nav off") }),
                ("Quick Nav arrow keys on", "The Waypoint key with Shift and Q in the Mac style",
                 voiceOver("QuickNavArrowKeyOn.wav") { Speech.speakMessage("Quick Nav on") }),
                ("Quick Nav arrow keys off", "The same switch the other way",
                 voiceOver("QuickNavArrowKeyOff.wav") { Speech.speakMessage("Quick Nav off") }),
                ("Review layer armed", "Waypoint Option R once: the next key reads around", { ReviewLayer.armedTone() }),
                ("Review layer on", "Waypoint Option R twice: the layer stays on", { ReviewLayer.tone(on: true) }),
                ("Review layer off", "Escape, or Waypoint Option R again", { ReviewLayer.tone(on: false) }),
                ("Skim on", "Waypoint Option N", { SkimMode.tone(on: true) }),
                ("Skim off", "Waypoint Option N again", { SkimMode.tone(on: false) }),
                ("Skim, next item", "A tick as each item is read", { SkimMode.tick() }),
                ("Speech beeps mode", "The beeps speech mode, where speech would be, with VoiceOver off", { Tones.speechBeep() }),
            ]),
            ("Menus and lists", [
                ("Menu or list opened", "The Waypoint menu, Anywhere, Places, item actions, choosers and tools lists: three notes rising", { Tones.listOpened() }),
                ("Menu or list closed", "Three notes falling", { Tones.listClosed() }),
            ]),
            ("Waypoint", [
                ("Waypoint on", "Right Option, Right Shift and Slash: two notes rising", { WaypointPause.tone(on: true) }),
                ("Waypoint off", "The same chord again: two notes falling", { WaypointPause.tone(on: false) }),
                ("Waypoint layer", "Command Control Comma, with VoiceOver on: a single tone before the words", { Tones.layer() }),
                ("Started, VoiceOver has the Mac", "When Waypoint opens at login and VoiceOver is on", { Tones.startup() }),
                ("Waypoint takes over", "Hand-over chimes: Waypoint starts reading an app", { Tones.takeOver() }),
                ("Waypoint hands back", "Hand-over chimes: VoiceOver gets the app back", { Tones.handBack() }),
            ]),
            ("Reading", [
                ("Heading, level 1", "Where headings are set to a tone. Level 1 is the highest", { Tones.heading(level: 1) }),
                ("Heading, level 2", "Lower with each level", { Tones.heading(level: 2) }),
                ("Heading, level 3", "", { Tones.heading(level: 3) }),
                ("Heading, level 4", "", { Tones.heading(level: 4) }),
                ("Heading, level 5", "", { Tones.heading(level: 5) }),
                ("Heading, level 6", "", { Tones.heading(level: 6) }),
                ("Link", "A link, where links are set to a tone", { Tones.link() }),
                ("List", "A list, where lists are set to a tone", { Tones.list() }),
                ("Landmark", "A landmark or article", { Tones.landmark() }),
                ("Table", "A table, and moving into one in a document", { Tones.table() }),
                ("Graphic", "An image", { Tones.graphic() }),
                ("Block quote", "A quotation", { Tones.blockQuote() }),
                ("Comment", "Commented text in Word or Preview", { Tones.comment() }),
                ("Spelling mistake", "A misspelled word", { Tones.spellingError() }),
                ("Secure character", "Typing in a password field", {
                    if !VoiceOverSounds.play("SecureCharacter.aiff"), config.general.navigationSounds {
                        Speech.player?.playBell(frequencies: [1900], spacingMs: 0, ringMs: 14, volume: 0.12)
                    }
                }),
                ("Progress bar, 0 percent", "A progress bar beep: an octave higher each 25 percent", { Tones.progress(0) }),
                ("Progress bar, 50 percent", "", { Tones.progress(50) }),
                ("Progress bar, 100 percent", "", { Tones.progress(100) }),
            ]),
            ("Moving and pressing", [
                ("Edge", "The end of a line, list or document: nothing further", { Tones.edgeSound(false) }),
                ("Focus moved", "A tick when the focus moves to a new control", { Tones.focusTick() }),
                ("Pressed", "A link followed or a button pressed", { Tones.press() }),
                ("Drill in", "Review: into a group", voiceOver("DrillIn.aiff") { Tones.beep(660, 30) }),
                ("Drill out", "Review: out of a group", voiceOver("DrillOut.aiff") { Tones.beep(440, 30) }),
                ("Jump to a linked item", "Review: a jump to the item a control points at", { Tones.beep(660, 30) }),
                ("Page loaded", "A web page has loaded", voiceOver("WebAreaLoaded.aiff")),
                ("Popup appeared", "A popup or menu opens", voiceOver("PopupAppeared.aiff")),
                ("Notification banner", "A notification banner", voiceOver("Announcement.aiff")),
                ("Trackpad commands on", "Gesture control switched on", voiceOver("TrackingOn.aiff")),
                ("Trackpad commands off", "Gesture control switched off", voiceOver("TrackingOff.aiff")),
                ("Empty space under the finger", "Exploring the trackpad over a blank area", voiceOver("EmptySpace.aiff")),
            ]),
            ("Braille", [
                ("Braille display connected", "Three notes up, or VoiceOver's sound for it", { Tones.brailleConnected() }),
                ("Braille display disconnected", "Three notes down", { Tones.brailleDisconnected() }),
            ]),
        ].map { ($0.0, $0.1.map { (title: $0.0, when: $0.1, play: $0.2) }) }
    }
}
