/// The modifier keys held down at one moment. Caps Lock is a toggle, not a held key, so it is not one of them.
public struct ModifierKeys: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = ModifierKeys(rawValue: 1 << 0)
    public static let option = ModifierKeys(rawValue: 1 << 1)
    public static let shift = ModifierKeys(rawValue: 1 << 2)
    public static let command = ModifierKeys(rawValue: 1 << 3)
    public static let function = ModifierKeys(rawValue: 1 << 4)
}

/// Recognizes two quick taps of one modifier key pressed on its own.
///
/// A tap starts with nothing held, holds only `key`, and lets go within `window`. The second tap must start within
/// `window` of the first one ending, and the double-tap is recognized as it ends. Another modifier, key or mouse button
/// already held, or pressed during or between the taps, spoils them.
struct DoubleTap: Sendable {
    static let window = Duration.milliseconds(400)

    private enum Phase: Sendable {
        /// Nothing is held. `lastTap` is when the previous tap ended, if one did and nothing spoiled it since.
        case ready(lastTap: Duration?)
        case pressed(since: Duration, lastTap: Duration?)
        /// Something other than a lone tap of the key is happening, so nothing counts until every modifier is up.
        case spoiled
    }

    let key: ModifierKeys
    private var phase = Phase.ready(lastTap: nil)

    init(of key: ModifierKeys) {
        self.key = key
    }

    /// Takes the modifiers now held, and answers whether that finished a double-tap.
    mutating func modifiersChanged(_ held: ModifierKeys, at time: Duration, otherInputHeld: Bool) -> Bool {
        guard !otherInputHeld else {
            phase = held.isEmpty ? .ready(lastTap: nil) : .spoiled
            return false
        }
        switch (phase, held) {
        case (.ready(let lastTap), key):
            phase = .pressed(since: time, lastTap: lastTap)
        case (.pressed(let since, let lastTap), []):
            let isTap = time - since <= Self.window
            let isDouble = isTap && lastTap.map { since - $0 <= Self.window } == true
            phase = .ready(lastTap: isTap && !isDouble ? time : nil)
            return isDouble
        case (.spoiled, []):
            phase = .ready(lastTap: nil)
        case (.ready, []), (.pressed, key), (.spoiled, _):
            break
        case (.ready, _), (.pressed, _):
            phase = .spoiled
        }
        return false
    }

    mutating func keyOrButtonPressed() {
        switch phase {
        case .ready: phase = .ready(lastTap: nil)
        case .pressed: phase = .spoiled
        case .spoiled: break
        }
    }
}
