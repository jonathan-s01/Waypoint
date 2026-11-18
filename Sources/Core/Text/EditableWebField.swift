// SPDX-License-Identifier: GPL-3.0-or-later
// A web page's multi-line text box (a contenteditable chat composer) read through the browser's text markers, not its
// AXValue. Waypoint only.
//
// Measured in the GitHub Copilot app's composer (WKWebView, AXTextArea, 18 Nov 2026): AXSelectedTextRange and the
// text markers agreed with the real caret, but AXValue and AXStringForRange held about two "\n" for each Return. Every
// offset after a line break read one or two characters late: arrows and Backspace said the wrong character, the word
// before was echoed, and the end was never reached ("bef▮ore." with the caret after "before."). Microsoft Teams
// (Chromium, 18 Nov 2026) reported its caret about two characters short of its value's end in the same way. The
// markers give the browser's own text, with one break per break.
//
// Only the field's own markers are used: its range, its selection and AXIndexForTextMarker, which count from the
// field's start. AXTextMarkerForIndex counts from the top of the window instead (Copilot, 18 Nov 2026: index 0 gave
// "S" from the sidebar, and the marker it gave had no index back), so offsets are never turned into markers: the text
// is read once and sliced. The first build did turn them, and every letter read as "blank".
import Foundation
import ApplicationServices
import TurnOverAX

/// A web text area whose text and caret are read through its text markers.
open class EditableWebField: EditableText, WebBridged {
    public lazy var bridge = WebDocumentBridge(webArea: element)
    open override var textInfoClass: TextInfo.Type { WebFieldTextInfo.self }

    /// The field's text as the browser holds it, one break per break.
    public func markerText() -> String? {
        guard let v = element.param("AXTextMarkerRangeForUIElement", element), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
        return element.param("AXStringForTextMarkerRange", v) as? String
    }

    /// The line around `offset` by its breaks, the break included; after a final break, the empty line at the end.
    public nonisolated static func hardLine(in text: String, at offset: Int) -> (Int, Int) {
        let u = Array(text.utf16), n = u.count
        func isBreak(_ c: UInt16) -> Bool { c == 10 || c == 13 || c == 0x2029 || c == 0x2028 }
        let o = min(max(offset, 0), n)
        if o == n, n > 0, isBreak(u[n - 1]) { return (n, n) }
        var s = o
        while s > 0, !isBreak(u[s - 1]) { s -= 1 }
        var e = o
        while e < n, !isBreak(u[e]) { e += 1 }
        if e < n { e += 1 }
        return (s, e)
    }

    /// The decision, pure: a multi-line text area that is not a password, inside a web page, whose browser answers a
    /// marker selection and counts its own text from 0.
    public nonisolated static func qualifies(axRole: String, subrole: String?, inWebArea: Bool, hasMarkerSelection: Bool, fieldStart: Int?) -> Bool {
        axRole == "AXTextArea" && subrole != "AXSecureTextField" && inWebArea && hasMarkerSelection && fieldStart == 0
    }

    /// Whether `element` is read this way. A browser without the marker calls, or one that counts the field from
    /// elsewhere in the page, keeps the AXValue reading.
    public static func isMarkerField(_ element: AXUIElement) -> Bool {
        guard element.role == "AXTextArea" else { return false }
        var p = element.element(kAXParentAttribute); var hops = 0; var inWeb = false
        while let x = p, hops < 40 { if x.role == "AXWebArea" { inWeb = true; break }; p = x.element(kAXParentAttribute); hops += 1 }
        guard inWeb else { return false }
        let bridge = WebDocumentBridge(webArea: element)
        let selection = bridge.selection()
        let ok = qualifies(axRole: "AXTextArea", subrole: element.string(kAXSubroleAttribute), inWebArea: true,
                           hasMarkerSelection: selection != nil, fieldStart: bridge.range(of: element)?.0)
        if !ok { Log.io("web field: no usable text markers (selection \(selection.map { "\($0.0)-\($0.1)" } ?? "none")); read by its value") }
        return ok
    }

    /// The caret by the field's index (AXSelectedTextRange) and by the markers, when they disagree: the log says so,
    /// so a mark in another browser shows whether its index or its markers drift.
    private var lastDisagreement: (Int, Int)?
    open override func event_caret() {
        if let r = cfRange(element.attr(kAXSelectedTextRangeAttribute)), let m = bridge.selection() {
            let pair = (r.location + r.length, m.1)
            if pair.0 != pair.1, lastDisagreement.map({ $0 != pair }) ?? true {
                Log.io("web field: the caret is \(pair.1) by the markers, \(pair.0) by the index; the markers are read")
            }
            lastDisagreement = pair.0 != pair.1 ? pair : nil
        }
        super.event_caret()
    }
}

/// A web field's text: the marker text, sliced by offset; the caret by the marker selection.
public final class WebFieldTextInfo: AXTextInfo {
    private lazy var markerText: String = (obj as? EditableWebField)?.markerText() ?? ""
    private var bridge: WebDocumentBridge { (obj as? WebBridged)?.bridge ?? WebDocumentBridge(webArea: obj.element) }

    public override func storyLength() -> Int { (markerText as NSString).length }
    public override func characterStoryLength() -> Int? { storyLength() }
    public override func textRange(_ s: Int, _ e: Int) -> String {
        let ns = markerText as NSString
        let cs = min(max(s, 0), ns.length), ce = min(max(e, cs), ns.length)
        return ns.substring(with: NSRange(location: cs, length: ce - cs))
    }
    public override func characterTextRange(_ s: Int, _ e: Int) -> String { textRange(s, e) }
    public override func caretOffset() -> Int? { bridge.selection()?.1 ?? super.caretOffset() }
    public override func selectionOffsets() -> (Int, Int)? { bridge.selection() ?? super.selectionOffsets() }

    /// The caret's line as the browser wraps it, from the caret's own marker; any other offset's by its breaks.
    public override func lineOffsets(_ offset: Int) -> (Int, Int)? {
        let hard = EditableWebField.hardLine(in: markerText, at: offset)
        guard hard.0 < hard.1, let sel = obj.element.attr("AXSelectedTextMarkerRange"), CFGetTypeID(sel) == AXTextMarkerRangeGetTypeID(),
              let (_, caret) = bridge.indices(of: sel as! AXTextMarkerRange), caret == offset,
              let v = obj.element.param("AXLineTextMarkerRangeForTextMarker", AXTextMarkerRangeCopyEndMarker(sel as! AXTextMarkerRange)),
              CFGetTypeID(v) == AXTextMarkerRangeGetTypeID(), let r = bridge.indices(of: v as! AXTextMarkerRange),
              r.0 >= hard.0, r.1 <= hard.1, r.0 <= offset, r.1 >= offset else { return hard }
        // The wrapped piece keeps its line's break, as the hard line does.
        return (r.0, r.1 + 1 == hard.1 ? hard.1 : r.1)
    }
}
