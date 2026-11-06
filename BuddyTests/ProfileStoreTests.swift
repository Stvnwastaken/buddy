import BuddyCore
import Foundation
import Testing
@testable import Buddy

@MainActor
struct ProfileStoreTests {
    @Test func aRememberedNoteIsInTheNextLaunchesTurns() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let profileURL = folder.appending(path: "profile.md")
        let historyURL = folder.appending(path: "history.json")
        let suite = "dev.steven.buddy.tests.profile.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let first = CompanionManager(historyURL: historyURL, profileURL: profileURL, preferences: preferences)
        #expect(first.state.profile == Profile())
        try ProfileStore(url: profileURL).save(Profile(notes: ["Prefers metric units."]))
        #expect(try String(contentsOf: profileURL, encoding: .utf8) == "# About you\n\n- Prefers metric units.\n")

        let relaunched = CompanionManager(historyURL: historyURL, profileURL: profileURL, preferences: preferences)
        #expect(relaunched.state.profile == Profile(notes: ["Prefers metric units."]))
        relaunched.send(.clearProfileRequested)
        #expect(relaunched.state.profileCleared)
        #expect(!FileManager.default.fileExists(atPath: profileURL.path))
    }

    @Test func anUnreadableProfileIsKeptUntilItIsCleared() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "profile.md")
        try Data([0xFF, 0xFE, 0x00]).write(to: url)
        let store = ProfileStore(url: url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(Profile(notes: ["Goes by Sam."])) }
        #expect(try Data(contentsOf: url) == Data([0xFF, 0xFE, 0x00]))
        try store.clear()
        try store.save(Profile(notes: ["Goes by Sam."]))
        #expect(try String(contentsOf: url, encoding: .utf8) == "# About you\n\n- Goes by Sam.\n")
    }

    @Test func aFailedClearKeepsTheOldNotesSafeUntilAClearSucceeds() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-profile-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let url = folder.appending(path: "profile.md")
        let store = ProfileStore(url: url)
        try store.save(Profile(notes: ["Goes by Sam."]))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        #expect(throws: (any Error).self) { try store.clear() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(throws: (any Error).self) { try store.save(Profile(notes: ["Prefers tea."])) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "# About you\n\n- Goes by Sam.\n")
        try store.clear()
        try store.save(Profile(notes: ["Prefers tea."]))
        #expect(try String(contentsOf: url, encoding: .utf8) == "# About you\n\n- Prefers tea.\n")
    }
}
