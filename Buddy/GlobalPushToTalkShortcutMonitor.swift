import AppKit
import BuddyCore
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation

/// Forwards physical input to the engine. Events Buddy posts itself are ignored.
final class GlobalPushToTalkShortcutMonitor {
    let eventPublisher = PassthroughSubject<BuddyEngine.Event, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    deinit {
        stop()
    }

    func start() {
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Buddy's own clicks and keys, posted while typing for the owner.
        if event.getIntegerValueField(.eventSourceUserData) == PasteInserter.postedEventMarker {
            return Unmanaged.passUnretained(event)
        }

        switch eventType {
        case .flagsChanged:
            eventPublisher.send(.modifiersChanged(
                ModifierKeys(event.flags), at: .nanoseconds(Int64(event.timestamp)),
                otherInputHeld: otherInputHeld, tapsAllowed: !IsSecureEventInputEnabled()
            ))
        case .leftMouseDown:
            eventPublisher.send(.clicked(DisplayPoint(quartz: event.location)))
        case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == 53:
            eventPublisher.send(.interrupted)
        case .keyDown, .rightMouseDown, .otherMouseDown:
            eventPublisher.send(.keyOrButtonPressed)
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private var otherInputHeld: Bool {
        Self.nonModifierKeyCodes.contains { CGEventSource.keyState(.combinedSessionState, key: $0) }
            || NSEvent.pressedMouseButtons != 0
    }

    private static let nonModifierKeyCodes: [CGKeyCode] = {
        let modifiers = Set([
            kVK_Control, kVK_RightControl, kVK_Option, kVK_RightOption, kVK_Shift, kVK_RightShift,
            kVK_Command, kVK_RightCommand, kVK_Function, kVK_CapsLock
        ].map(CGKeyCode.init))
        return (0..<128).map(CGKeyCode.init).filter { !modifiers.contains($0) }
    }()
}

private extension ModifierKeys {
    init(_ flags: CGEventFlags) {
        let keys: [(CGEventFlags, ModifierKeys)] = [
            (.maskControl, .control), (.maskAlternate, .option), (.maskShift, .shift),
            (.maskCommand, .command), (.maskSecondaryFn, .function)
        ]
        self = keys.reduce(into: []) { held, key in
            if flags.contains(key.0) { held.insert(key.1) }
        }
    }
}
