import Foundation

public enum MouseButton: Equatable, Sendable { case left, right }

/// A spot in the run's latest screenshot: pixels from its top-left, on screen N (1-based) or, without one, the
/// cursor's screen.
public struct ScreenSpot: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let screen: Int?

    public init(x: Int, y: Int, screen: Int?) {
        self.x = x
        self.y = y
        self.screen = screen
    }
}

/// One key with the modifiers held for it, as a macOS virtual key code.
public struct KeyPress: Equatable, Sendable {
    public let modifiers: ModifierKeys
    public let keyCode: UInt16

    public init(modifiers: ModifierKeys, keyCode: UInt16) {
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    /// Parses names like "return", "cmd+s", "Shift+Tab" or "cmd+shift+]". Nil for an unknown name, or for anything but
    /// exactly one key that isn't a modifier.
    public init?(parsing keys: String) {
        var modifiers: ModifierKeys = []
        var keyCode: UInt16?
        for part in keys.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            let name = part.trimmingCharacters(in: .whitespaces)
            if let modifier = Self.modifierNames[name] {
                modifiers.insert(modifier)
            } else if let code = Self.keyCodes[name], keyCode == nil {
                keyCode = code
            } else {
                return nil
            }
        }
        guard let keyCode else { return nil }
        self.init(modifiers: modifiers, keyCode: keyCode)
    }

    private static let modifierNames: [String: ModifierKeys] = [
        "cmd": .command, "command": .command, "shift": .shift, "option": .option, "opt": .option, "alt": .option,
        "ctrl": .control, "control": .control, "fn": .function
    ]

    /// The keys a run can press by name, with their ANSI virtual key codes from Carbon's `kVK_` constants.
    public static let keyCodes: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22,
        "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "=": 0x18, "-": 0x1B, "]": 0x1E, "[": 0x21, "'": 0x27, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, ".": 0x2F,
        "`": 0x32,
        "return": 0x24, "enter": 0x4C, "tab": 0x30, "space": 0x31, "delete": 0x33, "forwarddelete": 0x75,
        "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E, "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64, "f9": 0x65,
        "f10": 0x6D, "f11": 0x67, "f12": 0x6F
    ]
}

/// What a run does with the mouse and keyboard during a takeover, at spots of type `Spot`.
public enum ScreenAction<Spot: Equatable & Sendable>: Equatable, Sendable {
    case click(Spot, button: MouseButton, count: Int)
    case move(Spot)
    /// Lines to scroll. Negative scrolls up or left.
    case scroll(Spot, down: Int, right: Int)
    case type(String)
    case key(KeyPress)

    func map<T, E: Error>(_ transform: (Spot) throws(E) -> T) throws(E) -> ScreenAction<T> {
        switch self {
        case .click(let spot, let button, let count): .click(try transform(spot), button: button, count: count)
        case .move(let spot): .move(try transform(spot))
        case .scroll(let spot, let down, let right): .scroll(try transform(spot), down: down, right: right)
        case .type(let text): .type(text)
        case .key(let press): .key(press)
        }
    }
}

/// Why a takeover tool call can't go ahead, as the run is told.
struct TakeoverRefusal: Error, Equatable {
    let message: String
}

extension [ScreenCapture] {
    /// Where a spot in these screenshots is on the displays. Unlike a tag's screen, an explicit screen number must
    /// exist, because a click on the wrong display could do anything.
    func displayPoint(for spot: ScreenSpot) throws(TakeoverRefusal) -> DisplayPoint {
        guard !isEmpty else { throw TakeoverRefusal(message: "Take a screenshot with capture_screen first.") }
        let index: Int
        if let screen = spot.screen {
            guard indices.contains(screen - 1) else {
                throw TakeoverRefusal(message: "Your latest screenshot has no screen \(screen).")
            }
            index = screen - 1
        } else {
            index = firstIndex(where: \.containsCursor) ?? 0
        }
        let capture = self[index]
        guard (0..<capture.pixelWidth).contains(spot.x), (0..<capture.pixelHeight).contains(spot.y) else {
            throw TakeoverRefusal(message: "(\(spot.x), \(spot.y)) is outside screen \(index + 1), which is "
                + "\(capture.pixelWidth)x\(capture.pixelHeight) pixels.")
        }
        return capture.displayPoint(PixelPoint(x: Double(spot.x), y: Double(spot.y)))
    }
}
