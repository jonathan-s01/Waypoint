import Foundation

// The launcher's table of keys and its file (Waypoint, Nov 2026). The launcher runs a chosen action when a held chord and
// a letter are pressed: Right Command and a letter (layer 1), or Right Command, Right Option and a letter (layer 2).
// Every binding is data here, in ~/Library/Application Support/TurnOver/launcher.json, which can be edited by hand:
//
//   { "version": 1,
//     "layer1": [ { "key": "g", "kind": "app", "name": "Google Chrome", "bundle": "com.google.Chrome" },
//                 { "key": "u", "kind": "open", "target": "https://example.com", "name": "Example" } ],
//     "layer2": [ { "key": "d", "kind": "shell", "target": "say hello", "timeout": 10 } ] }
//
// Kinds: "app" (bundle and/or name), "shell" (target is run by /bin/zsh -c), "open" (target is a URL or a path),
// "command" (target is a Waypoint command's name, as the key list shows it). Unknown fields are ignored; a bad entry
// is skipped and logged, the others still load. A file that cannot be read at all is copied aside, the defaults are
// used, and the file itself stays as it is until the next save, which first keeps a copy of it (launcher.json.bak).

/// The decisions and the file format, pure: nothing here touches the keyboard or runs anything.
nonisolated public enum LauncherLogic {

    public typealias Device = ReviewLayerLogic.Device

    public static let currentVersion = 1
    /// Right Command; Right Command with Right Option.
    public static let defaultHold1: UInt = Device.rightCommand
    public static let defaultHold2: UInt = Device.rightCommand | Device.rightOption
    public static let defaultTimeout: Double = 30
    public static let maximumTimeout: Double = 300
    /// Hold to repeat: the wait before the first repeat, and the repeats a second, are kept within these.
    public static let delayRange: ClosedRange<Double> = 0.2...5
    public static let rateRange: ClosedRange<Double> = 1...30
    public static let defaultRepeatDelay: Double = 1.0

    public enum Kind: String, CaseIterable, Sendable {
        case app, shell, open, command
    }

    public struct Binding: Equatable, Sendable {
        /// The key's name as the key list spells it ("g", "7", "upArrow").
        public var key: String
        public var kind: Kind
        /// An app's display name, or what to call the action when it is spoken.
        public var name: String
        /// An app's bundle identifier.
        public var bundle: String
        /// The shell command, the URL or path, or the command's name.
        public var target: String
        /// Seconds a shell command may run; nil means the default.
        public var timeout: Double?
        /// Seconds a held key waits before it starts repeating; nil means the default. Only used with a `repeatRate`.
        public var repeatDelay: Double?
        /// Actions a second while the key stays held; nil means the action runs once, as the key goes down.
        public var repeatRate: Double?
        /// True when the key leaves speech that is playing alone (a volume key); every other key cuts it off.
        public var keepSpeech: Bool

        public init(key: String, kind: Kind, name: String = "", bundle: String = "", target: String = "", timeout: Double? = nil, repeatDelay: Double? = nil, repeatRate: Double? = nil, keepSpeech: Bool = false) {
            self.key = key; self.kind = kind; self.name = name; self.bundle = bundle; self.target = target; self.timeout = timeout
            self.repeatDelay = repeatDelay; self.repeatRate = repeatRate; self.keepSpeech = keepSpeech
        }

        public static func app(_ key: String, _ name: String, bundle: String) -> Binding { Binding(key: key, kind: .app, name: name, bundle: bundle) }

        /// What it needs to be able to run at all.
        public var isValid: Bool {
            switch kind {
            case .app: return !bundle.isEmpty || !name.isEmpty
            case .shell, .open, .command: return !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        /// What the action is called when spoken.
        public var label: String {
            if !name.isEmpty { return name }
            switch kind {
            case .app: return bundle
            case .shell, .open, .command: return target
            }
        }

        /// The kind and target in a few words, for lists.
        public var summary: String {
            switch kind {
            case .app: return bundle.isEmpty ? name : (name.isEmpty ? bundle : "\(name), \(bundle)")
            case .shell, .open, .command: return target
            }
        }
    }

    /// The two held chords, as the device bits of the modifier keys.
    public struct Holds: Equatable, Sendable {
        public var hold1: UInt, hold2: UInt
        public init(hold1: UInt = LauncherLogic.defaultHold1, hold2: UInt = LauncherLogic.defaultHold2) { self.hold1 = hold1; self.hold2 = hold2 }
        public static let standard = Holds()
    }

    public struct Table: Equatable, Sendable {
        public var layer1: [Binding]
        public var layer2: [Binding]
        public init(layer1: [Binding] = [], layer2: [Binding] = []) { self.layer1 = layer1; self.layer2 = layer2 }

        public func bindings(layer: Int) -> [Binding] { layer == 2 ? layer2 : layer1 }

        public func binding(layer: Int, key: String) -> Binding? {
            guard let k = LauncherLogic.normalizeKey(key) else { return nil }
            return bindings(layer: layer).first { $0.key == k }
        }

        /// Adds the binding, or replaces the one on the same key.
        public mutating func set(_ b: Binding, layer: Int) {
            var b = b
            guard let k = LauncherLogic.normalizeKey(b.key) else { return }
            b.key = k
            if layer == 2 { Table.put(b, in: &layer2) } else { Table.put(b, in: &layer1) }
        }

        @discardableResult
        public mutating func remove(key: String, layer: Int) -> Bool {
            guard let k = LauncherLogic.normalizeKey(key) else { return false }
            let before = bindings(layer: layer).count
            if layer == 2 { layer2.removeAll { $0.key == k } } else { layer1.removeAll { $0.key == k } }
            return bindings(layer: layer).count != before
        }

        private static func put(_ b: Binding, in list: inout [Binding]) {
            if let i = list.firstIndex(where: { $0.key == b.key }) { list[i] = b } else { list.append(b) }
        }

        /// Layer 1 as shipped: the owner's most used apps, bundle identifiers read from the installed apps' Info.plist files
        /// when this was written. An app that is not installed keeps its key and says so when pressed. Layer 2 is empty.
        public static let defaults = Table(layer1: [
            .app("g", "Google Chrome", bundle: "com.google.Chrome"),
            .app("h", "GitHub Copilot", bundle: "com.github.githubapp"),
            .app("o", "Microsoft Outlook", bundle: "com.microsoft.Outlook"),
            .app("m", "Microsoft Teams", bundle: "com.microsoft.teams2"),
            .app("s", "Safari", bundle: "com.apple.Safari"),
            .app("f", "Finder", bundle: "com.apple.finder"),
            .app("i", "Messages", bundle: "com.apple.MobileSMS"),
            .app("x", "Microsoft Excel", bundle: "com.microsoft.Excel"),
            .app("z", "Terminal", bundle: "com.apple.Terminal"),
            .app("c", "Colour Contrast Analyser", bundle: "com.electron.cca"),
            .app("t", "TextEdit", bundle: "com.apple.TextEdit"),
            Binding(key: "=", kind: .command, name: "Volume up", target: "volumeUp", repeatDelay: defaultRepeatDelay, repeatRate: 15, keepSpeech: true),
            Binding(key: "-", kind: .command, name: "Volume down", target: "volumeDown", repeatDelay: defaultRepeatDelay, repeatRate: 15, keepSpeech: true),
        ], layer2: [])
    }

    // MARK: Which keys

    /// A key's canonical name, nil when it is not a key a binding can have (a modifier key, or no key at all).
    public static func normalizeKey(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let code = KeyNames.code(for: KeyNames.canonical(t)), !(54...63).contains(code) else { return nil }
        return KeyNames.name(for: code)
    }

    /// Which layer the held modifier keys select, nil for none. The keys held must be exactly the chord's, so Right
    /// Command with Shift, Control, Left Command or Left Option is not the launcher's, and Right Command with Right
    /// Option is layer 2 and never also layer 1. A TurnOver key held means a Waypoint command, never the launcher.
    public static func layer(flags: UInt, holds: Holds, turnOverKey: Bool) -> Int? {
        guard !turnOverKey else { return nil }
        let held = flags & Device.all
        if holds.hold2 != 0, held == holds.hold2 { return 2 }
        if holds.hold1 != 0, held == holds.hold1 { return 1 }
        return nil
    }

    public struct Match: Equatable, Sendable {
        public let layer: Int
        public let binding: Binding
    }

    /// The binding a key press runs, nil when the key is not the launcher's (it then goes to the application as it is).
    public static func match(flags: UInt, keyName: String, turnOverKey: Bool, holds: Holds, table: Table) -> Match? {
        guard let layer = layer(flags: flags, holds: holds, turnOverKey: turnOverKey),
              let b = table.binding(layer: layer, key: keyName), b.isValid else { return nil }
        return Match(layer: layer, binding: b)
    }

    /// A hold can be any modifier keys, but not Shift alone: that would take every capital letter that is mapped.
    public static func isUsableHold(_ bits: UInt) -> Bool {
        bits & Device.all != 0 && bits & (Device.leftControl | Device.rightControl | Device.leftCommand | Device.rightCommand | Device.leftOption | Device.rightOption) != 0
    }

    /// "Right Command and Right Option".
    public static func holdName(_ bits: UInt) -> String {
        let names: [(UInt, String)] = [
            (Device.leftControl, "Left Control"), (Device.rightControl, "Right Control"),
            (Device.leftOption, "Left Option"), (Device.rightOption, "Right Option"),
            (Device.leftCommand, "Left Command"), (Device.rightCommand, "Right Command"),
            (Device.leftShift, "Left Shift"), (Device.rightShift, "Right Shift"),
        ]
        let parts = names.filter { bits & $0.0 != 0 }.map(\.1)
        switch parts.count {
        case 0: return "no keys"
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    public static func timeout(for b: Binding) -> Double {
        guard let t = b.timeout, t.isFinite, t > 0 else { return defaultTimeout }
        return min(t, maximumTimeout)
    }

    /// A rate within 1...30 a second, nil when there is none (absent, zero, negative or not a number): no repeating.
    public static func clampedRate(_ r: Double?) -> Double? {
        guard let r, r.isFinite, r > 0 else { return nil }
        return min(max(r, rateRange.lowerBound), rateRange.upperBound)
    }

    /// A delay within 0.2...5 seconds; the default when absent or not a number.
    public static func clampedDelay(_ d: Double?) -> Double {
        guard let d, d.isFinite else { return defaultRepeatDelay }
        return min(max(d, delayRange.lowerBound), delayRange.upperBound)
    }

    /// How a held key repeats: the wait before the first repeat and the time between repeats, in seconds. Nil for a
    /// binding with no repeat rate, which runs once as the key goes down.
    public static func repeatTiming(for b: Binding) -> (delay: Double, interval: Double)? {
        guard let rate = clampedRate(b.repeatRate) else { return nil }
        return (clampedDelay(b.repeatDelay), 1 / rate)
    }

    /// The window to bring forward when the app is already in front. The windows come front to back, so the back one
    /// is the one Command Grave Accent brings round, and each press goes one further. Nil when there is no other window.
    public static func nextWindowIndex(count: Int, current: Int?) -> Int? {
        guard count >= 2 else { return nil }
        guard let current, current >= 0, current < count else { return count - 1 }
        return current == count - 1 ? 0 : count - 1
    }

    // MARK: The file

    public enum Outcome: Equatable, Sendable {
        case ok
        /// The file did not exist; the defaults were written to it.
        case seeded
        /// The file was written by a newer version: read as far as it makes sense.
        case newer(Int)
        case corrupt(String)
    }

    public struct Loaded: Sendable {
        public var table: Table
        public var outcome: Outcome
        /// Entries left out, each with why.
        public var skipped: [String]
    }

    public static func encode(_ table: Table) -> Data {
        func entry(_ b: Binding) -> [String: Any] {
            var d: [String: Any] = ["key": b.key, "kind": b.kind.rawValue]
            if !b.name.isEmpty { d["name"] = b.name }
            if !b.bundle.isEmpty { d["bundle"] = b.bundle }
            if !b.target.isEmpty { d["target"] = b.target }
            if let t = b.timeout, b.kind == .shell { d["timeout"] = t }
            if let r = b.repeatRate {
                d["repeatRate"] = r
                if let delay = b.repeatDelay { d["repeatDelay"] = delay }
            }
            if b.keepSpeech { d["keepSpeech"] = true }
            return d
        }
        let root: [String: Any] = [
            "version": currentVersion,
            "about": "Waypoint launcher keys. layer1: hold Right Command and press the key. layer2: hold Right Command and Right Option. kind is app, shell, open or command. Optional repeatRate (1-30 a second) and repeatDelay (0.2-5 seconds) repeat a held key. Optional keepSpeech (true) leaves speech that is playing alone. Edit freely, then use the launcherReload command.",
            "layer1": table.layer1.map(entry),
            "layer2": table.layer2.map(entry),
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Reads a file's bytes: unknown fields are ignored, an entry that cannot work is skipped and named, and only a
    /// file that is not the launcher's at all is corrupt.
    public static func decode(_ data: Data) -> Loaded {
        func fail(_ why: String) -> Loaded { Loaded(table: .defaults, outcome: .corrupt(why), skipped: []) }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return fail("not valid JSON") }
        guard let root = object as? [String: Any] else { return fail("the top level is not an object") }
        guard let version = (root["version"] as? NSNumber)?.intValue, version >= 1 else { return fail("no version number") }
        guard root["layer1"] != nil || root["layer2"] != nil else { return fail("no layer1 or layer2") }
        var skipped: [String] = []
        func read(_ name: String) -> [Binding]? {
            guard let raw = root[name] else { return [] }
            guard let list = raw as? [Any] else { return nil }
            var out: [Binding] = []
            for (i, item) in list.enumerated() {
                let where_ = "\(name) entry \(i + 1)"
                guard let d = item as? [String: Any] else { skipped.append("\(where_): not an object"); continue }
                guard let rawKey = d["key"] as? String, let key = normalizeKey(rawKey) else { skipped.append("\(where_): no usable key"); continue }
                guard let kindName = d["kind"] as? String, let kind = Kind(rawValue: kindName.lowercased()) else { skipped.append("\(where_) (\(key)): unknown kind"); continue }
                func text(_ k: String) -> String { (d[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                var b = Binding(key: key, kind: kind, name: text("name"), bundle: text("bundle"), target: kind == .shell ? ((d["target"] as? String) ?? "") : text("target"))
                if let t = d["timeout"] as? NSNumber { b.timeout = t.doubleValue }
                if let rate = clampedRate((d["repeatRate"] as? NSNumber)?.doubleValue) {
                    b.repeatRate = rate
                    b.repeatDelay = clampedDelay((d["repeatDelay"] as? NSNumber)?.doubleValue)
                }
                b.keepSpeech = (d["keepSpeech"] as? NSNumber)?.boolValue ?? false
                guard b.isValid else { skipped.append("\(where_) (\(key)): nothing to \(kind.rawValue)"); continue }
                guard !out.contains(where: { $0.key == key }) else { skipped.append("\(where_) (\(key)): the key is used twice"); continue }
                out.append(b)
            }
            return out
        }
        guard let one = read("layer1"), let two = read("layer2") else { return fail("a layer is not a list") }
        return Loaded(table: Table(layer1: one, layer2: two), outcome: version > currentVersion ? .newer(version) : .ok, skipped: skipped)
    }

    /// Writes the table, keeping the file it replaces as `<file>.bak`. When the copy cannot be made the file is left alone.
    public static func save(_ table: Table, to url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            do { try fm.copyItem(at: url, to: backup) } catch { return false }
        }
        do { try encode(table).write(to: url, options: .atomic); return true } catch { return false }
    }

    /// Copies an unreadable file next to itself, so nothing the user wrote is lost; the copy's URL, nil if it could not be made.
    public static func keepCopyOfCorrupt(_ url: URL, at date: Date = Date()) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let copy = url.appendingPathExtension("corrupt-" + f.string(from: date))
        do { try FileManager.default.copyItem(at: url, to: copy); return copy } catch { return nil }
    }
}

/// The table and its file. Reading is by what the file says at the time: a hand edit is picked up at the next press of a
/// chord that could be the launcher's (one stat of the file), and the `launcherReload` command reads it at once.
public final class LauncherStore {
    public enum Status: Equatable {
        case ok, seeded, newer(Int), corrupt(String)
    }

    public let url: URL
    public private(set) var table: LauncherLogic.Table = .defaults
    public private(set) var status: Status = .ok
    public private(set) var skipped: [String] = []
    private var stamp: Stamp?

    private struct Stamp: Equatable { let modified: Date; let size: Int }

    public init(url: URL) {
        self.url = url
        reload()
    }

    private func currentStamp() -> Stamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), let m = a[.modificationDate] as? Date else { return nil }
        return Stamp(modified: m, size: (a[.size] as? NSNumber)?.intValue ?? 0)
    }

    /// Reads the file now. Returns true when the table came out of the file as it was written (false: defaults were used).
    @discardableResult
    public func reload() -> Bool {
        skipped = []
        guard FileManager.default.fileExists(atPath: url.path) else {
            table = .defaults
            if LauncherLogic.save(table, to: url) { status = .seeded; Log.info("launcher: wrote the default keys to \(url.lastPathComponent)") }
            else { status = .seeded; Log.warning("launcher: could not write \(url.path); using the default keys") }
            stamp = currentStamp()
            return true
        }
        stamp = currentStamp()
        guard let data = try? Data(contentsOf: url) else {
            table = .defaults; status = .corrupt("the file could not be read")
            Log.warning("launcher: \(url.lastPathComponent) could not be read; using the default keys")
            return false
        }
        let loaded = LauncherLogic.decode(data)
        skipped = loaded.skipped
        for s in loaded.skipped { Log.warning("launcher: skipped \(s)") }
        switch loaded.outcome {
        case .corrupt(let why):
            table = .defaults; status = .corrupt(why)
            let copy = LauncherLogic.keepCopyOfCorrupt(url)
            Log.warning("launcher: \(url.lastPathComponent) is not usable (\(why)); using the default keys. A copy is at \(copy?.lastPathComponent ?? "(could not be made)"); the file itself is untouched")
            return false
        case .newer(let v):
            table = loaded.table; status = .newer(v)
            Log.info("launcher: \(url.lastPathComponent) is version \(v), newer than this build reads (\(LauncherLogic.currentVersion)); read what could be")
        default:
            table = loaded.table; status = .ok
            Log.io("launcher: \(table.layer1.count) keys in layer 1, \(table.layer2.count) in layer 2")
        }
        return true
    }

    /// Reads the file again when it has changed (or gone) since it was last read or written here.
    public func reloadIfChanged() {
        if currentStamp() != stamp { reload() }
    }

    @discardableResult
    public func save() -> Bool {
        let ok = LauncherLogic.save(table, to: url)
        if ok {
            stamp = currentStamp()
            if case .corrupt = status { status = .ok }
        } else {
            Log.warning("launcher: could not save \(url.path)")
        }
        return ok
    }

    @discardableResult
    public func set(_ b: LauncherLogic.Binding, layer: Int) -> Bool {
        table.set(b, layer: layer)
        return save()
    }

    @discardableResult
    public func remove(key: String, layer: Int) -> Bool {
        guard table.remove(key: key, layer: layer) else { return false }
        return save()
    }

    @discardableResult
    public func resetToDefaults() -> Bool {
        table = .defaults
        skipped = []
        return save()
    }
}
