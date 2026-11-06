import Foundation
import Testing
@testable import Buddy

@MainActor
struct CodexScreenshotIsolationTests {
    @Test func constructingASecondManagerPreservesAnExistingScreenshot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BuddyScreenshotBaseline-\(UUID().uuidString)")
        let suite = "dev.steven.buddy.tests.screenshotBaseline.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let first = CompanionManager(
            historyURL: root.appending(path: "history-one.json"), profileURL: root.appending(path: "profile-one.md"),
            preferences: preferences, codexScreenshotRoot: root
        )
        let screenshot = root.appending(path: "existing-turn.jpg")
        try Data([1, 2, 3]).write(to: screenshot)
        let second = CompanionManager(
            historyURL: root.appending(path: "history-two.json"), profileURL: root.appending(path: "profile-two.md"),
            preferences: preferences, codexScreenshotRoot: root
        )
        #expect(FileManager.default.fileExists(atPath: screenshot.path))
        withExtendedLifetime((first, second)) {}
    }

    @Test func managersKeepEachOthersScreenshotsAndRemoveOnlyTheirOwnDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BuddyScreenshotIsolation-\(UUID().uuidString)")
        let suite = "dev.steven.buddy.tests.screenshots.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = root.appending(path: "existing-owner-image.jpg")
        try Data([1, 2, 3]).write(to: sentinel)
        var first: CompanionManager? = CompanionManager(
            historyURL: root.appending(path: "history-one.json"), profileURL: root.appending(path: "profile-one.md"),
            preferences: preferences, codexScreenshotRoot: root
        )
        #expect(try Data(contentsOf: sentinel) == Data([1, 2, 3]))
        let firstFolder = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        let firstImage = firstFolder.appending(path: "turn-one.jpg")
        try Data([4, 5, 6]).write(to: firstImage)
        var second: CompanionManager? = CompanionManager(
            historyURL: root.appending(path: "history-two.json"), profileURL: root.appending(path: "profile-two.md"),
            preferences: preferences, codexScreenshotRoot: root
        )
        #expect(try Data(contentsOf: firstImage) == Data([4, 5, 6]))
        #expect(try Data(contentsOf: sentinel) == Data([1, 2, 3]))
        let secondFolder = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .first { $0 != firstFolder && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        let secondImage = secondFolder.appending(path: "turn-two.jpg")
        try Data([7, 8, 9]).write(to: secondImage)
        withExtendedLifetime(first) {}
        first = nil
        #expect(!FileManager.default.fileExists(atPath: firstFolder.path))
        #expect(try Data(contentsOf: secondImage) == Data([7, 8, 9]))
        withExtendedLifetime(second) {}
        second = nil
        #expect(!FileManager.default.fileExists(atPath: secondFolder.path))
        #expect(try Data(contentsOf: sentinel) == Data([1, 2, 3]))
    }
}
