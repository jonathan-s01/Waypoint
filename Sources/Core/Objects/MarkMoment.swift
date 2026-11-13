// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint's "that was wrong" mark: one key that stamps the log with where the reader was at that moment, so a feeling
// of "it did not keep up" or "it did not read" can be matched with what the reader was doing. The line holds the app,
// the role of the focused item, and the age and length of the last few things said; never a word of what was said.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

final class MarkMomentPlugin: GlobalPlugin {
    required init() {
        super.init()
        script("markMoment", String(localized: "Marks this moment in the log, for a report that something just sounded wrong (VO-Command-Equals)", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:turnover+command+="], category: "Waypoint") { _ in
            Log.info(Self.line())
            TypingRecorder.mark()
            Speech.speakMessage(String(localized: "marked", comment: "Spoken message: the moment was marked in the log"))
        }
    }

    private static func line() -> String {
        let focus = API.focusObject
        let app = focus.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier } ?? "no app"
        let role = focus?.element.role ?? "no focus"
        let now = Date()
        let recent = Speech.history.value.suffix(5).map { "\(Int(now.timeIntervalSince($0.at) * 1000)) ms ago, \($0.text.count) characters" }
        return "MARK: wrong moment in \(app), focus \(role); last said: \(recent.isEmpty ? "nothing" : recent.joined(separator: "; "))"
    }
}
