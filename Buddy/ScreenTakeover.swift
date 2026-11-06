import AppKit
import BuddyCore
import Carbon.HIToolbox

/// The mouse and keyboard during a screen takeover. While it is on, an event tap drops the owner's keys, clicks, drags,
/// moves and scrolls, except Esc. Modifier changes pass, so push-to-talk still works, and so do the events Buddy posts
/// for the run, which carry `PasteInserter.postedEventMarker`. Actions run one after another.
final class ScreenTakeover {
    static let ended = "The takeover ended before Buddy could do this."
    static let secureInput = "Secure input is on, as in a password field, so Buddy typed nothing."

    /// Media, brightness and Mission Control keys, then trackpad gestures, which `CGEventType` doesn't name: rotate,
    /// begin and end gesture, gesture, magnify, swipe and smart magnify (`NSEvent.EventType` 18 to 20 and 29 to 32).
    /// Without them the owner could switch Spaces under the run.
    private static let systemAndGestureTypes: [UInt32] = [14, 18, 19, 20, 29, 30, 31, 32]

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var queue: Task<Void, Never>?
    /// Changes when the takeover ends, so actions still queued or typing stop.
    private var generation = 0

    /// Starts blocking the owner's input. False when macOS wouldn't make the event tap.
    func begin() -> Bool {
        guard tap == nil else { return true }
        let named: [CGEventType] = [
            .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseMoved, .scrollWheel
        ]
        let blocked = named.map(\.rawValue) + Self.systemAndGestureTypes
        let mask = blocked.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            return Unmanaged<ScreenTakeover>.fromOpaque(userInfo).takeUnretainedValue().filter(type, event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Gives the owner their input back. Actions that haven't finished report that the takeover ended.
    func end() {
        generation += 1
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
            self.tapSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
    }

    /// Performs the action once the ones before it are done, then calls `done` with nil or why it failed.
    func perform(_ action: ScreenAction<DisplayPoint>, done: @escaping (String?) -> Void) {
        let previous = queue
        let requested = generation
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return done(ScreenTakeover.ended) }
            done(await run(action, requested: requested))
        }
    }

    private func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == PasteInserter.postedEventMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private var isOn: Bool { tap != nil }

    private func run(_ action: ScreenAction<DisplayPoint>, requested: Int) async -> String? {
        guard isOn, generation == requested else { return Self.ended }
        let source = CGEventSource(stateID: .hidSystemState)
        switch action {
        case .click(let spot, let button, let count):
            post(mouse(.mouseMoved, at: spot, button: .left, source: source))
            // Apps track hover before a press, and some ignore a press that lands with no move first.
            try? await Task.sleep(for: .milliseconds(30))
            guard generation == requested else { return Self.ended }
            let (down, up): (CGEventType, CGEventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
            let quartzButton: CGMouseButton = button == .left ? .left : .right
            for click in 1...max(1, count) {
                for type in [down, up] {
                    let event = mouse(type, at: spot, button: quartzButton, source: source)
                    event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                    post(event)
                }
            }
        case .move(let spot):
            post(mouse(.mouseMoved, at: spot, button: .left, source: source))
        case .scroll(let spot, let down, let right):
            post(mouse(.mouseMoved, at: spot, button: .left, source: source))
            try? await Task.sleep(for: .milliseconds(30))
            guard generation == requested else { return Self.ended }
            let event = CGEvent(
                scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                wheel1: Int32(clamping: -down), wheel2: Int32(clamping: -right), wheel3: 0
            )
            event?.flags = []
            post(event)
        case .type(let text):
            return await type(text, requested: requested, source: source)
        case .key(let press):
            self.press(CGKeyCode(press.keyCode), flags: CGEventFlags(press.modifiers), source: source)
        }
        return nil
    }

    private func type(_ text: String, requested: Int, source: CGEventSource?) async -> String? {
        for chunk in Self.chunks(of: text) {
            guard generation == requested else { return Self.ended }
            guard !IsSecureEventInputEnabled() else { return Self.secureInput }
            if let chunk {
                for keyDown in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                    event?.flags = []
                    event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    post(event)
                }
            } else {
                press(CGKeyCode(kVK_Return), flags: [], source: source)
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return nil
    }

    /// The text as runs of UTF-16 short enough for one keyboard event, never splitting a character, with nil for each
    /// new line.
    private static func chunks(of text: String) -> [[UniChar]?] {
        var chunks: [[UniChar]?] = []
        var current: [UniChar] = []
        for character in text {
            if character.isNewline {
                if !current.isEmpty { chunks.append(current) }
                current = []
                chunks.append(nil)
                continue
            }
            let units = Array(String(character).utf16)
            if current.count + units.count > 20, !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func press(_ key: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
            event?.flags = flags
            post(event)
        }
    }

    private func mouse(_ type: CGEventType, at spot: DisplayPoint, button: CGMouseButton, source: CGEventSource?) -> CGEvent? {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: spot.quartz, mouseButton: button)
        // The owner may still hold a modifier, which would turn a click into a Command-click.
        event?.flags = []
        return event
    }

    private func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: PasteInserter.postedEventMarker)
        event?.post(tap: .cghidEventTap)
    }
}

private extension CGEventFlags {
    init(_ modifiers: ModifierKeys) {
        let flags: [(ModifierKeys, CGEventFlags)] = [
            (.control, .maskControl), (.option, .maskAlternate), (.shift, .maskShift),
            (.command, .maskCommand), (.function, .maskSecondaryFn)
        ]
        self = flags.reduce(into: []) { result, pair in
            if modifiers.contains(pair.0) { result.insert(pair.1) }
        }
    }
}
