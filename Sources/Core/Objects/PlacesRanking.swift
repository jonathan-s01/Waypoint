// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's Places (plan 13): what a bookmark is, how a place is named, how bookmarks and recent places are kept in
// order and found by typing, and how they are written to disk. Nothing here touches the Mac, so all of it is tested
// (PlacesTests.swift); System-facing work (finding the element again, moving focus) is Places.swift.
import Foundation

/// One step of a fingerprint, as it is written to disk. FocusNode cannot be made Codable from here: Swift only
/// synthesises that inside the file that declares the type.
nonisolated public struct PlaceNode: Codable, Equatable, Sendable {
    public var role: String
    public var id: String
    public var text: String
    public var index: Int
    public init(role: String, id: String = "", text: String = "", index: Int = 0) { self.role = role; self.id = id; self.text = text; self.index = index }
}

/// A place the user can come back to: a fingerprint of an element, and the app and window it was in.
nonisolated public struct PlaceRecord: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bundleID: String
    public var appName: String
    public var windowTitle: String
    public var nodes: [PlaceNode]
    public var created: Date

    public init(id: String = UUID().uuidString, name: String, bundleID: String, appName: String, windowTitle: String, nodes: [PlaceNode], created: Date = Date()) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.appName = appName; self.windowTitle = windowTitle; self.nodes = nodes; self.created = created
    }

    public init(name: String, bundleID: String, appName: String, fingerprint: FocusFingerprint, id: String = UUID().uuidString, created: Date = Date()) {
        self.init(id: id, name: name, bundleID: bundleID, appName: appName, windowTitle: fingerprint.windowTitle,
                  nodes: fingerprint.nodes.map { PlaceNode(role: $0.role, id: $0.id, text: $0.text, index: $0.index) }, created: created)
    }

    public var fingerprint: FocusFingerprint {
        FocusFingerprint(windowTitle: windowTitle, nodes: nodes.map { FocusNode(role: $0.role, id: $0.id, text: $0.text, index: $0.index) })
    }

    /// The same app, window and element. The place among the siblings is left out: a list that was reordered still holds
    /// the same row.
    public func isSamePlace(as other: PlaceRecord) -> Bool {
        guard PlacesLogic.sameApp(self, other), windowTitle == other.windowTitle, nodes.count == other.nodes.count else { return false }
        return zip(nodes, other.nodes).allSatisfy { $0.role == $1.role && $0.id == $1.id && $0.text == $1.text }
    }
}

nonisolated public enum PlacesLogic {
    /// How long the focus must stay on an element for it to count as a place the user was at.
    public static let dwellSeconds: TimeInterval = 5
    public static let recentLimit = 20
    /// Element references kept to be fingerprinted when the recent places are asked for (more than are listed: some
    /// will be gone, or a menu, or a window).
    public static let visitLimit = 40
    public static let nameLimit = 60

    // MARK: Naming

    /// The role as it is said: "AXTextField" is "text field".
    public static func roleWords(_ axRole: String) -> String {
        var s = axRole
        if s.hasPrefix("AX") { s.removeFirst(2) }
        var out = ""
        for ch in s where ch.isLetter {
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(contentsOf: ch.lowercased())
        }
        return out.isEmpty ? String(localized: "item", comment: "A place whose kind is not known, in the name made for a bookmark") : out
    }

    /// Spacing folded away and the length kept short, cut at a space when there is one in the second half.
    public static func shortText(_ s: String, limit: Int = nameLimit) -> String {
        let t = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard t.count > limit else { return t }
        let cut = String(t.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= limit / 2 { return String(cut[..<space]) }
        return cut
    }

    /// The name a place gets when the user does not give one: the element's own words, else its kind and where it is.
    public static func autoName(text: String, axRole: String, windowTitle: String, appName: String) -> String {
        let words = shortText(text)
        if !words.isEmpty { return words }
        let role = roleWords(axRole)
        let window = shortText(windowTitle)
        if !window.isEmpty { return String(localized: "\(role) in \(window)", comment: "The name made for a bookmark on an item with no words of its own: its kind, then the title of its window") }
        let app = shortText(appName)
        return app.isEmpty ? role : String(localized: "\(role) in \(app)", comment: "The name made for a bookmark on an item with no words of its own: its kind, then its app")
    }

    /// A name no other of `existing` has (case aside): "Inbox", then "Inbox 2", "Inbox 3".
    public static func uniqueName(_ name: String, among existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }

    public static func sameApp(_ a: PlaceRecord, _ b: PlaceRecord) -> Bool {
        if !a.bundleID.isEmpty || !b.bundleID.isEmpty { return a.bundleID == b.bundleID }
        return a.appName == b.appName
    }

    // MARK: The bookmarks

    /// Adds a bookmark. The same place again keeps its name and id and takes the new fingerprint (the row may have moved);
    /// a new one gets a name no other bookmark in the same app has. Returns the list and the bookmark as saved.
    public static func upsert(_ place: PlaceRecord, into list: [PlaceRecord]) -> (list: [PlaceRecord], saved: PlaceRecord) {
        if let i = list.firstIndex(where: { $0.isSamePlace(as: place) }) {
            var out = list
            out[i].nodes = place.nodes
            out[i].windowTitle = place.windowTitle
            return (out, out[i])
        }
        var added = place
        added.name = uniqueName(place.name, among: list.filter { sameApp($0, place) }.map(\.name))
        return (list + [added], added)
    }

    public static func removing(id: String, from list: [PlaceRecord]) -> [PlaceRecord] { list.filter { $0.id != id } }

    /// By name, so a bookmark has the same place in the list each time; the oldest first among equal names.
    public static func sorted(_ list: [PlaceRecord]) -> [PlaceRecord] {
        list.enumerated().sorted { a, b in
            let c = a.element.name.localizedCaseInsensitiveCompare(b.element.name)
            if c != .orderedSame { return c == .orderedAscending }
            if a.element.created != b.element.created { return a.element.created < b.element.created }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Recent places

    public static func dwelled(from start: Date, to end: Date, minimum: TimeInterval = dwellSeconds) -> Bool { end.timeIntervalSince(start) >= minimum }

    /// `item` to the front, an earlier equal one dropped, the list kept to `limit`.
    public static func pushRecent<T>(_ item: T, into list: [T], limit: Int, same: (T, T) -> Bool) -> [T] {
        var out = list.filter { !same($0, item) }
        out.insert(item, at: 0)
        return Array(out.prefix(limit))
    }

    /// The recent places, newest first, each place once (its newest visit) and not the place the user is at now: the
    /// first is the previous place.
    public static func dedupe(_ list: [PlaceRecord], excluding current: PlaceRecord? = nil, limit: Int = recentLimit) -> [PlaceRecord] {
        var out: [PlaceRecord] = []
        for p in list {
            if let current, p.isSamePlace(as: current) { continue }
            if out.contains(where: { $0.isSamePlace(as: p) }) { continue }
            out.append(p)
            if out.count == limit { break }
        }
        return out
    }

    // MARK: Finding the window

    /// The windows to look in, as indexes into `titles`: those with the title the place had first, then the others.
    /// Titles change (a page, a mailbox), and the finder only answers an exact match, so the others are worth a try.
    public static func windowOrder(titles: [String], wanted: String, limit: Int = 6) -> [Int] {
        let same = titles.indices.filter { titles[$0] == wanted }
        let others = titles.indices.filter { titles[$0] != wanted }
        return Array((same + others).prefix(limit))
    }

    // MARK: The list

    /// The name, then the app; the first of the recent places says so.
    public static func spokenTitle(name: String, appName: String, previous: Bool = false) -> String {
        let base = appName.isEmpty ? name : "\(name), \(appName)"
        return previous ? String(localized: "previous place: \(base)", comment: "The first of the recent places: the place you were at before this one, then its app") : base
    }

    /// What a place can also be found by, beside its name: its app and window, and for the previous place those words.
    public static func otherWords(appName: String, windowTitle: String, previous: Bool = false) -> String {
        [appName, windowTitle, previous ? String(localized: "previous place", comment: "The first of the recent places, as it can be typed") : ""].joined(separator: " ")
    }

    /// The indexes of the places a typed query finds, best first. Every word must match: a name matched whole (4), the start
    /// of a word of the name (3), inside the name (2), or only the app or window (1); a result is as good as its worst word.
    /// Equal fits keep the order given (newest first for recent places, by name for bookmarks).
    public static func filter(query: String, names: [String], others: [String]) -> [Int] {
        let tokens = AnywhereRanking.words(query)
        guard !tokens.isEmpty else { return Array(names.indices) }
        let phrase = tokens.joined(separator: " ")
        var scored: [(index: Int, tier: Int)] = []
        for i in names.indices {
            let nameWords = AnywhereRanking.words(names[i])
            if nameWords.joined(separator: " ") == phrase { scored.append((i, 4)); continue }
            let otherWords = i < others.count ? AnywhereRanking.words(others[i]) : []
            var tier = 3
            var fits = true
            for t in tokens {
                if nameWords.contains(where: { $0.hasPrefix(t) }) { continue }
                if nameWords.contains(where: { $0.contains(t) }) { tier = min(tier, 2); continue }
                if otherWords.contains(where: { $0.hasPrefix(t) || $0.contains(t) }) { tier = min(tier, 1); continue }
                fits = false
                break
            }
            if fits { scored.append((i, tier)) }
        }
        return scored.sorted { $0.tier != $1.tier ? $0.tier > $1.tier : $0.index < $1.index }.map(\.index)
    }

    // MARK: The file

    nonisolated struct Stored: Codable {
        var version: Int
        var bookmarks: [PlaceRecord]
    }

    public static func encode(_ list: [PlaceRecord]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(Stored(version: 1, bookmarks: list))
    }

    /// nil when the data is not a places file (so the caller keeps it rather than overwrite it). A bookmark with no
    /// element in it is left out: it could never be found.
    public static func decode(_ data: Data) -> [PlaceRecord]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data), stored.version == 1 else { return nil }
        return stored.bookmarks.filter { $0.fingerprint.isUsable }
    }
}
