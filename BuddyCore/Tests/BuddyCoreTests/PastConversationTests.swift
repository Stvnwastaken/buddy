import BuddyCore
import Foundation
import Testing

struct PastConversationTests {
    @Test func pushToTalkContinuesAReopenedConversationWithoutExpiringItsOldDate() {
        let date = Date(timeIntervalSince1970: 100_000)
        var engine = BuddyEngine(providerConnected: true, history: ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "My kite", reply: "Copper Finch.")],
                         lastActivity: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 110),
                         summary: ConversationSummary(text: "Copper Finch is the owner's kite.", turns: 1))
        ]), now: { date })
        _ = engine.handle(.conversationOpened(0))
        _ = engine.handle(.conversationsRequested)
        _ = engine.handle(.pushToTalkPressed)
        #expect(engine.state.notchConversation.page == .thread)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("What is its name?"))
        #expect(engine.handle(.screensCaptured([])) == [.sendTurn(TurnRequest(
            transcript: "What is its name?", captures: [], summary: "Copper Finch is the owner's kite."
        ))])
        _ = engine.handle(.provider(.textDelta("Copper Finch.")))
        _ = engine.handle(.provider(.completed))
        #expect(engine.state.history.conversations.map(\.turns) == [[
            TurnRecord(transcript: "My kite", reply: "Copper Finch."),
            TurnRecord(transcript: "What is its name?", reply: "Copper Finch.")
        ]])
    }

    @Test func deletingTheSelectedConversationRejectsLateTurnsAndNeverReusesItsIdentifier() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        var engine = BuddyEngine(providerConnected: true, history: ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "Delete me", reply: "Only here.")], lastActivity: date)
        ]), now: { date })
        _ = engine.handle(.textBoxFocused)
        _ = engine.handle(.textBoxSubmitted("A turn still capturing"))
        #expect(engine.handle(.conversationDeleted(0)).contains(.cancelCapture))
        #expect(engine.state.notchConversation.entries == [])
        #expect(engine.state.notchConversation.pastConversations == [])
        #expect(engine.handle(.screensCaptured([])) == [])
        #expect(engine.handle(.provider(.completed)) == [])
        #expect(engine.handle(.conversationOpened(0)) == [])
        let data = try JSONEncoder().encode(engine.state.history)
        let loaded = try JSONDecoder().decode(ConversationHistory.self, from: data)
        var relaunched = BuddyEngine(providerConnected: true, history: loaded, now: { date })
        _ = relaunched.handle(.textBoxFocused)
        _ = relaunched.handle(.textBoxSubmitted("New question"))
        _ = relaunched.handle(.screensCaptured([]))
        _ = relaunched.handle(.provider(.textDelta("New answer.")))
        _ = relaunched.handle(.provider(.completed))
        #expect(relaunched.state.notchConversation.pastConversations == [
            .init(id: 1, question: "New question", startedAt: date, lastActivity: date)
        ])
        #expect(relaunched.handle(.conversationOpened(0)) == [])
    }

    @Test func clearingFromSettingsEmptiesTheListAndRejectsOldSummaryAndSelection() {
        let date = Date(timeIntervalSince1970: 1_000)
        var engine = BuddyEngine(history: ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "Past", reply: "Old.")], lastActivity: date, endedAt: date),
            Conversation(turns: [TurnRecord(transcript: "Current", reply: "New.")], lastActivity: date)
        ]), now: { date })
        _ = engine.handle(.conversationsRequested)
        let clearing = engine.handle(.clearHistoryRequested)
        #expect(clearing.contains(.clearHistory))
        #expect(clearing.contains(.cancelSummary))
        #expect(engine.state.notchConversation.pastConversations == [])
        #expect(engine.state.notchConversation.entries == [])
        #expect(engine.handle(.conversationOpened(0)) == [])
        #expect(engine.handle(.conversationDeleted(1)) == [])
        #expect(engine.handle(.summaryWritten(id: 1, "Must not come back.")) == [])
        _ = engine.handle(.historyCleared(error: nil))
        _ = engine.handle(.conversationsRequested)
        #expect(engine.state.notchConversation.page == .history)
        #expect(engine.state.notchConversation.pastConversations == [])
        #expect(engine.state.history.conversations == [])
    }

    @Test func legacyTextHistoryGetsStableIdentifiersAcrossReopenSaveAndReload() throws {
        let legacy = #"{"conversations":[{"endedAt":-978307000,"lastActivity":-978307100,"turns":[{"transcript":"Old","reply":"Gold."}]},{"lastActivity":-978306200,"turns":[{"transcript":"Current","reply":"Fern."}]}]}"#
        let loaded = try JSONDecoder().decode(ConversationHistory.self, from: Data(legacy.utf8))
        var engine = BuddyEngine(history: loaded, now: { Date(timeIntervalSince1970: 1_000) })
        _ = engine.handle(.conversationOpened(0))
        _ = engine.handle(.conversationDeleted(1))
        let data = try JSONEncoder().encode(engine.state.history)
        var relaunched = BuddyEngine(history: try JSONDecoder().decode(ConversationHistory.self, from: data),
                                    now: { Date(timeIntervalSince1970: 1_000) })
        _ = relaunched.handle(.conversationsRequested)
        #expect(relaunched.state.notchConversation.pastConversations == [
            .init(id: 0, question: "Old", startedAt: Date(timeIntervalSince1970: 100), lastActivity: Date(timeIntervalSince1970: 1_000))
        ])
        #expect(relaunched.state.notchConversation.entries == [.owner("Old"), .buddy("Gold.")])
        #expect(relaunched.handle(.conversationOpened(1)) == [])
    }

    @Test func deletingAnInFlightSummaryCannotResurrectItAfterANewerCompletion() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        var engine = BuddyEngine(providerConnected: true, history: ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "Keep the kite", reply: "Copper Finch.")], lastActivity: date, endedAt: date),
            Conversation(turns: [TurnRecord(transcript: "Delete the secret", reply: "Deleted words.")], lastActivity: date, endedAt: date),
            Conversation(turns: [TurnRecord(transcript: "Current", reply: "Fern.")], lastActivity: date)
        ]), now: { date })
        #expect(engine.handle(.clockTick) == [.writeSummary(SummaryRequest(id: 1, conversation: 1, summary: nil,
            turns: [TurnRecord(transcript: "Delete the secret", reply: "Deleted words.")]))])
        let deleting = engine.handle(.conversationDeleted(1))
        #expect(deleting.contains(.cancelSummary))
        #expect(deleting.contains(.resetProvider))
        #expect(deleting.contains(.writeSummary(SummaryRequest(id: 2, conversation: 0, summary: nil,
            turns: [TurnRecord(transcript: "Keep the kite", reply: "Copper Finch.")]))))
        _ = engine.handle(.summaryWritten(id: 2, "The kite is Copper Finch."))
        #expect(engine.handle(.summaryWritten(id: 1, "Secret that must stay deleted.")) == [])
        #expect(engine.state.history.conversations.map(\.turns) == [
            [TurnRecord(transcript: "Keep the kite", reply: "Copper Finch.")], [TurnRecord(transcript: "Current", reply: "Fern.")]
        ])
        #expect(engine.state.history.conversations.map(\.summary?.text) == ["The kite is Copper Finch.", nil])
        let folder = FileManager.default.temporaryDirectory.appending(path: "Buddy-issue61-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "history.json")
        try JSONEncoder().encode(engine.state.history).write(to: url, options: .atomic)
        let loaded = try JSONDecoder().decode(ConversationHistory.self, from: Data(contentsOf: url))
        var relaunched = BuddyEngine(providerConnected: true, history: loaded, now: { date })
        _ = relaunched.handle(.newConversationRequested)
        _ = relaunched.handle(.pushToTalkPressed)
        _ = relaunched.handle(.pushToTalkReleased)
        _ = relaunched.handle(.transcriptFinished("What do you remember?"))
        #expect(relaunched.handle(.screensCaptured([])) == [.sendTurn(TurnRequest(
            transcript: "What do you remember?", captures: [], earlierSummaries: ["The kite is Copper Finch."]
        ))])
    }

    @Test func aLateSummaryFollowsItsConversationThroughReopenAndEarlierDeletion() {
        let date = Date(timeIntervalSince1970: 1_000)
        var engine = BuddyEngine(history: ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "Remove", reply: "Old.")], lastActivity: date, endedAt: date,
                         summary: ConversationSummary(text: "Old.", turns: 1)),
            Conversation(turns: [TurnRecord(transcript: "Keep", reply: "Gold.")], lastActivity: date, endedAt: date),
            Conversation(turns: [TurnRecord(transcript: "Current", reply: "Fern.")], lastActivity: date)
        ]), now: { date })
        _ = engine.handle(.clockTick)
        _ = engine.handle(.conversationOpened(1))
        _ = engine.handle(.conversationDeleted(0))
        _ = engine.handle(.summaryWritten(id: 1, "Keep is gold."))
        #expect(engine.state.history.conversations.map(\.summary?.text) == [nil, "Keep is gold."])
        #expect(engine.state.notchConversation.entries == [.owner("Keep"), .buddy("Gold.")])
    }

    @Test func reopeningContinuesTheWholeThreadWithItsOwnSummaryAndRecentTurns() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        var engine = BuddyEngine(providerConnected: true, history: ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "Name my kite", reply: "Copper Finch."),
                                 TurnRecord(transcript: "Its color?", reply: "It is red.\nWith gold wings.")],
                         lastActivity: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 110),
                         summary: ConversationSummary(text: "The kite is Copper Finch.", turns: 1)),
            Conversation(turns: [TurnRecord(transcript: "Today's task", reply: "Water the fern.")], lastActivity: date)
        ]), now: { date })
        let opening = engine.handle(.conversationOpened(0))
        #expect(opening.contains(.resetProvider))
        #expect(opening.contains(.writeSummary(SummaryRequest(id: 1, conversation: 1, summary: nil,
            turns: [TurnRecord(transcript: "Today's task", reply: "Water the fern.")]))))
        #expect(engine.state.history.conversations.map(\.endedAt) == [date, nil])
        #expect(engine.state.notchConversation.entries == [
            .owner("Name my kite"), .buddy("Copper Finch."), .owner("Its color?"), .buddy("It is red."), .buddy("With gold wings.")
        ])
        _ = engine.handle(.textBoxFocused)
        _ = engine.handle(.textBoxSubmitted("What color are its wings?"))
        #expect(engine.handle(.screensCaptured([])) == [.sendTurn(TurnRequest(
            transcript: "What color are its wings?", captures: [], summary: "The kite is Copper Finch.",
            recentTurns: [TurnRecord(transcript: "Its color?", reply: "It is red.\nWith gold wings.")]
        ))])
        _ = engine.handle(.provider(.textDelta("Gold.")))
        _ = engine.handle(.provider(.completed))
        #expect(engine.state.history.conversations.last?.turns == [
            TurnRecord(transcript: "Name my kite", reply: "Copper Finch."),
            TurnRecord(transcript: "Its color?", reply: "It is red.\nWith gold wings."),
            TurnRecord(transcript: "What color are its wings?", reply: "Gold.")
        ])
        #expect(engine.state.history.conversations.first?.turns == [TurnRecord(transcript: "Today's task", reply: "Water the fern.")])
    }

    @Test func theListKeepsWhenEachConversationStartedThroughLaterTurnsReopenAndReload() throws {
        let clock = ConversationClock()
        var engine = BuddyEngine(providerConnected: true, now: { clock.now })
        func ask(_ question: String, _ answer: String) {
            _ = engine.handle(.textBoxFocused)
            _ = engine.handle(.textBoxSubmitted(question))
            _ = engine.handle(.screensCaptured([]))
            _ = engine.handle(.provider(.textDelta(answer)))
            _ = engine.handle(.provider(.completed))
        }
        ask("First question", "First answer.")
        clock.set(2_000)
        ask("Follow-up", "Second answer.")
        clock.set(3_000)
        _ = engine.handle(.newConversationRequested)
        ask("Other question", "Other answer.")
        clock.set(4_000)
        _ = engine.handle(.conversationOpened(0))
        let data = try JSONEncoder().encode(engine.state.history)
        var relaunched = BuddyEngine(history: try JSONDecoder().decode(ConversationHistory.self, from: data), now: { clock.now })
        _ = relaunched.handle(.conversationsRequested)
        #expect(relaunched.state.notchConversation.pastConversations == [
            .init(id: 0, question: "First question", startedAt: Date(timeIntervalSince1970: 1_000), lastActivity: Date(timeIntervalSince1970: 4_000)),
            .init(id: 1, question: "Other question", startedAt: Date(timeIntervalSince1970: 3_000), lastActivity: Date(timeIntervalSince1970: 3_000))
        ])
    }

    @Test func theListIsNewestFirstAndDoesNotReplaceTheCurrentThread() {
        var engine = BuddyEngine(history: ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "Yesterday's question", reply: "Yesterday's answer.")],
                         lastActivity: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 110)),
            Conversation(turns: [TurnRecord(transcript: "Today's question", reply: "Today's answer.")],
                         lastActivity: Date(timeIntervalSince1970: 200))
        ]), now: { Date(timeIntervalSince1970: 200) })
        _ = engine.handle(.conversationsRequested)
        #expect(engine.state.notchConversation.page == .history)
        #expect(engine.state.notchConversation.pastConversations == [
            .init(id: 1, question: "Today's question", startedAt: Date(timeIntervalSince1970: 200), lastActivity: Date(timeIntervalSince1970: 200)),
            .init(id: 0, question: "Yesterday's question", startedAt: Date(timeIntervalSince1970: 100), lastActivity: Date(timeIntervalSince1970: 100))
        ])
        #expect(engine.state.notchConversation.entries == [.owner("Today's question"), .buddy("Today's answer.")])
        _ = engine.handle(.conversationThreadRequested)
        #expect(engine.state.notchConversation.page == .thread)
        #expect(engine.state.notchConversation.entries == [.owner("Today's question"), .buddy("Today's answer.")])
    }
}
