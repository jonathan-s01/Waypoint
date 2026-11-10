// SPDX-License-Identifier: GPL-3.0-or-later
// The Launcher pane: the keys that open an app or run an action when a held chord and a letter are pressed (Core's
// Launcher). Every control is an ordinary button, field or picker, reached with Tab: each row is a button that edits the
// binding, with a Delete button beside it, and the key is a field that keeps the last key typed in it. Changes go to
// Waypoint as `_launcher` operations; the list is whatever Waypoint answers (the window keeps no copy).
import SwiftUI

extension Model {
    /// One change to the launcher's table or keys (LauncherSettings.apply in Core).
    func sendLauncher(_ operation: [String: Any]) {
        sendPatch(["_launcher": operation])
    }
}

struct LauncherBinding: Identifiable, Equatable {
    var key: String
    var kind: String
    var name: String
    var bundle: String
    var target: String
    var timeout: Double?
    var installed: Bool
    var id: String { key }

    init(_ d: [String: Any]) {
        key = d["key"] as? String ?? ""
        kind = d["kind"] as? String ?? "app"
        name = d["name"] as? String ?? ""
        bundle = d["bundle"] as? String ?? ""
        target = d["target"] as? String ?? ""
        timeout = (d["timeout"] as? NSNumber)?.doubleValue
        installed = d["installed"] as? Bool ?? true
    }

    init(key: String = "", kind: String = "app") {
        self.key = key; self.kind = kind; name = ""; bundle = ""; target = ""; timeout = nil; installed = true
    }

    /// What the binding is called when read out.
    var label: String { name.isEmpty ? (kind == "app" ? bundle : target) : name }

    var kindName: String {
        switch kind {
        case "shell": return String(localized: "shell command", comment: "Launcher: what a key does")
        case "open": return String(localized: "opens a link or file", comment: "Launcher: what a key does")
        case "command": return String(localized: "Waypoint command", comment: "Launcher: what a key does")
        default: return String(localized: "app", comment: "Launcher: what a key does")
        }
    }

    /// The row as one phrase: "G, Google Chrome, app".
    var spoken: String {
        var s = "\(key.uppercased()), \(label), \(kindName)"
        if kind == "app", !installed { s += ", " + String(localized: "not installed", comment: "Launcher: the app is not on this Mac") }
        return s
    }

    var payload: [String: Any] {
        var d: [String: Any] = ["key": key, "kind": kind, "name": name, "bundle": bundle, "target": target]
        if kind == "shell", let timeout { d["timeout"] = timeout }
        return d
    }

    var isComplete: Bool {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case "app": return !bundle.trimmingCharacters(in: .whitespaces).isEmpty || !name.trimmingCharacters(in: .whitespaces).isEmpty
        default: return !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct LauncherEdit: Identifiable {
    let id = UUID()
    let layer: Int
    /// The key the binding had when editing began; nil when it is new.
    let original: String?
    var binding: LauncherBinding
}

struct LauncherView: View {
    @EnvironmentObject var model: Model
    @State private var editing: LauncherEdit?
    @State private var confirmReset = false

    private var launcher: [String: Any] { model.special("_launcher") as? [String: Any] ?? [:] }
    private func bindings(_ layer: Int) -> [LauncherBinding] { (launcher["layer\(layer)"] as? [[String: Any]] ?? []).map(LauncherBinding.init) }
    private func hold(_ layer: Int) -> String { launcher["hold\(layer)"] as? String ?? "" }

    var body: some View {
        Form {
            Section {
                Toggle("Launcher on", isOn: Binding(get: { launcher["enabled"] as? Bool ?? true }, set: { model.sendLauncher(["op": "enabled", "value": $0]) }))
                Text("Hold the keys for a layer and press a letter to open an app, run a shell command, open a link or file, or run a Waypoint command. A letter with no key set goes through as usual, and so do the held keys with any other modifier.").font(.caption)
            }
            layerSection(1)
            layerSection(2)
            Section("Held keys") {
                LabeledContent("Layer 1") { Text(verbatim: hold(1)) }
                Button("Change layer 1 keys…") { model.sendLauncher(["op": "capture", "layer": 1]) }
                    .accessibilityHint("Waypoint asks you to hold the keys, then press any letter")
                LabeledContent("Layer 2") { Text(verbatim: hold(2)) }
                Button("Change layer 2 keys…") { model.sendLauncher(["op": "capture", "layer": 2]) }
                    .accessibilityHint("Waypoint asks you to hold the keys, then press any letter")
                Button("Put the held keys back") { model.sendLauncher(["op": "resetHolds"]) }
            }
            Section("The file") {
                if let status = launcher["status"] as? String, status != "ok" {
                    Text(verbatim: status).font(.caption)
                }
                if let skipped = launcher["skipped"] as? [String], !skipped.isEmpty {
                    Text(verbatim: String(localized: "Entries left out of the file: \(skipped.joined(separator: "; "))", comment: "Launcher: entries of the file that could not be used")).font(.caption)
                }
                if let file = launcher["file"] as? String {
                    LabeledContent("Kept in") { Text(verbatim: file).textSelection(.enabled) }
                }
                Button("Read the file again") { model.sendLauncher(["op": "reload"]) }
                    .accessibilityHint("For after editing the file by hand")
                Button("Reset all keys to the defaults…", role: .destructive) { confirmReset = true }
            }
            Section("Good to know") {
                Text("Right Command with C, X, Z, S, F, T, H or M is normally Copy, Cut, Undo, Save, Find, New Tab, Hide or Minimize. A letter that has a key here takes over from that. Delete the key here to get the usual command back.").font(.caption)
                Text("Layer 2, with Right Option held too, starts empty. Right Command with Right Option runs layer 2 only, never layer 1 as well. Keys such as the arrows and F keys can be given in the file, by name.").font(.caption)
                Text("When an app is already in front, its key brings its other window forward. An app that is not installed says so.").font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Launcher")
        .sheet(item: $editing) { edit in
            LauncherEditor(edit: edit, taken: Set(bindings(edit.layer).map(\.key)).subtracting(edit.original.map { [$0] } ?? [])) { saved in
                model.sendLauncher(["op": "set", "layer": edit.layer, "replaces": edit.original ?? saved.key, "binding": saved.payload])
                editing = nil
            } cancel: { editing = nil }
        }
        .confirmationDialog("Reset all launcher keys to the defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.sendLauncher(["op": "reset"]) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Both layers are replaced. A copy of the file is kept next to it.")
        }
    }

    @ViewBuilder private func layerSection(_ layer: Int) -> some View {
        let list = bindings(layer)
        Section {
            if list.isEmpty {
                Text("No keys yet.").font(.caption)
            }
            ForEach(list) { b in
                HStack {
                    Button { editing = LauncherEdit(layer: layer, original: b.key, binding: b) } label: {
                        HStack {
                            Text(verbatim: b.key.uppercased()).bold().frame(minWidth: 28, alignment: .leading)
                            Text(verbatim: b.label)
                            Spacer()
                            Text(verbatim: b.kindName).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: b.spoken))
                    .accessibilityHint("Edit")
                    Button(role: .destructive) { model.sendLauncher(["op": "delete", "layer": layer, "key": b.key]) } label: { Image(systemName: "trash") }
                        .accessibilityLabel(Text(verbatim: String(localized: "Delete \(b.key.uppercased())", comment: "Launcher: delete a key; %@ is the key")))
                }
            }
            Button("Add a key to layer \(String(layer))…") { editing = LauncherEdit(layer: layer, original: nil, binding: LauncherBinding()) }
        } header: {
            Text(verbatim: String(localized: "Layer \(String(layer)): hold \(hold(layer))", comment: "Launcher: a list of keys; the layer's number, then the keys held"))
        }
    }
}

struct LauncherEditor: View {
    @State var edit: LauncherEdit
    let taken: Set<String>
    let save: (LauncherBinding) -> Void
    let cancel: () -> Void
    @State private var timeoutText: String

    init(edit: LauncherEdit, taken: Set<String>, save: @escaping (LauncherBinding) -> Void, cancel: @escaping () -> Void) {
        _edit = State(initialValue: edit)
        self.taken = taken; self.save = save; self.cancel = cancel
        _timeoutText = State(initialValue: edit.binding.timeout.map { String(Int($0)) } ?? "")
    }

    private var b: Binding<LauncherBinding> { $edit.binding }
    private var used: Bool { taken.contains(edit.binding.key.lowercased()) }

    var body: some View {
        Form {
            Section {
                // The last key typed here is the key: pressing another letter replaces it.
                TextField("Key", text: Binding(get: { edit.binding.key }, set: { edit.binding.key = String($0.suffix(1)).lowercased() }))
                    .accessibilityHint("Press the letter or number for this binding")
                if used { Text("That key already has a binding in this layer.").font(.caption) }
                Picker("Does this", selection: b.kind) {
                    Text("Open an app").tag("app")
                    Text("Run a shell command").tag("shell")
                    Text("Open a link or file").tag("open")
                    Text("Run a Waypoint command").tag("command")
                }
            }
            Section {
                switch edit.binding.kind {
                case "app":
                    TextField("App name", text: b.name)
                    TextField("Bundle identifier", text: b.bundle)
                    Text("The name is said, and used to find the app when there is no identifier or it is not found. For example Google Chrome and com.google.Chrome.").font(.caption)
                case "shell":
                    TextField("Name, said when it fails (optional)", text: b.name)
                    TextField("Shell command", text: b.target)
                    TextField("Seconds allowed (default 30)", text: $timeoutText)
                    Text("Run with zsh in your home folder, in the background. Nothing it prints is kept; a failure is spoken.").font(.caption)
                case "open":
                    TextField("Name, said when opening (optional)", text: b.name)
                    TextField("Link or file path", text: b.target)
                    Text("A link such as https://example.com, or a file or folder such as ~/Documents.").font(.caption)
                default:
                    TextField("Name, said on a problem (optional)", text: b.name)
                    TextField("Waypoint command name", text: b.target)
                    Text("A command as the key list names it, for example reviewLayerEnable or launcherList.").font(.caption)
                }
            }
            HStack {
                Button("Cancel", role: .cancel) { cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    var saved = edit.binding
                    saved.timeout = saved.kind == "shell" ? Double(timeoutText.trimmingCharacters(in: .whitespaces)) : nil
                    save(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!edit.binding.isComplete || used)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 360)
    }
}
