import BuddyCore
import Foundation

final class HistoryStore: Store {
    nonisolated static let defaultURL = URL.applicationSupportDirectory.appending(path: "Buddy/history.json")
    private let url: URL
    private var allowsWrites = true

    init(url: URL = HistoryStore.defaultURL) {
        self.url = url
    }

    func load() throws -> ConversationHistory {
        do {
            return try JSONDecoder().decode(ConversationHistory.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return ConversationHistory()
        } catch {
            allowsWrites = false
            throw error
        }
    }

    func save(_ history: ConversationHistory) throws {
        guard allowsWrites else { throw HistoryError.unreadable }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(history).write(to: url, options: .atomic)
    }

    func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        }
        allowsWrites = true
    }
}

private enum HistoryError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "Saved history couldn't be read. Clear history before saving new turns."
    }
}
