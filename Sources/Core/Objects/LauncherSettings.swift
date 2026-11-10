import Foundation

// The Settings window's side of the launcher (the Launcher pane): the table and the held keys as the window shows them,
// and its changes applied. The window holds no copy of its own: every change comes back as new state.

public enum LauncherSettings {

    private static func dict(_ b: LauncherLogic.Binding) -> [String: Any] {
        var d: [String: Any] = ["key": b.key, "kind": b.kind.rawValue, "name": b.name, "bundle": b.bundle, "target": b.target]
        if let t = b.timeout { d["timeout"] = t }
        if b.kind == .app { d["installed"] = LauncherApps.resolve(bundle: b.bundle, name: b.name) != nil }
        return d
    }

    static func state() -> [String: Any] {
        let store = Launcher.store
        var status = "ok"
        switch store.status {
        case .corrupt(let why): status = "The launcher file could not be read (\(why)), so the default keys are in use. The file is untouched; your next change here keeps a copy of it first."
        case .newer(let v): status = "The launcher file is from a newer version (\(v)); it was read as far as it could be."
        case .ok, .seeded: break
        }
        return [
            "enabled": Launcher.enabled,
            "hold1": LauncherLogic.holdName(Launcher.holds.hold1),
            "hold2": LauncherLogic.holdName(Launcher.holds.hold2),
            "layer1": store.table.layer1.map(dict),
            "layer2": store.table.layer2.map(dict),
            "status": status,
            "skipped": store.skipped,
            "file": store.url.path,
        ]
    }

    /// One change from the window: {"op": "set" | "delete" | "reset" | "reload" | "enabled" | "capture" | "resetHolds", ...}.
    static func apply(_ patch: [String: Any]) {
        let store = Launcher.store
        let layer = (patch["layer"] as? NSNumber)?.intValue == 2 ? 2 : 1
        switch patch["op"] as? String {
        case "set":
            guard let d = patch["binding"] as? [String: Any], let b = binding(from: d) else {
                Speech.speakMessage(String(localized: "That launcher key was not saved: it needs a key, and an app, a command, a link or a file to open", comment: "Spoken message"))
                return
            }
            let old = (patch["replaces"] as? String).flatMap(LauncherLogic.normalizeKey)
            if let old, old != b.key, store.table.binding(layer: layer, key: b.key) != nil {
                Speech.speakMessage(String(localized: "The \(b.key) key is already used in this layer; nothing changed", comment: "Spoken message: %@ is a key"))
                return
            }
            if let old, old != b.key { store.remove(key: old, layer: layer) }
            if !store.set(b, layer: layer) { Speech.speakMessage(String(localized: "The launcher file could not be saved", comment: "Spoken message")) }
        case "delete":
            if let k = patch["key"] as? String { store.remove(key: k, layer: layer) }
        case "reset":
            if !store.resetToDefaults() { Speech.speakMessage(String(localized: "The launcher file could not be saved", comment: "Spoken message")) }
        case "reload":
            Launcher.reload()
        case "enabled":
            if let on = patch["value"] as? Bool { Launcher.enabled = on }
        case "capture":
            Launcher.capture(layer: layer)
        case "resetHolds":
            Launcher.resetKeys()
        default:
            break
        }
    }

    /// A binding from the window's fields, nil when it could not run.
    public static func binding(from d: [String: Any]) -> LauncherLogic.Binding? {
        guard let key = (d["key"] as? String).flatMap(LauncherLogic.normalizeKey),
              let kind = (d["kind"] as? String).flatMap(LauncherLogic.Kind.init(rawValue:)) else { return nil }
        func text(_ k: String) -> String { (d[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        var b = LauncherLogic.Binding(key: key, kind: kind, name: text("name"), bundle: text("bundle"), target: kind == .shell ? ((d["target"] as? String) ?? "") : text("target"))
        if kind == .shell, let t = (d["timeout"] as? NSNumber)?.doubleValue, t > 0 { b.timeout = t }
        return b.isValid ? b : nil
    }
}
