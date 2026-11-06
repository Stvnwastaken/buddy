import BuddyCore
import Foundation
import Testing
@testable import Buddy

@MainActor
struct PenSoundsTests {
    @Test func thePenSoundChoiceDefaultsOnAndSurvivesReopening() throws {
        let suite = "dev.steven.buddy.tests.penSounds.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: "BuddyPenPreferences-\(UUID().uuidString)")
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let history = root.appending(path: "history.json")
        let profile = root.appending(path: "profile.md")
        let manager = CompanionManager(historyURL: history, profileURL: profile, preferences: preferences,
                                       codexScreenshotRoot: root.appending(path: "screenshots"))
        #expect(manager.state.penSounds == true)
        manager.send(.penSoundsChanged(false))
        #expect(manager.state.penSounds == false)
        let reopened = CompanionManager(historyURL: history, profileURL: profile, preferences: preferences,
                                        codexScreenshotRoot: root.appending(path: "screenshots"))
        #expect(reopened.state.penSounds == false)
        reopened.send(.penSoundsChanged(true))
        #expect(CompanionManager(historyURL: history, profileURL: profile, preferences: preferences,
                                 codexScreenshotRoot: root.appending(path: "screenshots")).state.penSounds == true)
    }
}
