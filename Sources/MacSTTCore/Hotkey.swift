import Foundation

/// A global shortcut such as `ctrl+opt+d`. Modifier bits are Carbon's (cmdKey, shiftKey, optionKey, controlKey).
public struct Hotkey: Equatable, Sendable {
    public static let defaultSpec = "ctrl+opt+d"
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let spec: String

    public enum ParseError: Error, LocalizedError, Equatable {
        case invalid(String)
        public var errorDescription: String? {
            switch self {
            case .invalid(let s):
                "invalid hotkey \(s); use modifiers (ctrl, opt, cmd, shift) plus one key, e.g. ctrl+opt+d, cmd+shift+space, ctrl+f5"
            }
        }
    }

    private static let modifierBits: [String: UInt32] = [
        "cmd": 256, "command": 256, "shift": 512, "opt": 2048, "option": 2048, "alt": 2048,
        "ctrl": 4096, "control": 4096,
    ]

    private static let keyCodes: [String: UInt32] = {
        var table: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
            "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
            "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "space": 49, "return": 36, "tab": 48,
        ]
        let f: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in f.enumerated() { table["f\(i + 1)"] = code }
        return table
    }()

    public init(_ spec: String) throws {
        let parts = spec.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let key = Self.keyCodes[parts.last!] else { throw ParseError.invalid(spec) }
        var bits: UInt32 = 0
        for name in parts.dropLast() {
            guard let bit = Self.modifierBits[name] else { throw ParseError.invalid(spec) }
            bits |= bit
        }
        // A bare shift is not a shortcut; F-keys may stand alone only with another modifier too (kept simple).
        guard bits != 0, bits != 512 else { throw ParseError.invalid(spec) }
        keyCode = key
        modifiers = bits
        self.spec = spec
    }
}
