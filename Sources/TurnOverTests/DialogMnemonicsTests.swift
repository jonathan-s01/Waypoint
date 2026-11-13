// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import TurnOverCore

func dialogMnemonicsTests() {
    func str(_ l: [Character?]) -> String { l.map { $0.map(String.init) ?? "-" }.joined() }
    test("dialog letters: each button takes its first letter") {
        check(str(DialogMnemonics.letters(for: ["Save", "Cancel", "Open"])) == "sco", "Save, Cancel, Open")
    }
    test("dialog letters: a clash goes to the first button, the other takes a later free letter") {
        check(str(DialogMnemonics.letters(for: ["Save", "Don't Save"])) == "sd", "Save, Don't Save")
        check(str(DialogMnemonics.letters(for: ["Cancel", "Continue"])) == "co", "Cancel, Continue")
        check(str(DialogMnemonics.letters(for: ["Copy", "Cut"])) == "cu", "Copy, Cut")
    }
    test("dialog letters: the default button and Cancel are served first") {
        check(str(DialogMnemonics.letters(for: ["Continue", "Cancel"], priority: [1])) == "oc", "Cancel keeps C")
        check(str(DialogMnemonics.letters(for: ["Close", "Continue"], priority: [1])) == "lc", "the default Continue keeps C")
    }
    test("dialog letters: no free letter gives nil, accents fold, non-letters are skipped") {
        check(DialogMnemonics.letters(for: ["A", "A"]) == ["a", nil], "one letter, two buttons")
        check(DialogMnemonics.letters(for: ["Écrire"])[0] == "e", "accent folded")
        check(DialogMnemonics.letters(for: ["…", "OK"]) == [nil, "o"], "no letters")
    }
    test("dialog letters: a letter finds its button") {
        let l = DialogMnemonics.letters(for: ["Save", "Don't Save", "Cancel"])
        check(DialogMnemonics.index(of: "d", in: l) == 1, "D")
        check(DialogMnemonics.index(of: "z", in: l) == nil, "Z")
    }
    test("dialog letters: only Left Option held with a letter counts") {
        func g(_ code: Int64, _ raw: UInt64, mods: Modifiers = .option, rep: Bool = false) -> KeyboardGesture {
            KeyboardGesture(keyCode: code, modifiers: mods, characters: "", timestamp: 0, isRepeat: rep, flags: CGEventFlags(rawValue: raw | CGEventFlags.maskAlternate.rawValue))
        }
        check(DialogMnemonics.isLeftOptionLetter(g(1, 0x20)), "left option S")
        check(!DialogMnemonics.isLeftOptionLetter(g(1, 0x40)), "right option")
        check(!DialogMnemonics.isLeftOptionLetter(g(1, 0x60)), "both options")
        check(!DialogMnemonics.isLeftOptionLetter(g(1, 0x20, mods: [.option, .shift])), "with shift")
        check(!DialogMnemonics.isLeftOptionLetter(g(1, 0x20, rep: true)), "a repeat")
        check(!DialogMnemonics.isLeftOptionLetter(g(48, 0x20)), "tab")
    }
}
