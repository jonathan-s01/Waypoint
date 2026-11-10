// SPDX-License-Identifier: GPL-3.0-or-later
// Focus memory kept across restarts: what the file holds, what is pruned, the round trip. All pure; the saving at a
// quit and the restoring after a restart need a running app and are tried by ear (FocusMemoryStore.swift).
import Foundation
import TurnOverCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func fp(_ text: String, window: String = "inbox") -> FocusFingerprint {
    FocusFingerprint(windowTitle: window, nodes: [FocusNode(role: "AXScrollArea"), FocusNode(role: "AXRow", id: "r1", text: text, index: 4)])
}

func focusStoreTests() {
    test("focus store: an element place comes back from the file as the same fingerprint") {
        var file = FocusStoreFile()
        file.apps["com.apple.mail"] = ["inbox": FocusStoreLogic.stored(fp("Lunch on Friday"), at: now)]
        guard let data = FocusStoreLogic.encode(file), let back = FocusStoreLogic.decode(data) else { return check(false, "round trip") }
        expect(back, file, "the same file")
        expect(FocusStoreLogic.fingerprint(back.apps["com.apple.mail"]!["inbox"]!), fp("Lunch on Friday"))
    }
    test("focus store: a document place keeps its position and words, and is no fingerprint") {
        let p = StoredPlace(kind: "document", offset: 120, line: "See you at noon", newest: "Thanks", at: now)
        var file = FocusStoreFile()
        file.regions["com.microsoft.teams2|messages"] = p
        guard let data = FocusStoreLogic.encode(file), let back = FocusStoreLogic.decode(data) else { return check(false, "round trip") }
        expect(back.regions["com.microsoft.teams2|messages"], p)
        check(FocusStoreLogic.fingerprint(p) == nil, "a document place is not an element")
    }
    test("focus store: a place with no words and no identifier could never be found, so it is not offered") {
        let empty = FocusFingerprint(windowTitle: "w", nodes: [FocusNode(role: "AXGroup")])
        check(FocusStoreLogic.fingerprint(FocusStoreLogic.stored(empty, at: now)) == nil, "nothing to find it by")
    }
    test("focus store: entries older than a week are dropped, and an app with none left goes") {
        var file = FocusStoreFile()
        file.apps["old.app"] = ["w": FocusStoreLogic.stored(fp("a"), at: now.addingTimeInterval(-8 * 24 * 3600))]
        file.apps["new.app"] = ["w": FocusStoreLogic.stored(fp("b"), at: now.addingTimeInterval(-3600))]
        file.regions["old.app|list"] = FocusStoreLogic.stored(fp("a"), at: now.addingTimeInterval(-9 * 24 * 3600))
        file.regions["new.app|list"] = FocusStoreLogic.stored(fp("b"), at: now.addingTimeInterval(-60))
        let kept = FocusStoreLogic.pruned(file, now: now)
        check(kept.apps["old.app"] == nil, "old app gone")
        check(kept.apps["new.app"] != nil, "recent app kept")
        check(kept.regions["old.app|list"] == nil && kept.regions["new.app|list"] != nil, "regions by age")
    }
    test("focus store: an app keeps its newest windows only") {
        var file = FocusStoreFile()
        for i in 0..<12 { file.apps["a"]?["w\(i)"] = nil; file.apps["a", default: [:]]["w\(i)"] = FocusStoreLogic.stored(fp("t\(i)", window: "w\(i)"), at: now.addingTimeInterval(Double(-i * 60))) }
        let kept = FocusStoreLogic.pruned(file, now: now).apps["a"] ?? [:]
        expect(kept.count, FocusStoreLogic.maxWindowsPerApp)
        check(kept["w0"] != nil && kept["w11"] == nil, "the newest stay, the oldest go")
    }
    test("focus store: a file of another version or not a file at all is not read") {
        check(FocusStoreLogic.decode(Data("nonsense".utf8)) == nil, "garbage")
        let v2 = Data(#"{"version":2,"apps":{},"regions":{}}"#.utf8)
        check(FocusStoreLogic.decode(v2) == nil, "another version")
    }
    test("focus store: the region key is the bundle and the part") {
        expect(FocusStoreLogic.regionKey(bundle: "com.microsoft.teams2", part: "messages"), "com.microsoft.teams2|messages")
    }
}
