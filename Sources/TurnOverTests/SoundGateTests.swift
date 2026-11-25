// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore

// 19 Nov 2026: the gate sits at the lowest level (Tones.beep, the bell, TurnOverSounds.play), and a sound is never
// prepared on the thread that asks for it. Logic evidence only: probes record what would play, nothing is played.
/// A focused object with only the role and states a test gives it.
private final class PlaceStub: TurnOverObject {
    var stubRole: Role = .unknown
    var stubStates: Set<State> = []
    var stubText: String?
    required init(element: AXUIElement) { super.init(element: element) }
    convenience init(_ role: Role, _ states: Set<State> = [], text: String? = nil) {
        self.init(element: AXUIElementCreateSystemWide()); stubRole = role; stubStates = states; stubText = text
    }
    override var role: Role { stubRole }
    override var states: Set<State> { stubStates }
    override var roleText: String? { stubText }
}

@MainActor func contextCueTests() {
    final class Heard { var items: [String] = []; var count: Int { items.count } }
    func run(_ body: (Heard) -> Void) {
        let savedSounds = config.general.sounds, savedCues = config.general.contextCues
        defer { config.general.sounds = savedSounds; config.general.contextCues = savedCues; Tones.outputProbe = nil; ContextCues.reset() }
        let heard = Heard()
        Tones.outputProbe = { heard.items.append($0) }
        config.general.sounds = "turnover"; config.general.contextCues = true
        ContextCues.reset()
        body(heard)
    }
    test("place cues: a kind of place is cued once, and again after a plain control or another kind") {
        run { heard in
            ContextCues.focusGained(PlaceStub(.list)); expect(heard.count, 1, "entering a list is cued")
            ContextCues.focusGained(PlaceStub(.tableRow)); ContextCues.focusGained(PlaceStub(.listItem)); expect(heard.count, 1, "rows of one list are silent")
            ContextCues.focusGained(PlaceStub(.groupBox)); expect(heard.count, 1, "a container changes nothing")
            ContextCues.focusGained(PlaceStub(.button)); ContextCues.focusGained(PlaceStub(.list)); expect(heard.count, 2, "a list after a button is cued again")
            ContextCues.focusGained(PlaceStub(.editableText, [.editable])); expect(heard.count, 3, "an edit field is another kind")
        }
    }
    test("place cues: each kind of place is told apart") {
        let cases: [(PlaceStub, ContextCues.Place)] = [
            (PlaceStub(.editableText, [.editable]), .cue(.edit)), (PlaceStub(.searchField), .cue(.edit)),
            (PlaceStub(.editableText, [.readOnly]), .cue(.reading)), (PlaceStub(.staticText), .cue(.reading)),
            (PlaceStub(.outline), .cue(.list)), (PlaceStub(.browser), .cue(.list)),
            (PlaceStub(.menuItem), .cue(.menu)), (PlaceStub(.popupMenu), .cue(.menu)),
            (PlaceStub(.passwordEdit), .cue(.secure)), (PlaceStub(.editableText, [.editable], text: "terminal"), .cue(.terminal)),
            (PlaceStub(.sheet), .cue(.dialog)), (PlaceStub(.checkBox), .plain), (PlaceStub(.window), .ignore),
        ]
        for (object, place) in cases { expect(ContextCues.place(of: object), place, "\(object.stubRole)") }
    }
    test("place cues: a menu opening and a mode change use the same state, and the toggle and VoiceOver's set silence them") {
        run { heard in
            Tones.menuOpened(); Tones.contextMenuOpened(); expect(heard.count, 1, "a menu opening is cued once")
            ContextCues.mode(focus: true); ContextCues.mode(focus: true); expect(heard.count, 2, "focus mode is cued once")
            ContextCues.focusGained(PlaceStub(.editableText, [.editable])); expect(heard.count, 2, "a field right after focus mode is not cued twice")
            config.general.contextCues = false; ContextCues.reset(); heard.items = []
            ContextCues.focusGained(PlaceStub(.list)); expect(heard.items, [], "cues off: nothing")
            config.general.contextCues = true; config.general.sounds = "voiceover"
            ContextCues.focusGained(PlaceStub(.table)); expect(heard.items, [], "VoiceOver's sounds: nothing")
        }
    }
}

@MainActor func soundGateTests() {
    let named: [(String, () -> Void)] = [
        ("the waiting beep (HelpImprove, NVDAStoreMenu, PluginAI)", { Tones.waitingTick() }),
        ("the marked sound (GlobalCommands)", { Tones.marked() }),
        ("the installed beep (AppStoreView)", { Tones.installed() }),
        ("a plain beep", { Tones.beep(880, 30) }),
        ("a plain bell", { Tones.bell(frequencies: [880], spacingMs: 0, ringMs: 10) }),
        ("a file of TurnOver's set", { _ = TurnOverSounds.play("marked") }),
    ]
    let exceptions: [(String, () -> Void)] = [
        ("startup", { Tones.startup() }), ("take-over", { Tones.takeOver() }), ("hand-back", { Tones.handBack() }),
        ("the progress beep", { Tones.progress(50) }),
    ]
    test("sounds: with VoiceOver's chosen, the three named callers and every ungated primitive request nothing") {
        let saved = config.general.sounds
        defer { config.general.sounds = saved; Tones.outputProbe = nil }
        var heard: [String] = []
        Tones.outputProbe = { heard.append($0) }
        config.general.sounds = "voiceover"
        for (what, play) in named { heard = []; play(); expect(heard, [], "\(what) is silent") }
    }
    test("sounds: the four exceptions and the stand-in fallbacks play in both sets") {
        let saved = config.general.sounds
        defer { config.general.sounds = saved; Tones.outputProbe = nil }
        var heard: [String] = []
        Tones.outputProbe = { heard.append($0) }
        for set in ["voiceover", "turnover"] {
            config.general.sounds = set
            for (what, play) in exceptions { heard = []; play(); expect(heard.isEmpty, false, "\(what) plays with \(set)") }
            heard = []; Tones.beep(880, 30, exempt: true); expect(heard.isEmpty, false, "an exempt beep plays with \(set)")
            heard = []; Tones.bell(frequencies: [880], spacingMs: 0, ringMs: 10, exempt: true); expect(heard.isEmpty, false, "an exempt bell plays with \(set)")
            heard = []; _ = TurnOverSounds.play("marked", exempt: true); expect(heard.isEmpty, false, "an exempt file plays with \(set)")
        }
    }
    test("sounds: with TurnOver's chosen, the gated sounds play as before") {
        let saved = config.general.sounds
        defer { config.general.sounds = saved; Tones.outputProbe = nil }
        var heard: [String] = []
        Tones.outputProbe = { heard.append($0) }
        config.general.sounds = "turnover"
        for (what, play) in named { heard = []; play(); expect(heard.isEmpty, false, "\(what) plays") }
    }
    test("sounds: a prepared file plays now; an unprepared one is skipped and plays nothing later; a failed one returns false") {
        let saved = config.general.sounds
        defer { config.general.sounds = saved; VoiceOverSounds.cache.setHold(nil) }
        config.general.sounds = "voiceover"
        let hold = DispatchSemaphore(value: 0)
        VoiceOverSounds.cache.setHold(hold)   // preparation waits here, so the request must return first
        let name = "NotFound.aiff"
        expect(VoiceOverSounds.cache.player(name) == nil, true, "not prepared before the request")
        expect(VoiceOverSounds.play(name), true, "an unprepared file: the request returns true at once")
        expect(VoiceOverSounds.cache.player(name) == nil, true, "nothing was prepared on this thread, and nothing is waiting to play")
        hold.signal()
        let until = Date().addingTimeInterval(5)
        while VoiceOverSounds.cache.player(name) == nil, !VoiceOverSounds.cache.hasFailed(name), Date() < until { Thread.sleep(forTimeInterval: 0.01) }
        if VoiceOverSounds.cache.player(name) != nil {
            expect(VoiceOverSounds.play(name), true, "prepared: it plays now (muted in tests)")
        } else {
            expect(VoiceOverSounds.cache.hasFailed(name), true, "or it failed")
        }
        // A file that cannot be read fails once, and the request then says false so the caller's fallback plays.
        let bad = "NoSuchFile-test.aiff"
        VoiceOverSounds.cache.setHold(nil)
        expect(VoiceOverSounds.play(bad), true, "the first request skips")
        let until2 = Date().addingTimeInterval(5)
        while !VoiceOverSounds.cache.hasFailed(bad), Date() < until2 { Thread.sleep(forTimeInterval: 0.01) }
        expect(VoiceOverSounds.cache.hasFailed(bad), true, "its preparation failed")
        expect(VoiceOverSounds.play(bad), false, "a failed file returns exactly what ownTone says (false: no stand-in), so the caller's own tone plays as before")
    }
}
