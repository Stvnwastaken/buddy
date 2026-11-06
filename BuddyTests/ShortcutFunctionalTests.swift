import AppKit
import BuddyCore
import Combine
import SwiftUI
import Testing
@testable import Buddy

@MainActor
private final class ShortcutEars: Ears {
    var starts = 0
    var stops = 0
    private var transcript: ((String) -> Void)?

    func prepare(onModelStatus: @escaping (SpeechModelStatus) -> Void) {}
    func startListening(onHeard: @escaping (String) -> Void, onTranscript: @escaping (String) -> Void,
                        onFailure: @escaping (String) -> Void) {
        starts += 1
        transcript = onTranscript
    }
    func stopListening() { stops += 1 }
    func finish() { transcript?("") }
}

private struct ShortcutCheckView: View {
    @ObservedObject var manager: CompanionManager
    var body: some View {
        ShortcutSettingsView(shortcuts: manager.state.shortcuts, error: manager.state.shortcutError) {
            manager.send(.shortcutChosen($0, $1))
        }
        .padding(12)
        .background(DS.Colors.background)
    }
}

@MainActor
struct ShortcutFunctionalTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_LIVE_SHORTCUTS"] == "1"))
    func settingsApplyRebindsNativeModifierInputImmediatelyAndSurvivesANewManager() async throws {
        let root = URL(filePath: "/tmp/buddy-frontier-issue-20/functional", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "dev.steven.buddy.tests.shortcutUI.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ears = ShortcutEars()
        let manager = CompanionManager(historyURL: root.appending(path: "history.json"),
                                       profileURL: root.appending(path: "profile.md"), preferences: preferences,
                                       codexScreenshotRoot: root.appending(path: "screenshots"), ears: ears)
        let view = NSHostingView(rootView: ShortcutCheckView(manager: manager))
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 380, height: 510),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Buddy issue 20 shortcut check"
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        panel.orderFront(nil)
        defer {
            panel.close()
            manager.stop()
            preferences.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(200))
        try picture(view, at: root.appending(path: "defaults.png"))

        try await press("shortcut.talk.1", in: view) // Remove Control, keep Option.
        try await press("shortcut.talk.4", in: view) // Add Shift.
        try await press("shortcut.talk.apply", in: view)
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.state.shortcuts[.talk] == .held([.option, .shift]))
        let saved = Data(#"{"talk":{"kind":"held","modifiers":6},"textBox":{"kind":"doubleTap","modifiers":1}}"#.utf8)
        #expect(preferences.data(forKey: "shortcutsV1") == saved)
        try picture(view, at: root.appending(path: "rebound.png"))

        let monitor = GlobalPushToTalkShortcutMonitor()
        let subscription = monitor.eventPublisher.sink { manager.send($0) }
        func modifiers(_ flags: CGEventFlags, at milliseconds: UInt64) throws {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: true))
            event.flags = flags
            event.timestamp = milliseconds * 1_000_000
            _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        }
        // Deliver native events directly to this monitor; never post to the global input stream or install a tap.
        try modifiers([.maskControl, .maskAlternate], at: 0)
        try modifiers([], at: 100)
        #expect(ears.starts == 0)
        try modifiers([.maskAlternate, .maskShift], at: 200)
        #expect(manager.state.turn == .held)
        #expect(ears.starts == 1)
        try modifiers(.maskAlternate, at: 300)
        #expect(manager.state.turn == .transcribing)
        #expect(ears.stops == 1)
        try modifiers([], at: 350)
        ears.finish()
        #expect(manager.state.turn == .idle)

        manager.send(.shortcutChosen(.talk, .held(.control)))
        #expect(manager.state.shortcutError == "That shortcut conflicts with Text box. Choose different modifiers.")
        #expect(preferences.data(forKey: "shortcutsV1") == saved)
        try await Task.sleep(for: .milliseconds(100))
        try picture(view, at: root.appending(path: "conflict.png"))

        let relaunched = CompanionManager(historyURL: root.appending(path: "history.json"),
                                          profileURL: root.appending(path: "profile.md"), preferences: preferences,
                                          codexScreenshotRoot: root.appending(path: "screenshots"), ears: ShortcutEars())
        #expect(relaunched.state.shortcuts[.talk] == .held([.option, .shift]))
        #expect(relaunched.state.shortcuts[.textBox] == .doubleTap(.control))
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
        withExtendedLifetime(subscription) {}
        print("SHORTCUT_FUNCTIONAL oldComboStarts=0 newComboStarts=1 releaseStops=1 persisted=6 conflictPreserved=6 focusPreserved=true globalEventsPosted=0 microphoneOpened=false")
    }

    private func press(_ identifier: String, in root: NSView) async throws {
        func find(_ element: NSObject) -> NSObject? {
            if element.accessibilityAttributeValue(.identifier) as? String == identifier { return element }
            for child in element.accessibilityAttributeValue(.children) as? [NSObject] ?? [] {
                if let found = find(child) { return found }
            }
            return nil
        }
        if let element = find(root) {
            element.accessibilityPerformAction(.press)
        } else {
            // SwiftUI can withhold its AX tree when no assistive client is attached. Click only this owned window.
            let positions: [String: NSPoint] = [
                "shortcut.talk.1": NSPoint(x: 55, y: 142),
                "shortcut.talk.4": NSPoint(x: 176, y: 142),
                "shortcut.talk.apply": NSPoint(x: 326, y: 181)
            ]
            let offset = try #require(positions[identifier])
            let window = try #require(root.window)
            let local = NSPoint(x: offset.x, y: root.isFlipped ? offset.y : root.bounds.height - offset.y)
            let location = root.convert(local, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
            print("SHORTCUT_OWN_WINDOW_PRESS \(identifier) bounds=\(root.bounds) offset=\(offset)")
        }
        try await Task.sleep(for: .milliseconds(80))
    }

    private func picture(_ view: NSView, at url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
