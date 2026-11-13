// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func waypointPauseTests() {
    let slash = WaypointPause.slashKeyCode
    let rightOption: UInt64 = 0x40, rightShift: UInt64 = 0x04
    test("waypoint off/on: Right Option + Right Shift + slash is the chord") {
        check(WaypointPause.isChord(keyCode: slash, rawFlags: rightOption | rightShift), "the two right-hand keys with slash")
        check(WaypointPause.isChord(keyCode: slash, rawFlags: rightOption | rightShift | 0x00800000), "Fn held as well does not matter")
        check(WaypointPause.isChord(keyCode: slash, rawFlags: rightOption | rightShift | 0x00010000), "Caps Lock on does not matter")
    }
    test("waypoint off/on: the left-hand keys, other modifiers and other keys are not the chord") {
        check(!WaypointPause.isChord(keyCode: slash, rawFlags: 0x20 | 0x02), "Left Option + Left Shift")
        check(!WaypointPause.isChord(keyCode: slash, rawFlags: 0x20 | rightShift), "Left Option + Right Shift")
        check(!WaypointPause.isChord(keyCode: slash, rawFlags: rightOption | 0x02), "Right Option + Left Shift")
        check(!WaypointPause.isChord(keyCode: slash, rawFlags: rightOption), "Right Option alone")
        check(!WaypointPause.isChord(keyCode: slash, rawFlags: rightOption | rightShift | 0x08), "with Left Command")
        check(!WaypointPause.isChord(keyCode: slash, rawFlags: rightOption | rightShift | 0x2000), "with Right Control")
        check(!WaypointPause.isChord(keyCode: 43, rawFlags: rightOption | rightShift), "comma")
    }
    test("waypoint off/on: the state is remembered and can be cleared") {
        let before = WaypointPause.isPaused
        defer { WaypointPause.set(before) }
        WaypointPause.set(true)
        check(WaypointPause.isPaused, "off")
        check(UserDefaults.standard.bool(forKey: WaypointPause.defaultsKey), "saved for the next start")
        WaypointPause.set(false)
        check(!WaypointPause.isPaused, "on")
        check(!UserDefaults.standard.bool(forKey: WaypointPause.defaultsKey), "saved as on")
    }
}
