// Unicode Utilities (CarbonCore): UCKeyTranslate over the US ANSI layout,
// as shortcut recorders use it to name keys (Carbon's input sources report
// the US layout too).

import Foundation
import RunwayFoundation

public typealias OptionBits = UInt32

public struct UCKeyboardLayout {
    public var keyboardLayoutHeaderFormat: UInt16 = 0x1002
    public var keyboardLayoutDataVersion: UInt16 = 0
    public init() {}
}

public enum _USKeyboardLayout {
    /// kVK code → (unshifted, shifted) characters on a US ANSI keyboard.
    public static let characters: [Int: (String, String)] = [
        0x00: ("a", "A"), 0x01: ("s", "S"), 0x02: ("d", "D"), 0x03: ("f", "F"), 0x04: ("h", "H"), 0x05: ("g", "G"),
        0x06: ("z", "Z"), 0x07: ("x", "X"), 0x08: ("c", "C"), 0x09: ("v", "V"), 0x0A: ("§", "±"), 0x0B: ("b", "B"),
        0x0C: ("q", "Q"), 0x0D: ("w", "W"), 0x0E: ("e", "E"), 0x0F: ("r", "R"), 0x10: ("y", "Y"), 0x11: ("t", "T"),
        0x12: ("1", "!"), 0x13: ("2", "@"), 0x14: ("3", "#"), 0x15: ("4", "$"), 0x16: ("6", "^"), 0x17: ("5", "%"),
        0x18: ("=", "+"), 0x19: ("9", "("), 0x1A: ("7", "&"), 0x1B: ("-", "_"), 0x1C: ("8", "*"), 0x1D: ("0", ")"),
        0x1E: ("]", "}"), 0x1F: ("o", "O"), 0x20: ("u", "U"), 0x21: ("[", "{"), 0x22: ("i", "I"), 0x23: ("p", "P"),
        0x24: ("\r", "\r"), 0x25: ("l", "L"), 0x26: ("j", "J"), 0x27: ("'", "\""), 0x28: ("k", "K"), 0x29: (";", ":"),
        0x2A: ("\\", "|"), 0x2B: (",", "<"), 0x2C: ("/", "?"), 0x2D: ("n", "N"), 0x2E: ("m", "M"), 0x2F: (".", ">"),
        0x30: ("\t", "\t"), 0x31: (" ", " "), 0x32: ("`", "~"), 0x33: ("\u{8}", "\u{8}"), 0x35: ("\u{1b}", "\u{1b}"),
        0x41: (".", "."), 0x43: ("*", "*"), 0x45: ("+", "+"), 0x4B: ("/", "/"), 0x4C: ("\u{3}", "\u{3}"), 0x4E: ("-", "-"),
        0x51: ("=", "="), 0x52: ("0", "0"), 0x53: ("1", "1"), 0x54: ("2", "2"), 0x55: ("3", "3"), 0x56: ("4", "4"),
        0x57: ("5", "5"), 0x58: ("6", "6"), 0x59: ("7", "7"), 0x5B: ("8", "8"), 0x5C: ("9", "9"),
    ]
}

public var kUCKeyActionDown: Int { 0 }
public var kUCKeyActionUp: Int { 1 }
public var kUCKeyActionAutoKey: Int { 2 }
public var kUCKeyActionDisplay: Int { 3 }
public var kUCKeyTranslateNoDeadKeysBit: Int { 0 }
public var kUCKeyTranslateNoDeadKeysMask: Int { 1 }

/// The characters a key produces on the US layout. `modifierKeyState` is
/// Carbon's modifiers shifted right by 8 (shift = 0x02, caps lock = 0x04).
public func UCKeyTranslate(_ keyLayoutPtr: UnsafePointer<UCKeyboardLayout>!, _ virtualKeyCode: UInt16, _ keyAction: UInt16,
                           _ modifierKeyState: UInt32, _ keyboardType: UInt32, _ keyTranslateOptions: OptionBits,
                           _ deadKeyState: UnsafeMutablePointer<UInt32>!, _ maxStringLength: Int,
                           _ actualStringLength: UnsafeMutablePointer<Int>!, _ unicodeString: UnsafeMutablePointer<UniChar>!) -> OSStatus {
    deadKeyState?.pointee = 0
    guard let pair = _USKeyboardLayout.characters[Int(virtualKeyCode)] else { actualStringLength?.pointee = 0; return noErr }
    let shifted = modifierKeyState & 0x02 != 0
    var s = shifted ? pair.1 : pair.0
    if modifierKeyState & 0x04 != 0, s.count == 1, s.first!.isLetter { s = s.uppercased() }
    let units = Array(s.utf16)
    let n = Swift.min(units.count, maxStringLength)
    if let unicodeString { for i in 0..<n { unicodeString[i] = units[i] } }
    actualStringLength?.pointee = n
    return noErr
}
