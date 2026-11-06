import BuddyCore
import Foundation
import Testing
@testable import Buddy

@MainActor
struct PastConversationStoreTests {
    @Test func deletionAndClearReachTheOwnedFileAndReloadedProviderContext() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Buddy-issue61-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "history.json")
        let store = HistoryStore(url: url)
        let date = Date(timeIntervalSince1970: 1_000)
        try store.save(ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "Keep my kite", reply: "Copper Finch.")], lastActivity: date,
                         endedAt: date, summary: ConversationSummary(text: "The kite is Copper Finch.", turns: 1)),
            Conversation(turns: [TurnRecord(transcript: "Delete my fern", reply: "Silver Fern.")], lastActivity: date,
                         endedAt: date, summary: ConversationSummary(text: "The fern is Silver Fern.", turns: 1))
        ]))
        var engine = BuddyEngine(providerConnected: true, history: try store.load(), now: { date })
        for effect in engine.handle(.conversationDeleted(1)) {
            if case .saveHistory(let history) = effect { try store.save(history) }
        }
        let saved = try store.load()
        #expect(saved.conversations.map(\.turns) == [[TurnRecord(transcript: "Keep my kite", reply: "Copper Finch.")]])
        #expect(saved.conversations.map(\.summary?.text) == ["The kite is Copper Finch."])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Silver Fern") == false)
        var relaunched = BuddyEngine(providerConnected: true, history: saved, now: { date })
        _ = relaunched.handle(.textBoxFocused)
        _ = relaunched.handle(.textBoxSubmitted("What do you remember?"))
        #expect(relaunched.handle(.screensCaptured([])) == [.sendTurn(TurnRequest(
            transcript: "What do you remember?", captures: [], earlierSummaries: ["The kite is Copper Finch."]
        ))])
        for effect in relaunched.handle(.clearHistoryRequested) {
            if case .clearHistory = effect { try store.clear() }
        }
        _ = relaunched.handle(.historyCleared(error: nil))
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect(try store.load().conversations == [])
        var empty = BuddyEngine(history: try store.load(), now: { date })
        _ = empty.handle(.conversationsRequested)
        #expect(empty.state.notchConversation.pastConversations == [])
    }

    @Test(arguments: [
        "not readable history",
        #"{"conversations":[{"id":0,"lastActivity":0,"turns":[]},{"id":0,"lastActivity":0,"turns":[]}]}"#,
        #"{"conversations":[{"id":9223372036854775807,"lastActivity":0,"turns":[]}]}"#
    ])
    func unreadableHistoryIncludingInvalidIdentifiersStaysProtectedUntilClear(contents: String) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Buddy-issue61-unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "history.json")
        let original = Data(contents.utf8)
        try original.write(to: url)
        let store = HistoryStore(url: url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(ConversationHistory()) }
        #expect(try Data(contentsOf: url) == original)
        try store.clear()
        try store.save(ConversationHistory())
        #expect(try store.load().conversations == [])
    }
}
