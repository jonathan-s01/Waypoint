// SPDX-License-Identifier: GPL-3.0-or-later
// Focus memory kept across restarts (of an app, and of Waypoint): the places FocusMemory records, saved by the app's
// bundle id in focus-memory.json in the support folder. Only fingerprints are kept (roles, identifiers and at most 80
// characters of text per level), never a live element, and an entry older than a week is dropped. A switch turns it off
// (waypoint.focusMemory.persist, on by default); off, the file is neither read nor written. "focusMemoryForget" in the key
// list empties it.
import Foundation
import AppKit
import TurnOverAX

/// One remembered place as it is written to the file.
nonisolated public struct StoredPlace: Codable, Equatable, Sendable {
    public var kind: String          // "element", or "document" (a reading position in a message history)
    public var windowTitle: String
    public var nodes: [PlaceNode]
    public var offset: Int
    public var line: String
    public var newest: String
    public var at: Date
    public init(kind: String = "element", windowTitle: String = "", nodes: [PlaceNode] = [], offset: Int = 0, line: String = "", newest: String = "", at: Date) {
        self.kind = kind; self.windowTitle = windowTitle; self.nodes = nodes; self.offset = offset; self.line = line; self.newest = newest; self.at = at
    }
}

nonisolated public struct FocusStoreFile: Codable, Equatable, Sendable {
    public var version = 1
    /// Bundle id, then the window title as FocusMemory.normalise gives it.
    public var apps: [String: [String: StoredPlace]] = [:]
    /// "bundle id|part name".
    public var regions: [String: StoredPlace] = [:]
    public init() {}
}

/// The pure side: what a file holds, what is kept, how it is read and written. Tested.
nonisolated public enum FocusStoreLogic {
    public static let maxAge: TimeInterval = 7 * 24 * 3600
    public static let maxApps = 60
    public static let maxWindowsPerApp = 8
    public static let maxRegions = 120

    public static func stored(_ fp: FocusFingerprint, at: Date) -> StoredPlace {
        StoredPlace(windowTitle: fp.windowTitle, nodes: fp.nodes.map { PlaceNode(role: $0.role, id: $0.id, text: $0.text, index: $0.index) }, at: at)
    }

    /// The fingerprint of an element place; nil for a document place or one that could never be found again.
    public static func fingerprint(_ p: StoredPlace) -> FocusFingerprint? {
        guard p.kind == "element" else { return nil }
        let fp = FocusFingerprint(windowTitle: p.windowTitle, nodes: p.nodes.map { FocusNode(role: $0.role, id: $0.id, text: $0.text, index: $0.index) })
        return fp.isUsable ? fp : nil
    }

    /// Old entries, and the oldest beyond the limits, dropped; empty apps removed.
    public static func pruned(_ file: FocusStoreFile, now: Date) -> FocusStoreFile {
        var out = file
        func fresh(_ p: StoredPlace) -> Bool { now.timeIntervalSince(p.at) <= maxAge }
        for (bundle, windows) in out.apps {
            var kept = windows.filter { fresh($0.value) }
            if kept.count > maxWindowsPerApp { kept = Dictionary(uniqueKeysWithValues: kept.sorted { $0.value.at > $1.value.at }.prefix(maxWindowsPerApp).map { ($0.key, $0.value) }) }
            out.apps[bundle] = kept.isEmpty ? nil : kept
        }
        if out.apps.count > maxApps {
            let newest = out.apps.sorted { ($0.value.values.map(\.at).max() ?? .distantPast) > ($1.value.values.map(\.at).max() ?? .distantPast) }.prefix(maxApps)
            out.apps = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        out.regions = out.regions.filter { fresh($0.value) }
        if out.regions.count > maxRegions {
            out.regions = Dictionary(uniqueKeysWithValues: out.regions.sorted { $0.value.at > $1.value.at }.prefix(maxRegions).map { ($0.key, $0.value) })
        }
        return out
    }

    public static func encode(_ file: FocusStoreFile) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(file)
    }

    /// nil when the data is not a focus-memory file this version knows.
    public static func decode(_ data: Data) -> FocusStoreFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(FocusStoreFile.self, from: data), file.version == 1 else { return nil }
        return file
    }

    public static func regionKey(bundle: String, part: String) -> String { "\(bundle)|\(part)" }
}

/// The file, and the hooks FocusMemory calls (main thread). Writing is off the main thread, a second after the last change.
enum FocusMemoryStore {
    private static let fileName = "focus-memory.json"
    private static var file: FocusStoreFile?
    private static var saveScheduled = false
    private static let ioQueue = DispatchQueue(label: "waypoint.focusmemory.store", qos: .utility)

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "waypoint.focusMemory.persist") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "waypoint.focusMemory.persist") }
    }

    private static func bundle(of pid: pid_t) -> String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }

    private static func current() -> FocusStoreFile {
        if let file { return file }
        var loaded = FocusStoreFile()
        if let data = try? Data(contentsOf: AppPaths.file(fileName)) {
            if let f = FocusStoreLogic.decode(data) { loaded = FocusStoreLogic.pruned(f, now: Date()) }
            else { Log.io("focus memory: \(fileName) could not be read; starting empty") }
        }
        file = loaded
        return loaded
    }

    private static func changed(_ f: FocusStoreFile) {
        file = f
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            saveScheduled = false
            writeNow()
        }
    }

    /// Encoded here, written on the io queue.
    static func writeNow() {
        guard enabled, let f = file, let data = FocusStoreLogic.encode(FocusStoreLogic.pruned(f, now: Date())) else { return }
        let url = AppPaths.file(fileName)
        ioQueue.async {
            do { try data.write(to: url, options: .atomic) }
            catch { Log.io("focus memory: could not write \(fileName): \(error.localizedDescription)") }
        }
    }

    // MARK: Per application

    static func saveApp(pid: pid_t, _ fp: FocusFingerprint) {
        guard enabled, let b = bundle(of: pid) else { return }
        var f = current()
        f.apps[b, default: [:]][fp.windowTitle] = FocusStoreLogic.stored(fp, at: Date())
        changed(f)
    }

    static func clearApp(pid: pid_t, windowTitle: String) {
        guard enabled, let b = bundle(of: pid) else { return }
        var f = current()
        guard f.apps[b]?[windowTitle] != nil else { return }
        f.apps[b]?[windowTitle] = nil
        changed(f)
    }

    /// What was kept for an app's windows, as fingerprints.
    static func apps(pid: pid_t) -> [String: FocusFingerprint] {
        guard enabled, let b = bundle(of: pid), let windows = current().apps[b] else { return [:] }
        let now = Date()
        var out: [String: FocusFingerprint] = [:]
        for (title, p) in windows where now.timeIntervalSince(p.at) <= FocusStoreLogic.maxAge {
            if let fp = FocusStoreLogic.fingerprint(p) { out[title] = fp }
        }
        return out
    }

    // MARK: Per region

    static func saveRegion(name: String, pid: pid_t, _ place: FocusPlace, at: Date) {
        guard enabled, let b = bundle(of: pid) else { return }
        var f = current()
        switch place {
        case .element(let fp): f.regions[FocusStoreLogic.regionKey(bundle: b, part: name)] = FocusStoreLogic.stored(fp, at: at)
        case .document(let offset, let line, let newest):
            f.regions[FocusStoreLogic.regionKey(bundle: b, part: name)] = StoredPlace(kind: "document", offset: offset, line: line, newest: newest, at: at)
        }
        changed(f)
    }

    static func region(name: String, pid: pid_t) -> (place: FocusPlace, at: Date)? {
        guard enabled, let b = bundle(of: pid), let p = current().regions[FocusStoreLogic.regionKey(bundle: b, part: name)],
              Date().timeIntervalSince(p.at) <= FocusStoreLogic.maxAge else { return nil }
        if p.kind == "document" { return (.document(offset: p.offset, line: p.line, newest: p.newest), p.at) }
        guard let fp = FocusStoreLogic.fingerprint(p) else { return nil }
        return (.element(fp), p.at)
    }

    // MARK: Quit, and forgetting

    /// Waypoint is stopping: the front app's last focus never "left", so it is kept now.
    static func flushActive() {
        guard enabled else { return }
        FocusMemory.leaving(pid: AXHandler.shared.activePid)
        writeNowBlocking()
    }

    /// At quit the write must finish before the process goes.
    private static func writeNowBlocking() {
        guard let f = file, let data = FocusStoreLogic.encode(FocusStoreLogic.pruned(f, now: Date())) else { return }
        do { try data.write(to: AppPaths.file(fileName), options: .atomic) }
        catch { Log.io("focus memory: could not write \(fileName): \(error.localizedDescription)") }
    }

    static func forgetAll() {
        file = FocusStoreFile()
        try? FileManager.default.removeItem(at: AppPaths.file(fileName))
    }
}
