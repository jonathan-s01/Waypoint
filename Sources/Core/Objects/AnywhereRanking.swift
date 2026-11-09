// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's Anywhere command bar (plan 4.11, the part that needs no language model): what a result is, how a typed
// query finds and orders results, which results are risky, and the small decisions around them. Nothing here touches
// the Mac, so all of it is tested (AnywhereTests.swift); System/Anywhere.swift gathers the results and runs them.
import Foundation

/// What a result is. The order is the tie-break: the item's own actions first, then the window's parts, apps, menu
/// commands and Waypoint's own commands.
nonisolated public enum AnywhereKind: Int, Sendable {
    case action = 0, region, app, menuCommand, command

    /// As it is said after the name.
    public var spoken: String {
        switch self {
        case .action: return String(localized: "action", comment: "Anywhere: what kind of result this is, said after its name")
        case .region: return String(localized: "region", comment: "Anywhere: what kind of result this is, said after its name: a part of the window")
        case .app: return String(localized: "app", comment: "Anywhere: what kind of result this is, said after its name")
        case .menuCommand: return String(localized: "menu command", comment: "Anywhere: what kind of result this is, said after its name")
        case .command: return String(localized: "command", comment: "Anywhere: what kind of result this is, said after its name: one of Waypoint's own")
        }
    }
}

/// One thing Anywhere can do. The words it is searched by are worked out once, here, as every key typed ranks them all.
nonisolated public struct AnywhereEntry: Sendable {
    /// Stable between launches, so what was used last is remembered.
    public let id: String
    public let name: String
    public let kind: AnywhereKind
    public let shortcut: String?
    /// Where it is (the menu a command is in); said after a pause on the result, and searched at a lower rank.
    public let place: String?
    public let enabled: Bool
    let nameWords: [String]
    let nameFolded: String
    let otherWords: [String]

    public init(id: String, name: String, kind: AnywhereKind, shortcut: String? = nil, place: String? = nil, enabled: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.shortcut = shortcut; self.place = place; self.enabled = enabled
        let words = AnywhereRanking.words(name)
        nameWords = words
        nameFolded = words.joined(separator: " ")
        otherWords = AnywhereRanking.words(place ?? "") + AnywhereRanking.kindWords[kind.rawValue, default: []]
    }
}

public enum AnywhereRanking {
    /// The kinds' own words, so "app" or "menu" in a query narrows to them (computed once: translating each entry's
    /// kind on every key typed was needless work).
    nonisolated static let kindWords: [Int: [String]] = {
        var out: [Int: [String]] = [:]
        for kind in [AnywhereKind.action, .region, .app, .menuCommand, .command] { out[kind.rawValue] = words(kind.spoken) }
        return out
    }()

    /// Case, accents and punctuation folded away: "Café Menu…" is "cafe", "menu".
    nonisolated public static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// How a typed query fits an entry: nil when it does not. Every word typed must match. The tier is how well:
    /// the whole name (4); every word at the start of a word of the name, which takes in exact words and prefixes (3);
    /// inside words of the name (2); only in where it is or what kind it is (1). The score orders within a tier:
    /// exact words over prefixes, a name that starts with the query, a shorter name.
    nonisolated public static func match(_ entry: AnywhereEntry, tokens: [String]) -> (tier: Int, score: Int)? {
        guard !tokens.isEmpty else { return nil }
        let phrase = tokens.joined(separator: " ")
        if entry.nameFolded == phrase { return (4, 10_000) }
        var points = 0
        var allWordStart = true
        var allInName = true
        for t in tokens {
            var best = 0
            for w in entry.nameWords {
                if w == t { best = 3; break }
                if w.hasPrefix(t) { best = max(best, 2) } else if w.contains(t) { best = max(best, 1) }
            }
            if best == 0 {
                guard entry.otherWords.contains(where: { $0.hasPrefix(t) || $0.contains(t) }) else { return nil }
                allWordStart = false; allInName = false
            } else {
                if best < 2 { allWordStart = false }
                points += best
            }
        }
        let tier = allWordStart ? 3 : allInName ? 2 : 1
        let score = points * 1000 + (entry.nameFolded.hasPrefix(phrase) ? 500 : 0) - min(entry.nameFolded.count, 499)
        return (tier, score)
    }

    /// The indexes of the entries that fit the query, best first: by tier, then what was used most recently, then
    /// score, kind and name. With nothing typed: what was used recently, newest first, then the rest as given.
    nonisolated public static func rank(query: String, entries: [AnywhereEntry], recents: [String]) -> [Int] {
        let tokens = words(query)
        var recency: [String: Int] = [:]
        for (i, id) in recents.enumerated() where recency[id] == nil { recency[id] = i }
        if tokens.isEmpty {
            let used = entries.indices.filter { recency[entries[$0].id] != nil }.sorted { (recency[entries[$0].id]!, $0) < (recency[entries[$1].id]!, $1) }
            return used + entries.indices.filter { recency[entries[$0].id] == nil }
        }
        var scored: [(index: Int, tier: Int, score: Int, recency: Int)] = []
        for (i, e) in entries.enumerated() {
            if let m = match(e, tokens: tokens) { scored.append((i, m.tier, m.score, recency[e.id] ?? Int.max)) }
        }
        scored.sort { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.recency != b.recency { return a.recency < b.recency }
            if a.score != b.score { return a.score > b.score }
            let ka = entries[a.index].kind.rawValue, kb = entries[b.index].kind.rawValue
            if ka != kb { return ka < kb }
            let c = entries[a.index].name.localizedCaseInsensitiveCompare(entries[b.index].name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.index < b.index
        }
        return scored.map(\.index)
    }

    /// The name, then the kind, then the shortcut when there is one, then "dimmed" if it can't be chosen now.
    nonisolated public static func spokenTitle(_ e: AnywhereEntry) -> String {
        var parts = [e.name, e.kind.spoken]
        if let s = e.shortcut, !s.isEmpty { parts.append(s) }
        if !e.enabled { parts.append(String(localized: "dimmed", comment: "A menu item that can't be chosen now")) }
        return parts.joined(separator: ", ")
    }

    // MARK: Risk

    /// Words that make a command one to choose twice, as whole words: "Quit Safari" and "Empty Trash…" are, "Reformat" and
    /// "Clear Formatting" are not.
    nonisolated static let riskyPhrases: [[String]] = [["delete"], ["erase"], ["empty", "trash"], ["quit"], ["log", "out"], ["shut", "down"], ["restart"], ["format"]]

    /// Whether choosing it needs a second Return. An app or a part of the window only takes you somewhere.
    nonisolated public static func isRisky(name: String, kind: AnywhereKind) -> Bool {
        guard kind != .app, kind != .region else { return false }
        let w = words(name)
        return riskyPhrases.contains { containsRun(w, $0) }
    }

    nonisolated static func containsRun(_ words: [String], _ run: [String]) -> Bool {
        guard !run.isEmpty, words.count >= run.count else { return false }
        for i in 0...(words.count - run.count) where Array(words[i..<(i + run.count)]) == run { return true }
        return false
    }

    /// The second Return: the same result chosen again soon after the first.
    nonisolated public static func isConfirmation(pendingID: String?, pendingAt: Date?, id: String, now: Date, within window: TimeInterval = 5) -> Bool {
        guard let pendingID, let pendingAt, pendingID == id else { return false }
        return now.timeIntervalSince(pendingAt) <= window
    }

    // MARK: Recent use, and which commands are listed

    /// The result just run goes to the front; the list stays short.
    nonisolated public static func recordRecent(_ id: String, in recents: [String], limit: Int = 12) -> [String] {
        var out = recents.filter { $0 != id }
        out.insert(id, at: 0)
        return Array(out.prefix(limit))
    }

    /// A key with a Command, Control, Option or TurnOver key in it is a command; a bare letter or arrow, or one with
    /// Shift alone, is a key a list or a page uses (the arrows, a letter that jumps), which Anywhere does not list.
    nonisolated public static func isChord(_ identifier: String) -> Bool {
        guard let colon = identifier.firstIndex(of: ":") else { return false }
        let parts = identifier[identifier.index(after: colon)...].split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return false }
        return parts.dropLast().contains { $0 != "shift" }
    }
}
