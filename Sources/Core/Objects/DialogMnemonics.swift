// SPDX-License-Identifier: GPL-3.0-or-later
// Waypoint: Windows-style button letters in dialogs and sheets. Left Option with a letter presses the button that
// letter belongs to, as Alt with the underlined letter does on Windows. The Mac draws no underlines, so the letters
// come from the buttons' names (DialogMnemonics.letters), the same way each time, and are spoken as Tab reaches a
// button and in the dialog's description. Right Option is left alone: it is the Commander, and types accents.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

nonisolated public enum DialogMnemonics {
    /// NX_DEVICELALTKEYMASK and NX_DEVICERALTKEYMASK: which Option key is down.
    private static let leftOptionBit: UInt64 = 0x20
    private static let rightOptionBit: UInt64 = 0x40
    private static let cancelNames: Set<String> = ["cancel", "not now", "close", "no", "don’t allow", "don't allow", "later"]

    /// The key is Left Option held with nothing else.
    public static func isLeftOptionLetter(_ g: KeyboardGesture) -> Bool {
        guard g.modifiers == [.option], !g.isRepeat else { return false }
        let raw = g.flags.rawValue
        return raw & leftOptionBit != 0 && raw & rightOptionBit == 0 && letter(forKeyName: g.keyName) != nil
    }

    public static func letter(forKeyName name: String) -> Character? {
        guard name.count == 1, let c = name.lowercased().first, c >= "a", c <= "z" else { return nil }
        return c
    }

    private static func fold(_ s: String) -> [Character] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0 >= "a" && $0 <= "z" }.map { $0 }
    }

    /// One letter for each name, or nil where none is left. A name takes its first letter if nobody has it, and the
    /// buttons in `priority` (the default button, then Cancel) are served before the rest, in reading order. A name
    /// that lost its first letter takes the first letter of a later word, then any free letter in it.
    public static func letters(for names: [String], priority: [Int] = []) -> [Character?] {
        var out = [Character?](repeating: nil, count: names.count)
        var used = Set<Character>()
        let order = (priority + names.indices).reduce(into: [Int]()) { if names.indices.contains($1), !$0.contains($1) { $0.append($1) } }
        for i in order {
            if let first = fold(names[i]).first, !used.contains(first) { out[i] = first; used.insert(first) }
        }
        for i in order where out[i] == nil {
            let words = names[i].split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let candidates = words.dropFirst().compactMap { fold($0).first } + fold(names[i])
            if let c = candidates.first(where: { !used.contains($0) }) { out[i] = c; used.insert(c) }
        }
        return out
    }

    /// Index of the name that owns a letter.
    public static func index(of letter: Character, in letters: [Character?]) -> Int? { letters.firstIndex { $0 == letter } }
}

extension Dialog {
    /// What a letter can press: the buttons and the other controls that take a press; edit fields are not among them.
    private var pressables: [(AXUIElement, String)] {
        choices.filter { !["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains($0.0.role) }
    }

    /// The pressables with their letters, in the dialog's order.
    var letteredChoices: [(element: AXUIElement, name: String, letter: Character?)] {
        let list = pressables
        let defaultButton = element.element("AXDefaultButton") ?? element.element(kAXWindowAttribute)?.element("AXDefaultButton")
        var priority: [Int] = []
        if let d = defaultButton, let i = list.firstIndex(where: { $0.0.isSame(d) }) { priority.append(i) }
        if let i = list.firstIndex(where: { ["cancel"].contains($0.1.lowercased()) }) { priority.append(i) }
        let letters = DialogMnemonics.letters(for: list.map(\.1), priority: priority)
        return list.indices.map { (list[$0].0, list[$0].1, letters[$0]) }
    }

    /// What is added when a button is spoken: "Option S", or nothing when letters are off or the button has none.
    func letterHint(for e: AXUIElement) -> String? {
        guard config.keyboard.dialogLetterHints, let c = letteredChoices.first(where: { $0.element.isSame(e) }), let l = c.letter else { return nil }
        return String(localized: "Option \(String(l).uppercased())", comment: "The key that presses a dialog's button: its letter, with Left Option")
    }

    /// "Save, Option S; Don't Save, Option D": the choices with their letters, for the dialog's description.
    var choicesWithLetters: [String] {
        guard config.keyboard.dialogLetterHints else { return choices.map(\.1) }
        let lettered = letteredChoices
        return choices.map { c in
            guard let l = lettered.first(where: { $0.element.isSame(c.0) })?.letter else { return c.1 }
            return String(localized: "\(c.1), Option \(String(l).uppercased())", comment: "A dialog's choice with the key that presses it: name, then Left Option and its letter")
        }
    }

    /// The nearest dialog or sheet round the focus.
    static var nearest: Dialog? {
        if let d = API.focusObject as? Dialog { return d }
        return API.focusAncestors.lazy.compactMap { $0 as? Dialog }.first
    }

    /// Left Option and a letter (main thread): presses the button that letter belongs to. False: not ours, the key
    /// goes on to the application (Left Option and a letter types its character there).
    static func pressButton(forLetterOf g: KeyboardGesture) -> Bool {
        guard DialogMnemonics.isLeftOptionLetter(g), let letter = DialogMnemonics.letter(forKeyName: g.keyName),
              let dialog = nearest, !SystemPrompts.isProtected(dialog.element.pid) else { return false }
        let all = dialog.letteredChoices
        guard let hit = all.first(where: { $0.letter == letter }) else { return false }
        if dialog.press(hit.element) {
            Log.io("dialog: pressed \(Log.words(hit.name)) by its letter")
            SystemPrompts.checkPress(of: hit.element, name: hit.name)
        } else {
            Speech.speakMessage(String(localized: "\(hit.name) cannot be pressed", comment: "A dialog's choice could not be pressed: its name"))
        }
        return true
    }
}
