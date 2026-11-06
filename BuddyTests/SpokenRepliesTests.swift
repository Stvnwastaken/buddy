import BuddyCore
import Foundation
import Testing
@testable import Buddy

@MainActor
struct SpokenRepliesTests {
    @Test func spokenRepliesDefaultOnAndTheChoiceSurvivesANewManager() throws {
        let suite = "dev.steven.buddy.tests.spokenReplies.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let history = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-history.json")
        let profile = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-profile.md")

        let manager = CompanionManager(historyURL: history, profileURL: profile, preferences: preferences)
        #expect(manager.state.spokenReplies)
        manager.send(.spokenRepliesChanged(false))
        #expect(!manager.state.spokenReplies)

        let reopened = CompanionManager(historyURL: history, profileURL: profile, preferences: preferences)
        #expect(!reopened.state.spokenReplies)
        reopened.send(.spokenRepliesChanged(true))
        #expect(CompanionManager(historyURL: history, profileURL: profile, preferences: preferences).state.spokenReplies)
    }
}
