import BuddyCore
import Foundation
import Testing
@testable import Buddy

@MainActor
struct ShortcutPreferencesTests {
    @Test func acceptedShortcutsPersistAcrossManagersAndRejectedChoicesDoNotReplaceThem() throws {
        let suite = "dev.steven.buddy.tests.shortcuts.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: "BuddyShortcutPreferences-\(UUID().uuidString)")
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let manager = CompanionManager(
            historyURL: root.appending(path: "history.json"), profileURL: root.appending(path: "profile.md"),
            preferences: preferences, codexScreenshotRoot: root.appending(path: "screenshots")
        )
        #expect(manager.state.shortcuts[.talk] == .held([.control, .option]))
        #expect(manager.state.shortcuts[.textBox] == .doubleTap(.control))

        manager.send(.shortcutChosen(.talk, .doubleTap(.option)))
        let saved = Data(#"{"talk":{"kind":"doubleTap","modifiers":2},"textBox":{"kind":"doubleTap","modifiers":1}}"#.utf8)
        #expect(preferences.data(forKey: "shortcutsV1") == saved)
        manager.send(.shortcutChosen(.textBox, .doubleTap(.option)))
        #expect(manager.state.shortcutError == "That shortcut conflicts with Talk. Choose different modifiers.")
        #expect(preferences.data(forKey: "shortcutsV1") == saved)

        let relaunched = CompanionManager(
            historyURL: root.appending(path: "history.json"), profileURL: root.appending(path: "profile.md"),
            preferences: preferences, codexScreenshotRoot: root.appending(path: "screenshots")
        )
        #expect(relaunched.state.shortcuts[.talk] == .doubleTap(.option))
        #expect(relaunched.state.shortcuts[.textBox] == .doubleTap(.control))
        #expect(relaunched.state.shortcutError == nil)
    }
}
