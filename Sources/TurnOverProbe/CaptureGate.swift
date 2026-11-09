// SPDX-License-Identifier: GPL-3.0-or-later
// turnover-probe capture: one timeline of what an app reports while you use it.
//
// It follows the front app (or one pinned with --app/--bundle/--pid) and writes, with wall-clock times:
//   NOTIF  every accessibility notification, with the element's role, name, id, selection, value and the text after
//          the caret; for a list that changes its selection, its children and which are selected;
//   TREE   a bounded tree of the window when the window changes, and on Control-Option-Shift-T;
//   KEY    every key pressed (needs a listen-only tap; if macOS refuses it the rest still works);
//   MARK   Control-Option-Shift-M: a numbered marker to refer to afterwards ("at mark 3 I pressed Enter");
//   WP     the new lines of Waypoint's own log, so what it did sits in the same timeline.
// Passwords: nothing is written for a secure field, for a field whose name suggests a secret, or for any text field
// while macOS secure input is on; keys typed then are logged as "(secure)". --no-values also leaves out every field
// value and typed character. The files are local, in ~/Library/Application Support/TurnOver/captures/, and the folder
// is kept under 1 GB by deleting the oldest files first.
// Options: --seconds N (default 1800) --app Name | --bundle id | --pid N (pin one app) --no-values
import Foundation
import AppKit
import ApplicationServices
import Carbon
import TurnOverAX

private enum Cap {
    nonisolated(unsafe) static var handle: FileHandle?
    nonisolated(unsafe) static var path = ""
    nonisolated(unsafe) static var dir = URL(fileURLWithPath: "/")
    nonisolated(unsafe) static var written: UInt64 = 0
    nonisolated(unsafe) static var sinceCheck: UInt64 = 0
    nonisolated(unsafe) static var stopped = false
    nonisolated(unsafe) static var last = ""
    nonisolated(unsafe) static var repeats = 0
    static let limit: UInt64 = 1 << 30
    static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func open() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurnOver/captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let url = dir.appendingPathComponent("capture-\(stamp).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        path = url.path
        prune()
    }

    /// Oldest files go until the folder fits; if this capture alone has reached the limit it stops.
    static func prune() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "log" && $0.path != path }
            .map { f -> (URL, UInt64, Date) in
                let v = try? f.resourceValues(forKeys: Set(keys))
                return (f, UInt64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.2 < $1.2 }
        var total = written + files.reduce(0) { $0 + $1.1 }
        while total > limit, !files.isEmpty {
            let old = files.removeFirst()
            try? FileManager.default.removeItem(at: old.0)
            total -= old.1
        }
        if total > limit { stopped = true }
    }

    static func raw(_ text: String) {
        guard !stopped, let handle else { return }
        let data = Data(text.utf8)
        do { try handle.write(contentsOf: data) } catch { return }
        written += UInt64(data.count); sinceCheck += UInt64(data.count)
        if sinceCheck > 8 << 20 { sinceCheck = 0; prune() }
    }

    /// A line identical to the one before is counted instead of written again.
    static func line(_ text: String) {
        if text == last { repeats += 1; return }
        flushRepeats()
        last = text
        raw("\(clock.string(from: Date())) \(text)\n")
    }

    static func flushRepeats() {
        if repeats > 0 { raw("\(clock.string(from: Date())) (the line above repeated \(repeats) more times)\n"); repeats = 0 }
    }
}

private let secretWords = try! NSRegularExpression(
    pattern: "pass(word|code|phrase)|secret|\\bpin\\b|cvv|cvc|security code|card number|social security|\\bssn\\b",
    options: .caseInsensitive)

private func looksSecret(_ strings: [String?]) -> Bool {
    strings.contains { s in
        guard let s, !s.isEmpty else { return false }
        return secretWords.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

private let capValues: Bool = !(Options(Array(CommandLine.arguments.dropFirst(2))).has("no-values")
    || Options(Array(CommandLine.arguments.dropFirst(2))).string("no-values") != nil)
nonisolated(unsafe) private var capMarks = 0
nonisolated(unsafe) private var capFrontPid: pid_t = 0
nonisolated(unsafe) private var capObserver: AXObserver?
nonisolated(unsafe) private var capObservedApp: AXUIElement?

private let capAttributes: [String] = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute,
    kAXHelpAttribute, "AXIdentifier", "AXDOMIdentifier", kAXSelectedAttribute, kAXValueAttribute,
    kAXSelectedTextRangeAttribute, kAXRoleDescriptionAttribute,
]

private func shown(_ s: String, _ n: Int) -> String {
    let t = s.replacingOccurrences(of: "\n", with: "⏎")
    return t.count > n ? String(t.prefix(n)) + "…" : t
}

/// What one element is, as one line. A secret element yields only its role.
private func describe(_ el: AXUIElement, values: Bool = true) -> (text: String, secret: Bool) {
    let a = el.attrs(capAttributes)
    let role = (a[kAXRoleAttribute] as? String) ?? "?"
    let sub = a[kAXSubroleAttribute] as? String
    let title = a[kAXTitleAttribute] as? String
    let desc = a[kAXDescriptionAttribute] as? String
    let place = a[kAXPlaceholderValueAttribute] as? String
    let id = a["AXIdentifier"] as? String
    let dom = a["AXDOMIdentifier"] as? String
    let textual = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    let secret = role == "AXSecureTextField" || sub == "AXSecureTextField"
        || looksSecret([title, desc, place, id, dom, a[kAXHelpAttribute] as? String])
        || (textual && IsSecureEventInputEnabled())
    var out = role + (sub.map { "/\($0)" } ?? "")
    if secret { return (out + " (secure: nothing recorded)", true) }
    if let title, !title.isEmpty { out += " title \"\(shown(title, 100))\"" }
    if let desc, !desc.isEmpty { out += " desc \"\(shown(desc, 160))\"" }
    if let id, !id.isEmpty { out += " id \(shown(id, 60))" }
    if let dom, !dom.isEmpty { out += " dom \(shown(dom, 60))" }
    if let place, !place.isEmpty { out += " placeholder \"\(shown(place, 60))\"" }
    if let s = a[kAXSelectedAttribute] as? NSNumber { out += " selected=\(s.boolValue ? 1 : 0)" }
    let v = a[kAXValueAttribute]
    if let n = v as? NSNumber {
        out += " value \(n)"
    } else if let s = v as? String {
        let units = s.utf16.count
        if values && capValues {
            out += " value \"\(shown(s, 120))\" (\(units) units)"
            if let r = cfRange(a[kAXSelectedTextRangeAttribute]), r.location != Int.max, r.location >= 0, r.location + r.length <= units {
                out += " caret \(r.location)+\(r.length)"
                let after = Array(s.utf16.dropFirst(r.location + r.length).prefix(80))
                if !after.isEmpty { out += " after-caret \"\(shown(String(decoding: after, as: UTF16.self), 80))\"" }
            }
        } else {
            out += " value (\(units) units)"
        }
    }
    return (out, false)
}

private func dumpChildren(of el: AXUIElement) {
    let kids = el.elements(kAXChildrenAttribute)
    var lines: [String] = []
    for k in kids.prefix(30) {
        let d = describe(k)
        lines.append("    " + d.text)
    }
    Cap.line("      children: \(kids.count)\(kids.count > 30 ? " (first 30)" : "")")
    for l in lines { Cap.line(l) }
}

private func dumpTree(from root: AXUIElement, label: String, depth: Int = 5, limit: Int = 250) {
    Cap.line("TREE  \(label)")
    var count = 0
    func walk(_ e: AXUIElement, _ d: Int) {
        guard d <= depth, count < limit else { return }
        count += 1
        let info = describe(e)
        let focused = (e.attr(kAXFocusedAttribute) as? Bool) == true ? " FOCUSED" : ""
        Cap.line("TREE  " + String(repeating: "  ", count: d) + info.text + focused)
        if info.secret { return }
        for c in e.elements(kAXChildrenAttribute) { walk(c, d + 1) }
    }
    walk(root, 0)
    Cap.line("TREE  end (\(count) elements)")
}

private func dumpFrontWindow(_ label: String) {
    guard capFrontPid != 0 else { return }
    let app = AXUIElementCreateApplication(capFrontPid)
    AXUIElementSetMessagingTimeout(app, 2)
    if let w = app.element(kAXFocusedWindowAttribute) { dumpTree(from: w, label: label) }
}

private let capCallback: AXObserverCallbackWithInfo = { _, el, name, _, _ in
    let n = name as String
    let d = describe(el)
    var parent = ""
    if !d.secret, let p = el.element(kAXParentAttribute) { parent = " in \(p.role)" }
    Cap.line("NOTIF \(n)  \(d.text)\(parent)")
    if d.secret { return }
    switch n {
    case "AXSelectedChildrenChanged", "AXMenuOpened":
        dumpChildren(of: el)
    case "AXFocusedWindowChanged":
        dumpFrontWindow("window changed")
    default: break
    }
}

private let capKeyCallback: CGEventTapCallBack = { _, type, event, refcon in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Cap.line("KEY   tap was disabled by macOS; re-enabling")
        if let refcon { CGEvent.tapEnable(tap: Unmanaged<CFMachPort>.fromOpaque(refcon).takeUnretainedValue(), enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let f = event.flags
    var mods = ""
    if f.contains(.maskControl) { mods += "ctrl+" }
    if f.contains(.maskAlternate) { mods += "opt+" }
    if f.contains(.maskShift) { mods += "shift+" }
    if f.contains(.maskCommand) { mods += "cmd+" }
    if f.contains(.maskControl) && f.contains(.maskAlternate) && f.contains(.maskShift) {
        if code == 46 { capMarks += 1; Cap.line("MARK  \(capMarks)"); return Unmanaged.passUnretained(event) }
        if code == 17 { Cap.line("KEY   \(mods)T: tree dump requested"); dumpFrontWindow("requested"); return Unmanaged.passUnretained(event) }
    }
    var text = "code \(code)"
    if IsSecureEventInputEnabled() {
        text = "(secure)"
    } else if capValues, let s = NSEvent(cgEvent: event)?.charactersIgnoringModifiers, !s.isEmpty,
              s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
        text = "\"\(s)\" code \(code)"
    }
    Cap.line("KEY   \(mods)\(text)")
    return Unmanaged.passUnretained(event)
}

private let capNotifications = [
    "AXFocusedUIElementChanged", "AXFocusedWindowChanged", "AXSelectedTextChanged", "AXValueChanged", "AXLayoutChanged",
    "AXAnnouncementRequested", "AXTitleChanged", "AXSelectedChildrenChanged", "AXSelectedRowsChanged",
    "AXRowCountChanged", "AXSelectedCellsChanged", "AXMenuOpened", "AXMenuClosed", "AXMenuItemSelected",
    "AXWindowCreated", "AXCreated", "AXUIElementDestroyed", "AXExpandedChanged",
]

private func capAttach(_ pid: pid_t) {
    if let obs = capObserver {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        capObserver = nil
    }
    capFrontPid = pid
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 2)
    capObservedApp = app
    var obs: AXObserver?
    guard AXObserverCreateWithInfoCallback(pid, capCallback, &obs) == .success, let obs else {
        Cap.line("FRONT could not observe pid \(pid)")
        return
    }
    var failed: [String] = []
    for n in capNotifications where AXObserverAddNotification(obs, app, n as CFString, nil) != .success { failed.append(n) }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
    capObserver = obs
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
    Cap.line("FRONT \(name) pid \(pid)\(failed.isEmpty ? "" : " (not available: \(failed.joined(separator: ", ")))")")
    if let f = app.element(kAXFocusedUIElementAttribute) { Cap.line("FOCUS \(describe(f).text)") }
    dumpFrontWindow("front app")
}

/// Waypoint's own log, new lines only, so its decisions share the timeline.
private final class WaypointTail {
    var url: URL?
    var offset: UInt64 = 0
    var pending = ""
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TurnOver/logs", isDirectory: true)

    func newest() -> URL? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("turnover-") && $0.pathExtension == "log" }
        return files.max { a, b in
            ((try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }

    func poll() {
        guard let latest = newest() else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: latest.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if latest != url { url = latest; offset = size; pending = ""; Cap.line("WP    following \(latest.lastPathComponent)"); return }
        guard size > offset, let h = try? FileHandle(forReadingFrom: latest) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let data = (try? h.read(upToCount: 1 << 20)) ?? Data()
        offset += UInt64(data.count)
        pending += String(decoding: data, as: UTF8.self)
        var parts = pending.components(separatedBy: "\n")
        pending = parts.removeLast()
        for p in parts where !p.isEmpty { Cap.line("WP    " + p) }
    }
}

func runCaptureGate(_ args: [String]) {
    let opts = Options(args)
    let seconds = opts.double("seconds", 1800)
    Cap.open()
    guard Cap.handle != nil else { Log.line("could not create the capture file"); return }
    Log.line("capture file: \(Cap.path)")
    Cap.line("CAPTURE started, values \(capValues ? "on" : "off"), secure input \(IsSecureEventInputEnabled() ? "ON" : "off"), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    Cap.line("CAPTURE Control-Option-Shift-M adds a numbered mark; Control-Option-Shift-T dumps the window's tree")

    let pinned = opts.has("app") || opts.has("bundle") || opts.has("pid") || opts.string("app") != nil
        || opts.string("bundle") != nil || opts.string("pid") != nil
    if pinned {
        guard let app = resolveApp(opts) else { Log.line("no target app"); return }
        capAttach(app.processIdentifier)
    } else {
        if let front = NSWorkspace.shared.frontmostApplication { capAttach(front.processIdentifier) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
            MainActor.assumeIsolated {
                guard pid != 0, pid != getpid(), pid != capFrontPid else { return }
                capAttach(pid)
            }
        }
    }

    var tapRef: CFMachPort?
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                   eventsOfInterest: mask, callback: capKeyCallback, userInfo: nil) {
        tapRef = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .defaultMode)
    } else {
        Cap.line("KEY   no key tap (Input Monitoring is not granted to this program); notifications and the Waypoint log are still recorded")
    }
    _ = tapRef

    let tail = WaypointTail()
    tail.poll()
    let timer = Timer(timeInterval: 0.4, repeats: true) { _ in MainActor.assumeIsolated { tail.poll(); Cap.flushRepeats() } }
    RunLoop.current.add(timer, forMode: .default)

    CFRunLoopRunInMode(.defaultMode, seconds, false)
    Cap.flushRepeats()
    Cap.line("CAPTURE ended\(Cap.stopped ? " (the 1 GB limit was reached and writing stopped)" : "")")
    Log.line("capture ended: \(Cap.path), \(Cap.written) bytes")
}
