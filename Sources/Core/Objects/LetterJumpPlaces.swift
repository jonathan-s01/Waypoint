// SPDX-License-Identifier: GPL-3.0-or-later
// Letter jump on or off for a place, remembered (Waypoint, not in upstream TurnOver).
//
// LetterJump turns a typed letter into "the next list item that starts with it". That is wrong where the letters
// should reach the app (a list that has its own type-to-search, a game, a web app that takes keys). VO-Shift-L
// switches it for the place the keyboard is in, and the choice is kept, so it is off in one place and on in the next
// without asking again. A place is the most specific of: the exact page (a web document, without its #fragment), the
// named part of the window (an app with a recipe's parts), the app. A place with no choice follows the next wider
// one, and an app with none has letter jump on, so nothing changes until the key is pressed.
import Foundation
import AppKit

@MainActor
public enum LetterJumpPlaces {
    nonisolated public enum Scope { case page, part, app }

    nonisolated public struct Place: Codable, Equatable {
        public var on: Bool
        public var at: Date
        public init(on: Bool, at: Date) { self.on = on; self.at = at }
    }

    static let defaultsKey = "waypoint.letterJump.places"
    /// Pages come and go; the oldest choices are dropped past this many.
    nonisolated public static let limit = 300

    // MARK: Pure parts (tested)

    /// The places the keyboard is in, most specific first: the key each is kept under, and what it is called aloud.
    nonisolated public static func candidates(bundle: String, url: String?, part: String?) -> [(key: String, scope: Scope)] {
        var out: [(key: String, scope: Scope)] = []
        if let url {
            let page = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if !page.isEmpty { out.append(("page|\(bundle)|\(page)", .page)) }
        }
        if let part, !part.isEmpty { out.append(("part|\(bundle)|\(part)", .part)) }
        out.append(("app|\(bundle)", .app))
        return out
    }

    /// The choice of the most specific place that has one; nil when none does.
    nonisolated public static func choice(_ places: [(key: String, scope: Scope)], in table: [String: Place]) -> Bool? {
        for p in places { if let c = table[p.key] { return c.on } }
        return nil
    }

    /// The table after the key is pressed here: the most specific place gets the opposite of what holds now.
    nonisolated public static func toggled(_ places: [(key: String, scope: Scope)], in table: [String: Place], now: Date) -> (table: [String: Place], on: Bool, scope: Scope) {
        let on = !(choice(places, in: table) ?? true)
        var t = table
        t[places[0].key] = Place(on: on, at: now)
        if t.count > limit {
            for k in t.sorted(by: { $0.value.at < $1.value.at }).prefix(t.count - limit).map(\.key) { t[k] = nil }
        }
        return (t, on, places[0].scope)
    }

    // MARK: Where the keyboard is

    private static var loaded: [String: Place]?
    private static var table: [String: Place] {
        get {
            if let loaded { return loaded }
            let t = UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([String: Place].self, from: $0) } ?? [:]
            loaded = t
            return t
        }
        set {
            loaded = newValue
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        }
    }

    private static func here() -> [(key: String, scope: Scope)] {
        let pid = API.focusPid ?? 0
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        var part: String?
        if let view = PanesView.current(pid: pid), let i = view.currentIndex(), view.parts.indices.contains(i) { part = view.parts[i].name }
        return candidates(bundle: bundle, url: API.focusTreeInterceptor?.url, part: part)
    }

    /// Letter jump is on where the keyboard is now.
    static var enabledHere: Bool { choice(here(), in: table) ?? true }

    /// VO-Shift-L.
    static func toggle() {
        let r = toggled(here(), in: table, now: Date())
        table = r.table
        Log.io("letter jump: \(r.on ? "on" : "off") for the \(r.scope)")
        switch (r.on, r.scope) {
        case (true, .page): Speech.speakMessage(String(localized: "letter jump on for this page", comment: "Spoken message"))
        case (false, .page): Speech.speakMessage(String(localized: "letter jump off for this page", comment: "Spoken message"))
        case (true, .part): Speech.speakMessage(String(localized: "letter jump on for this part", comment: "Spoken message"))
        case (false, .part): Speech.speakMessage(String(localized: "letter jump off for this part", comment: "Spoken message"))
        case (true, .app): Speech.speakMessage(String(localized: "letter jump on for this app", comment: "Spoken message"))
        case (false, .app): Speech.speakMessage(String(localized: "letter jump off for this app", comment: "Spoken message"))
        }
    }
}
