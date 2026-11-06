import Foundation
import Synchronization
import Testing
import BuddyCore

struct SummaryTests {
    @Test func sayingNewConversationAsksTheUtilityModelForASummary() {
        var engine = BuddyEngine(providerConnected: true, history: kiteHistory(), now: { Date(timeIntervalSince1970: 1_100) })
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        let request = SummaryRequest(id: 1, conversation: 0, summary: nil, turns: [kiteTurn])
        #expect(engine.handle(.transcriptFinished("New conversation.")) == [
            .resetProvider, .saveHistory(kiteHistory(lastActivity: 1_100, endedAt: 1_100)),
            .showNotch(.notice("Started a new conversation.")), .writeSummary(request)
        ])
        #expect(request.prompt == """
        Fold these new turns into the conversation summary.

        New turns:
        Owner: My paper kite is named Copper Finch.
        Buddy: Copper Finch is a lovely name.
        """)
    }

    @Test func theNextConversationStartsWithTheSummaryAndItsWireTextIsRight() {
        var engine = BuddyEngine(providerConnected: true, history: kiteHistory(), now: { Date(timeIntervalSince1970: 1_100) })
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("New conversation."))
        let summarized = kiteHistory(lastActivity: 1_100, endedAt: 1_100, summary: "The owner's paper kite is named Copper Finch.")
        #expect(engine.handle(.summaryWritten(id: 1, " The owner's paper kite is named Copper Finch.\n")) == [.saveHistory(summarized)])
        #expect(engine.state.history == summarized)

        let request = TurnRequest(transcript: "What is my kite called?", captures: [], earlierSummaries: ["The owner's paper kite is named Copper Finch."])
        #expect(ask("What is my kite called?", on: &engine) == [.sendTurn(request)])
        #expect(request.content == [
            .text("Your owner's profile is empty. They haven't asked you to remember anything about them."),
            .text("The dock has no agent runs."),
            .text("Summaries of earlier conversations, oldest first:\n- The owner's paper kite is named Copper Finch."),
            .text("What is my kite called?")
        ])
    }

    @Test func aSummaryThatLandsAfterTheNextConversationStartedRestartsTheProviderAtTheFollowingTurn() {
        var engine = BuddyEngine(providerConnected: true, history: kiteHistory(), now: { Date(timeIntervalSince1970: 1_100) })
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("New conversation."))
        #expect(ask("Hi", on: &engine) == [.sendTurn(TurnRequest(transcript: "Hi", captures: []))])
        let summarized = kiteHistory(lastActivity: 1_100, endedAt: 1_100, summary: "The owner's kite is Copper Finch.")
        #expect(engine.handle(.summaryWritten(id: 1, "The owner's kite is Copper Finch.")) == [.saveHistory(summarized)])
        _ = engine.handle(.provider(.textDelta("Hello.")))
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        #expect(ask("What is my kite called?", on: &engine) == [.resetProvider, .sendTurn(TurnRequest(
            transcript: "What is my kite called?", captures: [], earlierSummaries: ["The owner's kite is Copper Finch."],
            recentTurns: [TurnRecord(transcript: "Hi", reply: "Hello.")]
        ))])
        _ = engine.handle(.provider(.textDelta("Copper Finch.")))
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        #expect(ask("Thanks", on: &engine) == [.sendTurn(TurnRequest(
            transcript: "Thanks", captures: [], earlierSummaries: ["The owner's kite is Copper Finch."],
            recentTurns: [TurnRecord(transcript: "Hi", reply: "Hello."), TurnRecord(transcript: "What is my kite called?", reply: "Copper Finch.")]
        ))])
    }

    @Test func earlierSummariesStayWithinTheirBudgetNewestFirst() {
        let long = String(repeating: "a", count: 1_000)
        let history = ConversationHistory(conversations: [
            ended("one", at: 100), ended("two", at: 200), ended(long, at: 300), ended("four", at: 400),
            Conversation(turns: [kiteTurn], lastActivity: Date(timeIntervalSince1970: 450), endedAt: Date(timeIntervalSince1970: 460)),
            ended(long, at: 500), ended("six", at: 600), ended("seven", at: 700)
        ])
        var engine = BuddyEngine(providerConnected: true, history: history, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(ask("Hello", on: &engine) == [.sendTurn(TurnRequest(
            transcript: "Hello", captures: [], earlierSummaries: ["four", long, "six", "seven"]
        ))])

        let crowded = ConversationHistory(conversations: (1...7).map { ended("summary \($0)", at: TimeInterval($0) * 100) })
        var counted = BuddyEngine(providerConnected: true, history: crowded, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(ask("Hello", on: &counted) == [.sendTurn(TurnRequest(
            transcript: "Hello", captures: [], earlierSummaries: ["summary 3", "summary 4", "summary 5", "summary 6", "summary 7"]
        ))])
    }

    @Test func aLongConversationKeepsItsOwnSummaryOfTurnsBeyondTheRecentTen() {
        let earlier = ended("The owner likes tea.", at: 100)
        var engine = BuddyEngine(providerConnected: true, history: ConversationHistory(conversations: [
            earlier, Conversation(turns: numbered(1...10), lastActivity: Date(timeIntervalSince1970: 1_000))
        ]), now: { Date(timeIntervalSince1970: 1_000) })
        #expect(engine.handle(.clockTick) == [])
        _ = ask("q11", on: &engine)
        _ = engine.handle(.provider(.textDelta("a11")))
        #expect(engine.handle(.provider(.completed)) == [
            .saveHistory(ConversationHistory(conversations: [earlier, Conversation(turns: numbered(1...11), lastActivity: Date(timeIntervalSince1970: 1_000))])),
            .speak("a11", voice: .apple),
            .writeSummary(SummaryRequest(id: 1, conversation: 1, summary: nil, turns: numbered(1...1)))
        ])
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        #expect(engine.handle(.summaryWritten(id: 1, "They began with q1.")) == [.saveHistory(ConversationHistory(conversations: [
            earlier,
            Conversation(turns: numbered(1...11), lastActivity: Date(timeIntervalSince1970: 1_000), summary: ConversationSummary(text: "They began with q1.", turns: 1))
        ]))])

        let request = TurnRequest(
            transcript: "q12", captures: [], earlierSummaries: ["The owner likes tea."], summary: "They began with q1.", recentTurns: numbered(2...11)
        )
        #expect(ask("q12", on: &engine) == [.sendTurn(request)])
        #expect(request.content == [
            .text("Your owner's profile is empty. They haven't asked you to remember anything about them."),
            .text("The dock has no agent runs."),
            .text("Summaries of earlier conversations, oldest first:\n- The owner likes tea."),
            .text("Summary of this conversation so far:\nThey began with q1."),
            .text("Recent exchanges in this conversation (text only):\n" + (2...11).map { "Owner: q\($0)\nBuddy: a\($0)" }.joined(separator: "\n\n")),
            .text("q12")
        ])
    }

    @Test func endingALongConversationFoldsItsRemainingTurnsIntoItsSummary() {
        let partial = ConversationSummary(text: "Earlier talk.", turns: 2)
        var engine = BuddyEngine(providerConnected: true, history: ConversationHistory(conversations: [
            Conversation(turns: numbered(1...12), lastActivity: Date(timeIntervalSince1970: 1_000), summary: partial)
        ]), now: { Date(timeIntervalSince1970: 1_600) })
        #expect(engine.handle(.clockTick) == [
            .resetProvider,
            .saveHistory(ConversationHistory(conversations: [Conversation(
                turns: numbered(1...12), lastActivity: Date(timeIntervalSince1970: 1_000), endedAt: Date(timeIntervalSince1970: 1_600), summary: partial
            )])),
            .writeSummary(SummaryRequest(id: 1, conversation: 0, summary: "Earlier talk.", turns: numbered(3...12)))
        ])
        #expect(SummaryRequest(id: 1, conversation: 0, summary: "Earlier talk.", turns: numbered(11...12)).prompt == """
        Fold these new turns into the conversation summary.

        Summary so far:
        Earlier talk.

        New turns:
        Owner: q11
        Buddy: a11

        Owner: q12
        Buddy: a12
        """)
        #expect(engine.handle(.summaryWritten(id: 1, "All of it.")) == [.saveHistory(ConversationHistory(conversations: [Conversation(
            turns: numbered(1...12), lastActivity: Date(timeIntervalSince1970: 1_000), endedAt: Date(timeIntervalSince1970: 1_600),
            summary: ConversationSummary(text: "All of it.", turns: 12)
        )]))])
    }

    @Test func aFailedSummaryWaitsForTheNextTurnInsteadOfEveryEvent() {
        let clock = Clock()
        var engine = BuddyEngine(providerConnected: true, history: kiteHistory(), now: { clock.now })
        clock.set(1_600)
        #expect(engine.handle(.clockTick) == [
            .resetProvider, .saveHistory(kiteHistory(endedAt: 1_600)), .writeSummary(SummaryRequest(id: 1, conversation: 0, summary: nil, turns: [kiteTurn]))
        ])
        #expect(engine.handle(.clockTick) == [])
        #expect(engine.handle(.summaryFailed(id: 1)) == [])
        #expect(engine.handle(.clockTick) == [])
        #expect(engine.handle(.summaryWritten(id: 1, "late")) == [])
        #expect(engine.state.history == kiteHistory(endedAt: 1_600))

        _ = ask("What next?", on: &engine)
        _ = engine.handle(.provider(.textDelta("Rest.")))
        #expect(engine.handle(.provider(.completed)) == [
            .saveHistory(ConversationHistory(conversations: [
                Conversation(turns: [kiteTurn], lastActivity: Date(timeIntervalSince1970: 1_000), endedAt: Date(timeIntervalSince1970: 1_600)),
                Conversation(turns: [TurnRecord(transcript: "What next?", reply: "Rest.")], lastActivity: Date(timeIntervalSince1970: 1_600))
            ])),
            .speak("Rest.", voice: .apple),
            .writeSummary(SummaryRequest(id: 2, conversation: 0, summary: nil, turns: [kiteTurn]))
        ])
        #expect(engine.handle(.summaryWritten(id: 2, "   ")) == [])
        #expect(engine.handle(.clockTick) == [])
    }

    @Test func aSummaryThatFailedBeforeTheProviderWasReadyIsRetriedWhenItChanges() {
        var engine = BuddyEngine(providerConnected: true, history: kiteHistory(endedAt: 1_010), now: { Date(timeIntervalSince1970: 1_100) })
        let request = SummaryRequest(id: 1, conversation: 0, summary: nil, turns: [kiteTurn])
        #expect(engine.handle(.clockTick) == [.writeSummary(request)])
        #expect(engine.handle(.summaryFailed(id: 1)) == [])
        #expect(engine.handle(.clockTick) == [])
        #expect(engine.handle(.providerChanged) == [.writeSummary(SummaryRequest(id: 2, conversation: 0, summary: nil, turns: [kiteTurn]))])
        #expect(engine.handle(.providerChanged) == [])
    }

    @Test func aSummaryThatFailsAfterTheProviderChangedDuringItIsRetriedOnTheNewProvider() {
        var engine = BuddyEngine(providerConnected: true, history: kiteHistory(endedAt: 1_010), now: { Date(timeIntervalSince1970: 1_100) })
        #expect(engine.handle(.clockTick) == [.writeSummary(SummaryRequest(id: 1, conversation: 0, summary: nil, turns: [kiteTurn]))])
        #expect(engine.handle(.providerChanged) == [])
        #expect(engine.handle(.summaryFailed(id: 1)) == [.writeSummary(SummaryRequest(id: 2, conversation: 0, summary: nil, turns: [kiteTurn]))])
        #expect(engine.handle(.summaryFailed(id: 2)) == [])
        #expect(engine.handle(.clockTick) == [])
    }

    @Test func aProviderChangeAlreadyRestartedTheProcessSoTheNextTurnDoesNotResetItAgain() {
        var engine = BuddyEngine(providerConnected: true, history: kiteHistory(), now: { Date(timeIntervalSince1970: 1_100) })
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("New conversation."))
        _ = ask("Hi", on: &engine)
        _ = engine.handle(.summaryWritten(id: 1, "The owner's kite is Copper Finch."))
        _ = engine.handle(.provider(.textDelta("Hello.")))
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        #expect(engine.handle(.providerChanged) == [])
        #expect(ask("What is my kite called?", on: &engine) == [.sendTurn(TurnRequest(
            transcript: "What is my kite called?", captures: [], earlierSummaries: ["The owner's kite is Copper Finch."],
            recentTurns: [TurnRecord(transcript: "Hi", reply: "Hello.")]
        ))])
    }

    @Test func clearingHistoryCancelsTheSummaryAndDropsItsLateAnswer() {
        var engine = BuddyEngine(providerConnected: true, history: kiteHistory(), now: { Date(timeIntervalSince1970: 1_600) })
        _ = engine.handle(.clockTick)
        #expect(engine.handle(.clearHistoryRequested) == [.cancelSummary, .cancelCapture, .resetProvider, .hideBuddy, .clearHistory])
        #expect(engine.handle(.summaryWritten(id: 1, "The owner's paper kite is named Copper Finch.")) == [])
        _ = engine.handle(.historyCleared(error: nil))
        #expect(engine.state.history == ConversationHistory())
        #expect(engine.handle(.clockTick) == [])
        #expect(ask("Hello", on: &engine) == [.sendTurn(TurnRequest(transcript: "Hello", captures: []))])
    }

    @Test func summariesAreSavedAsTextAndOlderHistoryStillLoads() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(kiteHistory(endedAt: 1_100, summary: "Copper Finch."))
        #expect(String(decoding: data, as: UTF8.self) == #"{"conversations":[{"endedAt":-978306100,"id":0,"lastActivity":-978306200,"startedAt":-978306200,"summary":{"text":"Copper Finch.","turns":1},"turns":[{"reply":"Copper Finch is a lovely name.","transcript":"My paper kite is named Copper Finch."}]}],"nextConversationID":1}"#)
        let older = #"{"conversations":[{"endedAt":-978306100,"lastActivity":-978306200,"turns":[{"reply":"Copper Finch is a lovely name.","transcript":"My paper kite is named Copper Finch."}]}]}"#
        #expect(try JSONDecoder().decode(ConversationHistory.self, from: Data(older.utf8)) == kiteHistory(endedAt: 1_100))
    }

    @Test func afterARelaunchTheFirstTickSummarizesRecentConversationsThatHaveNone() {
        let history = ConversationHistory(conversations: (1...7).map { index in Conversation(
            turns: [TurnRecord(transcript: "q\(index)", reply: "a\(index)")],
            lastActivity: Date(timeIntervalSince1970: TimeInterval(index) * 100), endedAt: Date(timeIntervalSince1970: TimeInterval(index) * 100 + 1)
        ) })
        var engine = BuddyEngine(providerConnected: true, history: history, now: { Date(timeIntervalSince1970: 2_000) })
        var asked: [Int] = []
        var effects = engine.handle(.clockTick)
        while case .writeSummary(let request) = effects.last {
            asked.append(request.conversation)
            effects = engine.handle(.summaryWritten(id: request.id, "summary \(request.conversation)"))
        }
        #expect(asked == [6, 5, 4, 3, 2])
        #expect(engine.handle(.clockTick) == [])
    }
}

private let kiteTurn = TurnRecord(transcript: "My paper kite is named Copper Finch.", reply: "Copper Finch is a lovely name.")

private func kiteHistory(lastActivity: TimeInterval = 1_000, endedAt: TimeInterval? = nil, summary: String? = nil) -> ConversationHistory {
    ConversationHistory(conversations: [Conversation(
        turns: [kiteTurn], startedAt: Date(timeIntervalSince1970: 1_000), lastActivity: Date(timeIntervalSince1970: lastActivity),
        endedAt: endedAt.map { Date(timeIntervalSince1970: $0) },
        summary: summary.map { ConversationSummary(text: $0, turns: 1) }
    )])
}

private func ended(_ summary: String, at time: TimeInterval) -> Conversation {
    Conversation(
        turns: [TurnRecord(transcript: "q", reply: "a")], lastActivity: Date(timeIntervalSince1970: time),
        endedAt: Date(timeIntervalSince1970: time + 1), summary: ConversationSummary(text: summary, turns: 1)
    )
}

private func numbered(_ range: ClosedRange<Int>) -> [TurnRecord] {
    range.map { TurnRecord(transcript: "q\($0)", reply: "a\($0)") }
}

private func ask(_ transcript: String, on engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
    _ = engine.handle(.pushToTalkPressed)
    _ = engine.handle(.pushToTalkReleased)
    _ = engine.handle(.transcriptFinished(transcript))
    return engine.handle(.screensCaptured([]))
}

private final class Clock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000))
    var now: Date { value.withLock { $0 } }
    func set(_ seconds: TimeInterval) { value.withLock { $0 = Date(timeIntervalSince1970: seconds) } }
}
