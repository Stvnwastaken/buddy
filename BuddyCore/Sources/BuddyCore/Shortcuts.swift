import Foundation

public enum ShortcutSlot: String, CaseIterable, Sendable {
    case talk, textBox

    public var title: String {
        switch self {
        case .talk: "Talk"
        case .textBox: "Text box"
        }
    }
}

public enum ShortcutModifier: Int, CaseIterable, Codable, Sendable {
    case control = 1, option = 2, shift = 4, command = 8, function = 16

    public var keys: ModifierKeys { ModifierKeys(rawValue: rawValue) }
    public var title: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .shift: "Shift"
        case .command: "Command"
        case .function: "fn"
        }
    }
}

public enum ShortcutTrigger: Equatable, Codable, Sendable {
    case held(ModifierKeys)
    case doubleTap(ShortcutModifier)

    var modifiers: ModifierKeys {
        switch self {
        case .held(let keys): keys
        case .doubleTap(let key): key.keys
        }
    }

    var isValid: Bool { !modifiers.isEmpty && modifiers.rawValue & ~31 == 0 }

    private enum CodingKeys: String, CodingKey { case kind, modifiers }
    private enum Kind: String, Codable { case held, doubleTap }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let keys = try values.decode(Int.self, forKey: .modifiers)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .held:
            self = .held(ModifierKeys(rawValue: keys))
        case .doubleTap:
            guard let modifier = ShortcutModifier(rawValue: keys) else {
                throw DecodingError.dataCorruptedError(forKey: .modifiers, in: values, debugDescription: "Expected one modifier.")
            }
            self = .doubleTap(modifier)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .held(let keys):
            try values.encode(Kind.held, forKey: .kind)
            try values.encode(keys.rawValue, forKey: .modifiers)
        case .doubleTap(let key):
            try values.encode(Kind.doubleTap, forKey: .kind)
            try values.encode(key.rawValue, forKey: .modifiers)
        }
    }

    public var instruction: String {
        switch self {
        case .held(let keys):
            "hold " + ShortcutModifier.allCases.filter { keys.contains($0.keys) }.map { $0.title.lowercased() }.joined(separator: " + ")
        case .doubleTap(let key):
            "double-tap \(key.title)"
        }
    }
}

public struct Shortcuts: Equatable, Codable, Sendable {
    private var talk = ShortcutTrigger.held([.control, .option])
    private var textBox = ShortcutTrigger.doubleTap(.control)

    public init() {}

    public subscript(_ slot: ShortcutSlot) -> ShortcutTrigger {
        switch slot {
        case .talk: talk
        case .textBox: textBox
        }
    }

    mutating func set(_ trigger: ShortcutTrigger, for slot: ShortcutSlot) {
        switch slot {
        case .talk: talk = trigger
        case .textBox: textBox = trigger
        }
    }

    func conflict(with trigger: ShortcutTrigger, for slot: ShortcutSlot) -> ShortcutSlot? {
        ShortcutSlot.allCases.first {
            guard $0 != slot else { return false }
            let other = self[$0]
            if case .held = trigger, case .held = other {
                return trigger.modifiers.isSubset(of: other.modifiers) || other.modifiers.isSubset(of: trigger.modifiers)
            }
            return other.modifiers == trigger.modifiers
        }
    }

    var isValid: Bool {
        ShortcutSlot.allCases.allSatisfy { self[$0].isValid && conflict(with: self[$0], for: $0) == nil }
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try! encoder.encode(self)
    }
}

struct ShortcutMatcher: Sendable {
    enum Match { case began(ShortcutSlot), ended(ShortcutSlot), tapped(ShortcutSlot), cancelled(ShortcutSlot) }
    private enum Hold { case ready, active(ShortcutSlot), waitingForRelease }
    private let shortcuts: Shortcuts
    private var hold = Hold.ready
    private(set) var modifiersHeld: ModifierKeys = []
    private var taps: [ShortcutSlot: DoubleTap] = [:]

    init(shortcuts: Shortcuts, modifiersHeld: ModifierKeys = []) {
        self.shortcuts = shortcuts
        self.modifiersHeld = modifiersHeld
        hold = modifiersHeld.isEmpty ? .ready : .waitingForRelease
        for slot in ShortcutSlot.allCases {
            if case .doubleTap(let key) = shortcuts[slot] { taps[slot] = DoubleTap(of: key.keys) }
        }
    }

    mutating func modifiersChanged(_ held: ModifierKeys, at time: Duration, otherInputHeld: Bool, tapsAllowed: Bool) -> [Match] {
        modifiersHeld = held
        if case .waitingForRelease = hold {
            for slot in ShortcutSlot.allCases {
                _ = taps[slot]?.modifiersChanged(held, at: time, otherInputHeld: true)
            }
            if held.isEmpty { hold = .ready }
            return []
        }
        var matches: [Match] = []
        for slot in ShortcutSlot.allCases {
            if taps[slot]?.modifiersChanged(held, at: time, otherInputHeld: otherInputHeld || !tapsAllowed) == true {
                matches.append(.tapped(slot))
            }
        }
        switch hold {
        case .ready:
            if !otherInputHeld, let slot = ShortcutSlot.allCases.first(where: { shortcuts[$0] == .held(held) }) {
                hold = .active(slot)
                matches.append(.began(slot))
            }
        case .active(let slot):
            let combo = shortcuts[slot].modifiers
            if otherInputHeld || !held.isSubset(of: combo) {
                hold = held.isEmpty ? .ready : .waitingForRelease
                matches.append(.cancelled(slot))
            } else if held != combo {
                hold = held.isEmpty ? .ready : .waitingForRelease
                matches.append(.ended(slot))
            }
        case .waitingForRelease:
            break
        }
        return matches
    }

    mutating func keyOrButtonPressed() -> Bool {
        for slot in ShortcutSlot.allCases { taps[slot]?.keyOrButtonPressed() }
        guard case .active(let slot) = hold else { return false }
        hold = modifiersHeld.isEmpty ? .ready : .waitingForRelease
        return slot == .talk
    }

    mutating func cancel() {
        self = ShortcutMatcher(shortcuts: shortcuts, modifiersHeld: modifiersHeld)
    }
}
