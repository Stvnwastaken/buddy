import BuddyCore
import Foundation

/// The owner's profile as `profile.md` beside the history.
final class ProfileStore {
    nonisolated static let defaultURL = URL.applicationSupportDirectory.appending(path: "Buddy/profile.md")
    private let url: URL
    private var allowsWrites = true

    init(url: URL = ProfileStore.defaultURL) {
        self.url = url
    }

    func load() throws -> Profile {
        do {
            return Profile(markdown: try String(contentsOf: url, encoding: .utf8))
        } catch CocoaError.fileReadNoSuchFile {
            return Profile()
        } catch {
            allowsWrites = false
            throw error
        }
    }

    func save(_ profile: Profile) throws {
        guard allowsWrites else { throw ProfileError.unreadable }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(profile.markdown.utf8).write(to: url, options: .atomic)
    }

    /// A failed clear leaves the old notes in the file, so saves stay blocked until a clear succeeds.
    func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            allowsWrites = false
            throw error
        }
        allowsWrites = true
    }
}

private enum ProfileError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "Buddy couldn't read or clear your saved profile. Clear the profile before Buddy remembers anything new."
    }
}
