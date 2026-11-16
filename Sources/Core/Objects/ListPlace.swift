// SPDX-License-Identifier: GPL-3.0-or-later
// Where the selection last was in each list (Waypoint): when the selected item is moved or deleted from another
// window, the list comes back with nothing selected, and the user wants to stay in their place, not start at the top.
// Seen in Finder on macOS 27, 16 Nov 2026: a file copied in window A and moved into window B with Option-Command-V
// left A's list empty, and Down went to the first row.
import Foundation
import ApplicationServices
import TurnOverAX

/// A small store keyed by the list's accessibility element: SelectableList objects are made again on each focus,
/// so the place cannot live in one. All on the main actor. The newest lists only; a dead list is dropped.
public enum ListPlace {
    public struct Entry {
        public let list: AXUIElement
        public var row: AXUIElement?
        public var index: Int?
        /// The place is TurnOver's own walk, in a list that does not move its selection (Copilot's sessions).
        public var walked = false
        /// False while `index` is from an earlier row, or not yet read.
        var settled: Bool
    }

    static let limit = 20
    private static var entries: [Entry] = []
    private static var settle: DispatchWorkItem?

    public static func place(of list: AXUIElement) -> Entry? {
        entries.first { $0.list.isSame(list) }
    }

    /// The row the list's selection is on now. The row is known at once and costs no accessibility call; its place among
    /// the rows is read once the selection has been still for a moment, so a held arrow makes no extra calls (Finder
    /// serves them on its own main thread, and its selection froze while TurnOver read rows, 16 Nov 2026).
    public static func note(list: AXUIElement, row: AXUIElement, index: Int? = nil, walked: Bool = false) {
        if let i = entries.firstIndex(where: { $0.list.isSame(list) }) {
            var e = entries.remove(at: i)
            e.row = row
            if let index { e.index = index }
            e.settled = index != nil
            e.walked = walked
            entries.append(e)
        } else {
            entries.append(Entry(list: list, row: row, index: index, walked: walked, settled: index != nil))
            if entries.count > limit { entries.removeAll { $0.list.role == "?" } }
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
        }
        guard index == nil else { return }
        settle?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { resolveIndexes() } }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Reads the rows of each list whose row has no place yet, once.
    private static func resolveIndexes() {
        for n in entries.indices where !entries[n].settled {
            guard let row = entries[n].row else { continue }
            entries[n].settled = true
            let list = entries[n].list
            let rows = SelectableList.rowsAndKey(of: list, role: list.role, subrole: list.string(kAXSubroleAttribute)).0
            if let i = rows.firstIndex(where: { $0.isSame(row) }) { entries[n].index = i }
        }
    }

    /// The row to select when the list has nothing selected: the remembered row if it is still there, else the row now at the
    /// remembered place (the item that took the moved or deleted one's place), else the last. Nil when there is nothing to go to.
    public static func restoreIndex(remembered: Int?, found: Int?, rowCount: Int) -> Int? {
        guard rowCount > 0 else { return nil }
        if let found, found >= 0, found < rowCount { return found }
        guard let remembered, remembered >= 0 else { return nil }
        return min(remembered, rowCount - 1)
    }
}
