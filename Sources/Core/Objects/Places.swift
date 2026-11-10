// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's Places (plan 13): bookmarks, and the places the user has recently spent time in. A place is a focus-memory
// fingerprint (FocusMemory.swift) with the app and window it was in, found again by FocusMemory.find and given the
// focus by FocusMemory.put. Bookmarks are kept in places.json in TurnOver's support folder; recent places are only in
// memory. The pure parts (naming, order, filtering, the file) are PlacesRanking.swift.
//
// Recent places cost the focus path nothing: FocusMemory.note hands over the element reference, and when the focus has
// moved on after five seconds or more the reference is kept (no accessibility call). The references are fingerprinted
// only when the list is asked for, off the main thread, within a time limit.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

@MainActor
enum Places {
    // MARK: Setting (UserDefaults; Waypoint-only, default on)

    static let settingKey = "waypoint.places"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    // MARK: The bookmarks (places.json)

    private static let fileName = "places.json"
    private static var stored: [PlaceRecord]?

    static var bookmarks: [PlaceRecord] {
        if stored == nil { stored = load() }
        return stored ?? []
    }

    private static func load() -> [PlaceRecord] {
        let url = AppPaths.file(fileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let list = PlacesLogic.decode(data) { return list }
        // A file this version cannot read is kept aside, not overwritten by the next bookmark.
        let aside = url.deletingLastPathComponent().appendingPathComponent("places.unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        Log.io("places: \(fileName) could not be read; kept as places.unreadable.json")
        return []
    }

    @discardableResult
    private static func save(_ list: [PlaceRecord]) -> Bool {
        stored = list
        guard let data = PlacesLogic.encode(list) else { return false }
        do { try data.write(to: AppPaths.file(fileName), options: .atomic); return true }
        catch { Log.io("places: could not write \(fileName): \(error.localizedDescription)"); return false }
    }

    private static func off() {
        Speech.speakMessage(String(localized: "places is off", comment: "Spoken message: the bookmarks and recent places feature is turned off"))
    }

    // MARK: Bookmark this place

    static func bookmarkHere() {
        guard enabled else { off(); return }
        guard let pid = API.focusPid, let focus = API.focusObject else {
            Speech.speakMessage(String(localized: "nothing to bookmark", comment: "Spoken message: there is no item in focus to bookmark"))
            return
        }
        // Where the review cursor is, when it has been moved elsewhere in the same app: that is where the user is reading.
        var target = focus.element
        var preferred = focus.name
        if let review = ObjectNavigator.shared.reviewElement, !CFEqual(review, target) {
            var reviewPid: pid_t = 0
            if AXUIElementGetPid(review, &reviewPid) == .success, reviewPid == pid { target = review; preferred = "" }
        }
        let role = target.role
        guard !FocusMemory.isMenuRole(role), let fp = FocusMemory.fingerprint(of: target, root: nil, budget: 0.6), fp.isUsable else {
            Speech.speakMessage(String(localized: "this place cannot be bookmarked", comment: "Spoken message: the item in focus has nothing a bookmark could find it by again"))
            return
        }
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName ?? ""
        let text = preferred.isEmpty ? (fp.nodes.last?.text ?? "") : preferred
        let name = PlacesLogic.autoName(text: text, axRole: role, windowTitle: fp.windowTitle, appName: appName)
        let place = PlaceRecord(name: name, bundleID: app?.bundleIdentifier ?? "", appName: appName, fingerprint: fp)
        let result = PlacesLogic.upsert(place, into: bookmarks)
        let saved = save(result.list)
        Log.io("places: bookmarked \(role) \"\(Log.words(result.saved.name))\" in \(app?.bundleIdentifier ?? "pid \(pid)"), \(fp.nodes.count) levels")
        let said = result.saved.name
        Speech.speakMessage(saved ? String(localized: "Bookmarked \(said)", comment: "Spoken message: a bookmark was made; %@ is its name")
                            : String(localized: "Bookmarked \(said), but it could not be saved", comment: "Spoken message: a bookmark was made but the file could not be written; %@ is its name"))
    }

    // MARK: The lists

    static func openBookmarks() {
        guard enabled else { off(); return }
        let list = PlacesLogic.sorted(bookmarks)
        guard !list.isEmpty else { Speech.speakMessage(String(localized: "no bookmarks", comment: "Spoken message: there are no bookmarks yet")); return }
        present(String(localized: "Bookmarks", comment: "Title of the list of bookmarks, which you narrow by typing"), list, previousFirst: false) { jump(to: $0) }
    }

    /// A bookmark is deleted from its own list, so it is never one key away from the list that goes to it.
    static func openDelete() {
        guard enabled else { off(); return }
        let list = PlacesLogic.sorted(bookmarks)
        guard !list.isEmpty else { Speech.speakMessage(String(localized: "no bookmarks", comment: "Spoken message: there are no bookmarks yet")); return }
        present(String(localized: "Delete a bookmark", comment: "Title of the list in which Return deletes the bookmark you are on"), list, previousFirst: false) { place in
            save(PlacesLogic.removing(id: place.id, from: bookmarks))
            Log.io("places: deleted \"\(Log.words(place.name))\"")
            Speech.speakMessage(String(localized: "Deleted \(place.name)", comment: "Spoken message: a bookmark was deleted; %@ is its name"))
        }
    }

    private static func present(_ title: String, _ records: [PlaceRecord], previousFirst: Bool, choose: @escaping (PlaceRecord) -> Void) {
        let names = records.map(\.name)
        let others = records.enumerated().map { PlacesLogic.otherWords(appName: $1.appName, windowTitle: $1.windowTitle, previous: previousFirst && $0 == 0) }
        func item(_ i: Int) -> MenuItem {
            let r = records[i]
            return MenuItem(verbatim: PlacesLogic.spokenTitle(name: r.name, appName: r.appName, previous: previousFirst && i == 0),
                            .action { choose(r) }, hint: r.windowTitle.isEmpty ? nil : r.windowTitle)
        }
        TurnOverMenu.shared.openChooser(verbatim: title, items: records.indices.map(item))
        TurnOverMenu.shared.filterMatcher = { text in PlacesLogic.filter(query: text, names: names, others: others).map(item) }
    }

    // MARK: Recent places

    nonisolated private struct Visit: Sendable {
        let id: Int
        let element: Handed<AXUIElement>
        let pid: pid_t
    }

    /// What was found out about a visit: nil fingerprint when it cannot be a place (a menu, a window, gone).
    nonisolated private struct Probe: Sendable {
        let id: Int
        let bundleID: String
        let appName: String
        let fingerprint: FocusFingerprint?
    }

    nonisolated private struct Job: Sendable {
        let visit: Visit
        let bundleID: String
        let appName: String
        let cached: Probe?
    }

    private static var current: (element: AXUIElement, pid: pid_t, at: Date)?
    private static var visits: [Visit] = []
    private static var probes: [Int: Probe] = [:]
    private static var nextVisitID = 0
    private static var listGeneration = 0

    /// The focus is `e` (FocusMemory.note, for every focus change): a reference and a time, no accessibility call. The
    /// element left behind is kept when the focus had been on it long enough.
    static func noted(_ e: AXUIElement, pid: pid_t) {
        guard enabled else { return }
        let now = Date()
        if let c = current {
            if CFEqual(c.element, e) { return }
            if PlacesLogic.dwelled(from: c.at, to: now) {
                nextVisitID += 1
                visits = PlacesLogic.pushRecent(Visit(id: nextVisitID, element: Handed(c.element), pid: c.pid), into: visits, limit: PlacesLogic.visitLimit) { CFEqual($0.element.value, $1.element.value) }
                let live = Set(visits.map(\.id))
                probes = probes.filter { live.contains($0.key) }
            }
        }
        current = (e, pid, now)
    }

    static func openRecent() {
        guard enabled else { off(); return }
        let startedAt = Date()
        visits = visits.filter { v in NSRunningApplication(processIdentifier: v.pid).map { !$0.isTerminated } ?? false }
        var jobs: [Job] = []
        for v in visits {
            if let cur = current, CFEqual(cur.element, v.element.value) { continue }
            guard let app = NSRunningApplication(processIdentifier: v.pid) else { continue }
            jobs.append(Job(visit: v, bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "", cached: probes[v.id]))
        }
        let here = current.map { Handed($0.element) }
        let hereApp = current.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        let hereBundle = hereApp?.bundleIdentifier ?? "", hereName = hereApp?.localizedName ?? ""
        guard !jobs.isEmpty else { Speech.speakMessage(String(localized: "no recent places", comment: "Spoken message: no place has been stayed at long enough yet")); return }
        listGeneration += 1
        let generation = listGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let found = gather(jobs, here: here)
            onMain {
                guard generation == listGeneration, InputManager.lastKeyDownAt <= startedAt else { Log.io("places: the user moved on; recent places not shown"); return }
                for p in found.probes { probes[p.id] = p }
                func record(_ p: Probe) -> PlaceRecord? {
                    guard let fp = p.fingerprint else { return nil }
                    let name = PlacesLogic.autoName(text: fp.nodes.last?.text ?? "", axRole: fp.nodes.last?.role ?? "", windowTitle: fp.windowTitle, appName: p.appName)
                    return PlaceRecord(name: name, bundleID: p.bundleID, appName: p.appName, fingerprint: fp)
                }
                let now = found.here.map { PlaceRecord(name: "", bundleID: hereBundle, appName: hereName, fingerprint: $0) }
                let list = PlacesLogic.dedupe(found.probes.compactMap(record), excluding: now)
                guard !list.isEmpty else { Speech.speakMessage(String(localized: "no recent places", comment: "Spoken message: no place has been stayed at long enough yet")); return }
                Log.io("places: \(list.count) recent places")
                present(String(localized: "Recent places", comment: "Title of the list of places you were at recently, newest first, which you narrow by typing"), list, previousFirst: true) { jump(to: $0) }
            }
        }
    }

    /// Fingerprints the references, newest first, within two seconds: not on the main thread. A reference that is a menu
    /// item, a window or an empty group says nothing about where the user was, and one that is gone has no fingerprint.
    nonisolated private static func gather(_ jobs: [Job], here: Handed<AXUIElement>?) -> (probes: [Probe], here: FocusFingerprint?) {
        let deadline = Date().addingTimeInterval(2)
        var here_ = here.flatMap { FocusMemory.fingerprint(of: $0.value, root: nil, budget: 0.3) }
        if let f = here_, !f.isUsable { here_ = nil }
        var out: [Probe] = []
        var usable = 0
        for job in jobs {
            guard Date() < deadline, usable < PlacesLogic.recentLimit + 5 else { break }
            if let cached = job.cached {
                out.append(cached)
                if cached.fingerprint != nil { usable += 1 }
                continue
            }
            let e = job.visit.element.value
            AXUIElementSetMessagingTimeout(e, 0.5)
            let role = e.role
            var fp: FocusFingerprint?
            if role != "?", !FocusMemory.isMenuRole(role),
               !FocusMemory.isGeneric(role: role, title: FocusMemory.trimmed(e.string(kAXTitleAttribute)), description: FocusMemory.trimmed(e.string(kAXDescriptionAttribute))) {
                fp = FocusMemory.fingerprint(of: e, root: nil, budget: 0.3)
                if let f = fp, !f.isUsable { fp = nil }
            }
            if fp != nil { usable += 1 }
            out.append(Probe(id: job.visit.id, bundleID: job.bundleID, appName: job.appName, fingerprint: fp))
        }
        return (out, here_)
    }

    // MARK: Going to a place

    /// The app and the moment a jump is under way, so FocusMemory.returned does not put the app's own remembered place
    /// over the one chosen.
    private static var jumping: (pid: pid_t, until: Date)?
    private static var jumpGeneration = 0

    static func holdsFocus(pid: pid_t) -> Bool {
        guard let j = jumping, j.pid == pid else { return false }
        return Date() < j.until
    }

    private static func runningApp(for r: PlaceRecord) -> NSRunningApplication? {
        if !r.bundleID.isEmpty {
            return NSRunningApplication.runningApplications(withBundleIdentifier: r.bundleID).first { !$0.isTerminated }
        }
        guard !r.appName.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { !$0.isTerminated && $0.activationPolicy == .regular && $0.localizedName == r.appName }
    }

    /// Brings the app forward if it is not, finds the place in its windows (the one with the title it had first, then the
    /// others), and gives it the focus. When it cannot be found the focus stays where it is.
    static func jump(to r: PlaceRecord) {
        let name = r.name
        guard let app = runningApp(for: r) else {
            Speech.speakMessage(String(localized: "Could not find \(name): \(r.appName) is not open", comment: "Spoken message: a bookmarked place could not be found because its app is not running; the place, then the app"))
            return
        }
        let pid = app.processIdentifier
        let startedAt = Date()
        jumpGeneration += 1
        let generation = jumpGeneration
        jumping = (pid, startedAt.addingTimeInterval(6))
        var wait: TimeInterval = 0
        if AXHandler.shared.activePid != pid {
            ApplicationChooser.switchTo(ApplicationChooser.Entry(pid: pid, name: r.appName, windows: []), window: nil)
            wait = 0.5
        }
        let fp = r.fingerprint
        onMain(after: wait) {
            DispatchQueue.global(qos: .userInitiated).async {
                let hit = locate(fp, pid: pid).map { Handed($0) }
                onMain {
                    guard generation == jumpGeneration else { return }
                    jumping = nil
                    guard InputManager.lastKeyDownAt <= startedAt else { Log.io("places: the user moved on; not moved to \"\(Log.words(name))\""); return }
                    guard let found = hit?.value else {
                        Log.io("places: could not find \"\(Log.words(name))\" again; focus left alone")
                        Speech.speakMessage(String(localized: "Could not find \(name)", comment: "Spoken message: a bookmarked place could not be found again; %@ is its name"))
                        return
                    }
                    if let window = found.element(kAXWindowAttribute) { _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
                    let how = FocusMemory.put(found, pid: pid)
                    Log.io("places: to \(found.role) \"\(Log.words(name))\" in pid \(pid) (\(how))")
                }
            }
        }
    }

    nonisolated private static func locate(_ fp: FocusFingerprint, pid: pid_t, budget: TimeInterval = 2.5) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(budget)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var windows = app.elements(kAXWindowsAttribute)
        if let focused = app.element(kAXFocusedWindowAttribute), !windows.contains(where: { CFEqual($0, focused) }) { windows.insert(focused, at: 0) }
        let titles = windows.map { FocusMemory.normalise(FocusMemory.trimmed($0.string(kAXTitleAttribute))) }
        for i in PlacesLogic.windowOrder(titles: titles, wanted: fp.windowTitle) {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            if let hit = FocusMemory.find(fp, under: windows[i], budget: min(0.8, left)) { return hit }
        }
        return nil
    }
}

/// Bookmarks and recent places. VO-Option-B, G and P are free in both keyboard styles (checked against every key in
/// Sources and Resources, 9 Nov 2026; VO-Option-J is the braille auto scroll key), so they can be rebound in the keyboard
/// commands editor if one clashes. Deleting a bookmark and the on/off switch have no key by default.
final class PlacesPlugin: GlobalPlugin {
    required init() {
        super.init()
        script("placesBookmark", String(localized: "Bookmarks the item you are on, so a key can bring you back to it", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:turnover+option+b"], category: "Waypoint") { _ in Places.bookmarkHere() }
        script("placesJump", String(localized: "Lists your bookmarks, narrowed as you type; Return goes to one, in its app", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:turnover+option+g"], category: "Waypoint") { _ in Places.openBookmarks() }
        script("placesRecent", String(localized: "Lists the places you stayed at recently, the one before this first; Return goes back to it", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:turnover+option+p"], category: "Waypoint") { _ in Places.openRecent() }
        script("placesDelete", String(localized: "Lists your bookmarks; Return deletes the one you are on", comment: "A command, as the key list and keyboard help say it"),
               category: "Waypoint") { _ in Places.openDelete() }
        script("placesEnable", String(localized: "Turns bookmarks and recent places on or off", comment: "A command, as the key list and keyboard help say it"), category: "Waypoint") { _ in
            Places.enabled.toggle()
            Speech.speakMessage(Places.enabled ? String(localized: "places on", comment: "Spoken message") : String(localized: "places off", comment: "Spoken message"))
        }
    }
}
