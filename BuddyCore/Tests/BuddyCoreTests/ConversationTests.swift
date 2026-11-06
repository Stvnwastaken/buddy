import Foundation
import Synchronization
import Testing
import BuddyCore

struct ConversationTests {
    @Test func newConversationCommandDoesNotCaptureTheScreen() {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        let effects = engine.handle(.transcriptFinished(" New conversation! "))
        #expect(effects == [.resetProvider, .showNotch(.notice("Started a new conversation."))])
        #expect(engine.state.turn == .idle)
    }

    @Test func idleExpiryIsExactlyTenMinutesAndPreservesEarlierText() {
        let clock = ConversationClock()
        var engine = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { clock.now })
        clock.set(1_599)
        #expect(engine.handle(.clockTick) == [])
        clock.set(1_600)
        let ended = oneTurnHistory(endedAt: 1_600)
        #expect(engine.handle(.clockTick) == [.resetProvider, .saveHistory(ended), gearSummary])
        #expect(engine.state.history == ended)
        #expect(engine.handle(.clockTick) == [])
        #expect(startTurn("What is next?", on: &engine) == [.sendTurn(TurnRequest(transcript: "What is next?", captures: []))])
    }

    @Test func openingTheTextBoxChecksExpiryLikeAPress() {
        var expired = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { Date(timeIntervalSince1970: 1_600) })
        #expect(controlDoubleTap.flatMap { expired.handle($0) } == [
            .resetProvider, .saveHistory(oneTurnHistory(endedAt: 1_600)), .hideBuddy, .showTextBox, gearSummary
        ])

        var recent = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { Date(timeIntervalSince1970: 1_100) })
        #expect(controlDoubleTap.flatMap { recent.handle($0) } == [
            .saveHistory(oneTurnHistory(lastActivity: 1_100)), .hideBuddy, .showTextBox
        ])
        #expect(recent.handle(.textBoxSubmitted("What is next?")) == [
            .hideTextBox, .showBuddy, .showNotch(.thinking), .captureScreens
        ])
        #expect(recent.handle(.screensCaptured([])) == [.sendTurn(TurnRequest(
            transcript: "What is next?", captures: [],
            recentTurns: [TurnRecord(transcript: "Where are settings?", reply: "Click the gear.")]
        ))])
    }

    @Test func aTextBoxLeftOpenForTenMinutesEndsTheConversation() {
        let clock = ConversationClock()
        var ticking = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { clock.now })
        clock.set(1_100)
        #expect(controlDoubleTap.flatMap { ticking.handle($0) } == [
            .saveHistory(oneTurnHistory(lastActivity: 1_100)), .hideBuddy, .showTextBox
        ])
        clock.set(1_699)
        #expect(ticking.handle(.clockTick) == [])
        clock.set(1_700)
        #expect(ticking.handle(.clockTick) == [.resetProvider, .saveHistory(oneTurnHistory(lastActivity: 1_100, endedAt: 1_700)), gearSummary])
        #expect(ticking.state.turn == .typing)
        #expect(ticking.handle(.textBoxSubmitted("What is next?")) == [
            .hideTextBox, .showBuddy, .showNotch(.thinking), .captureScreens
        ])
        #expect(ticking.handle(.screensCaptured([])) == [.sendTurn(TurnRequest(transcript: "What is next?", captures: []))])

        clock.set(1_100)
        var untimed = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { clock.now })
        _ = controlDoubleTap.flatMap { untimed.handle($0) }
        clock.set(1_700)
        #expect(untimed.handle(.textBoxSubmitted("What is next?")) == [
            .resetProvider, .saveHistory(oneTurnHistory(lastActivity: 1_100, endedAt: 1_700)),
            .hideTextBox, .showBuddy, .showNotch(.thinking), .captureScreens, gearSummary
        ])
    }

    @Test func typingNewConversationEndsTheConversationWithoutCapturing() {
        var engine = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { Date(timeIntervalSince1970: 1_100) })
        _ = controlDoubleTap.flatMap { engine.handle($0) }
        #expect(engine.handle(.textBoxSubmitted(" New conversation. ")) == [
            .hideTextBox, .showBuddy, .showNotch(.thinking), .resetProvider,
            .saveHistory(oneTurnHistory(lastActivity: 1_100, endedAt: 1_100)),
            .showNotch(.notice("Started a new conversation.")), gearSummary
        ])
        #expect(engine.state.turn == .idle)
    }

    @Test func theTextBoxStaysClosedWhileHistoryIsBeingCleared() {
        var engine = BuddyEngine(providerConnected: true, history: oneTurnHistory())
        _ = engine.handle(.clearHistoryRequested)
        #expect(controlDoubleTap.flatMap { engine.handle($0) } == [])
        #expect(engine.handle(.historyCleared(error: nil)) == [])
        #expect(controlDoubleTap.flatMap { engine.handle($0) } == [.hideBuddy, .showTextBox])
    }

    @Test func aPressChecksExpiryWithoutWaitingForATimer() {
        var engine = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { Date(timeIntervalSince1970: 1_600) })
        #expect(engine.handle(.pushToTalkPressed) == [
            .resetProvider, .saveHistory(oneTurnHistory(endedAt: 1_600)), .showNotch(.listening(heard: "")), .startListening, gearSummary
        ])
    }

    @Test func speechAndListeningAreActivityEvenWhenTheyLastOverTenMinutes() {
        let clock = ConversationClock()
        var engine = BuddyEngine(providerConnected: true, now: { clock.now })
        _ = startTurn("Where are settings?", on: &engine)
        #expect(engine.handle(.provider(.textDelta("Click the gear."))) == [])
        #expect(engine.handle(.provider(.completed)) == [.saveHistory(oneTurnHistory()), .speak("Click the gear.", voice: .apple)])
        clock.set(1_700)
        #expect(engine.handle(.clockTick) == [])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Click the gear."))])
        #expect(engine.handle(.lineFinished) == [
            .saveHistory(oneTurnHistory(lastActivity: 1_700)), .hideBuddy, .showNotch(.closing)
        ])
        clock.set(2_299)
        #expect(engine.handle(.clockTick) == [])
        _ = engine.handle(.pushToTalkPressed)
        clock.set(3_000)
        #expect(engine.handle(.clockTick) == [])
        #expect(engine.handle(.interrupted) == [
            .stopListening, .saveHistory(oneTurnHistory(lastActivity: 3_000)), .hideBuddy, .showNotch(.idle)
        ])
        clock.set(3_599)
        #expect(engine.handle(.clockTick) == [])
        clock.set(3_600)
        #expect(engine.handle(.clockTick) == [.resetProvider, .saveHistory(oneTurnHistory(lastActivity: 3_000, endedAt: 3_600)), gearSummary])
    }

    @Test(arguments: ["new conversation", "NEW CONVERSATION.", " \nNew conversation!?  "])
    func aStandaloneCommandEndsTheConversationBeforeScreenCapture(command: String) {
        var engine = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { Date(timeIntervalSince1970: 1_100) })
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished(command)) == [
            .resetProvider, .saveHistory(oneTurnHistory(lastActivity: 1_100, endedAt: 1_100)), .showNotch(.notice("Started a new conversation.")), gearSummary
        ])
        #expect(startTurn("Hello", on: &engine) == [.sendTurn(TurnRequest(transcript: "Hello", captures: []))])
    }

    @Test(arguments: ["What does new conversation mean?", "Start a new conversation about cooking", "new conversations", "new conversation tomorrow"])
    func mentioningTheCommandIsAnOrdinaryTurn(text: String) {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished(text)) == [.captureScreens])
        #expect(engine.state.turn == .capturing(transcript: text))
    }

    @Test func savedContentsHaveOnlyTranscriptAndStrippedSpokenText() throws {
        let screen = ScreenCapture(jpeg: Data([0, 255, 1]), display: DisplayRect(x: 0, y: 0, width: 100, height: 100), pixelWidth: 100, pixelHeight: 100, containsCursor: true)
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = startTurn("Where are settings?", captures: [screen], on: &engine)
        _ = engine.handle(.provider(.textDelta("[POINT:10,20:settings] Click the gear.")))
        let effects = engine.handle(.provider(.completed))
        #expect(effects == [.saveHistory(oneTurnHistory()), .speak("Click the gear.", voice: .apple)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(engine.state.history)
        #expect(String(decoding: data, as: UTF8.self) == #"{"conversations":[{"id":0,"lastActivity":-978306200,"startedAt":-978306200,"turns":[{"reply":"Click the gear.","transcript":"Where are settings?"}]}],"nextConversationID":1}"#)
        #expect(try JSONDecoder().decode(ConversationHistory.self, from: data) == oneTurnHistory())
    }

    @Test func relaunchWithinConversationPrimesTheFollowUpWithText() throws {
        let data = try JSONEncoder().encode(oneTurnHistory())
        let loaded = try JSONDecoder().decode(ConversationHistory.self, from: data)
        var relaunched = BuddyEngine(providerConnected: true, history: loaded, now: { Date(timeIntervalSince1970: 1_200) })
        #expect(startTurn("Which gear?", on: &relaunched) == [.sendTurn(TurnRequest(
            transcript: "Which gear?", captures: [], recentTurns: [TurnRecord(transcript: "Where are settings?", reply: "Click the gear.")]
        ))])
    }

    @Test func closedOrExpiredHistoryNeverPrimesAnotherConversation() {
        var closed = BuddyEngine(providerConnected: true, history: oneTurnHistory(endedAt: 1_010), now: { Date(timeIntervalSince1970: 1_200) })
        #expect(startTurn("Hello", on: &closed) == [.sendTurn(TurnRequest(transcript: "Hello", captures: []))])
        var expired = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { Date(timeIntervalSince1970: 1_600) })
        #expect(startTurn("Hello", on: &expired) == [.sendTurn(TurnRequest(transcript: "Hello", captures: []))])
    }

    @Test func primingUsesTheLatestTenTurnsInOrderAndRetainsAllHistory() {
        let turns = [
            TurnRecord(transcript: "one", reply: "1"), TurnRecord(transcript: "two", reply: "2"),
            TurnRecord(transcript: "three", reply: "3"), TurnRecord(transcript: "four", reply: "4"),
            TurnRecord(transcript: "five", reply: "5"), TurnRecord(transcript: "six", reply: "6"),
            TurnRecord(transcript: "seven", reply: "7"), TurnRecord(transcript: "eight", reply: "8"),
            TurnRecord(transcript: "nine", reply: "9"), TurnRecord(transcript: "ten", reply: "10"),
            TurnRecord(transcript: "eleven", reply: "11"), TurnRecord(transcript: "twelve", reply: "12")
        ]
        let history = ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "past", reply: "old conversation")], lastActivity: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 200)),
            Conversation(turns: turns, lastActivity: Date(timeIntervalSince1970: 1_000))
        ])
        var engine = BuddyEngine(providerConnected: true, history: history, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(startTurn("continue", on: &engine) == [.sendTurn(TurnRequest(transcript: "continue", captures: [], recentTurns: [
            TurnRecord(transcript: "three", reply: "3"), TurnRecord(transcript: "four", reply: "4"),
            TurnRecord(transcript: "five", reply: "5"), TurnRecord(transcript: "six", reply: "6"),
            TurnRecord(transcript: "seven", reply: "7"), TurnRecord(transcript: "eight", reply: "8"),
            TurnRecord(transcript: "nine", reply: "9"), TurnRecord(transcript: "ten", reply: "10"),
            TurnRecord(transcript: "eleven", reply: "11"), TurnRecord(transcript: "twelve", reply: "12")
        ]))])
        #expect(engine.state.history == history)
    }

    @Test func clearStopsTheTurnAndWaitsForDeletionBeforeClaimingSuccess() {
        var engine = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { Date(timeIntervalSince1970: 1_000) })
        _ = startTurn("continue", on: &engine)
        _ = engine.handle(.provider(.textDelta("A line.\n")))
        #expect(engine.handle(.clearHistoryRequested) == [
            .cancelReply, .stopSpeaking, .cancelCapture, .resetProvider, .hideBuddy, .showNotch(.idle), .clearHistory
        ])
        #expect(engine.state.history == ConversationHistory())
        #expect(engine.state.historyClearPending == true)
        #expect(engine.state.historyCleared == false)
        #expect(engine.handle(.pushToTalkPressed) == [])
        #expect(engine.handle(.clearHistoryRequested) == [])
        #expect(engine.handle(.clockTick) == [])
        #expect(engine.handle(.provider(.completed)) == [])
        #expect(engine.handle(.screensCaptured([])) == [])
        #expect(engine.handle(.historyCleared(error: nil)) == [])
        #expect(engine.state.historyClearPending == false)
        #expect(engine.state.historyCleared == true)
        #expect(startTurn("Hello", on: &engine) == [.sendTurn(TurnRequest(transcript: "Hello", captures: []))])
    }

    @Test func clearFailureRemainsVisibleAndCanBeRetried() {
        var engine = BuddyEngine(history: oneTurnHistory())
        _ = engine.handle(.clearHistoryRequested)
        #expect(engine.handle(.historyCleared(error: "History couldn't be cleared.")) == [.showNotch(.notice("History couldn't be cleared."))])
        #expect(engine.state.historyError == "History couldn't be cleared.")
        #expect(engine.state.historyCleared == false)
        #expect(engine.handle(.noticeExpired) == [.hideBuddy, .showNotch(.idle)])
        #expect(engine.state.historyError == "History couldn't be cleared.")
        #expect(engine.handle(.clearHistoryRequested) == [.cancelCapture, .resetProvider, .hideBuddy, .clearHistory])
        #expect(engine.handle(.historyCleared(error: nil)) == [])
        #expect(engine.state.historyError == nil)
        #expect(engine.state.historyCleared == true)
    }

    @Test func storageErrorsRemainInSettingsAfterTheOverlayExpires() {
        var engine = BuddyEngine()
        #expect(engine.handle(.historyFailed("History couldn't be saved.")) == [.showNotch(.notice("History couldn't be saved."))])
        #expect(engine.handle(.noticeExpired) == [.hideBuddy, .showNotch(.idle)])
        #expect(engine.state.historyError == "History couldn't be saved.")
        #expect(engine.handle(.historySaved) == [])
        #expect(engine.state.historyError == nil)
    }

    @Test func failedOrInterruptedStreamingDoesNotBecomeARecordedTurn() {
        let clock = ConversationClock()
        var failed = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { clock.now })
        _ = startTurn("What is next?", on: &failed)
        _ = failed.handle(.provider(.textDelta("An unfinished answer")))
        clock.set(1_700)
        #expect(failed.handle(.provider(.failed(.signedOut))) == [
            .saveHistory(oneTurnHistory(lastActivity: 1_700)), .showNotch(.notice("Claude Code is signed out. Run claude in Terminal to sign in."))
        ])
        #expect(failed.state.history == oneTurnHistory(lastActivity: 1_700))
        clock.set(2_299)
        #expect(failed.handle(.clockTick) == [])
        clock.set(2_300)
        #expect(failed.handle(.clockTick) == [.resetProvider, .saveHistory(oneTurnHistory(lastActivity: 1_700, endedAt: 2_300)), gearSummary])

        clock.set(1_000)
        var interrupted = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { clock.now })
        _ = startTurn("What is next?", on: &interrupted)
        _ = interrupted.handle(.provider(.textDelta("A spoken line.\nAnother")))
        clock.set(1_800)
        #expect(interrupted.handle(.interrupted) == [
            .cancelReply, .stopSpeaking, .saveHistory(oneTurnHistory(lastActivity: 1_800)), .hideBuddy, .showNotch(.idle)
        ])
        #expect(interrupted.state.history == oneTurnHistory(lastActivity: 1_800))
    }

    @Test func clearCancelsHeldAndCapturingTurnsWithoutSavingOldHistory() {
        let clock = ConversationClock()
        var held = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { clock.now })
        _ = held.handle(.pushToTalkPressed)
        clock.set(1_100)
        #expect(held.handle(.clearHistoryRequested) == [
            .stopListening, .cancelCapture, .resetProvider, .hideBuddy, .showNotch(.idle), .clearHistory
        ])
        #expect(held.handle(.transcriptFinished("late")) == [])
        #expect(held.handle(.pushToTalkReleased) == [])
        var capturing = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { Date(timeIntervalSince1970: 1_000) })
        _ = capturing.handle(.pushToTalkPressed)
        _ = capturing.handle(.pushToTalkReleased)
        _ = capturing.handle(.transcriptFinished("Where is the menu?"))
        #expect(capturing.handle(.clearHistoryRequested) == [
            .cancelCapture, .resetProvider, .hideBuddy, .showNotch(.idle), .clearHistory
        ])
        #expect(capturing.handle(.screensCaptured([])) == [])
    }

    @Test func laterCompletedTurnsAppendWithoutReplacingEarlierText() {
        var engine = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { Date(timeIntervalSince1970: 1_000) })
        _ = startTurn("Which gear?", on: &engine)
        _ = engine.handle(.provider(.textDelta("The gray one.")))
        #expect(engine.handle(.provider(.completed)) == [.saveHistory(ConversationHistory(conversations: [Conversation(turns: [
            TurnRecord(transcript: "Where are settings?", reply: "Click the gear."),
            TurnRecord(transcript: "Which gear?", reply: "The gray one.")
        ], lastActivity: Date(timeIntervalSince1970: 1_000))])), .speak("The gray one.", voice: .apple)])
    }

    @Test func aBackwardsClockDoesNotMoveTheIdleDeadlineEarlier() {
        var engine = BuddyEngine(providerConnected: true, history: oneTurnHistory(), now: { Date(timeIntervalSince1970: 900) })
        #expect(engine.handle(.clockTick) == [])
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: "")), .startListening])
        #expect(engine.handle(.interrupted) == [.stopListening, .hideBuddy, .showNotch(.idle)])
        #expect(engine.state.history == oneTurnHistory())
    }
}

final class ConversationClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000))
    var now: Date { value.withLock { $0 } }
    func set(_ seconds: TimeInterval) { value.withLock { $0 = Date(timeIntervalSince1970: seconds) } }
}

private func oneTurnHistory(lastActivity: TimeInterval = 1_000, endedAt: TimeInterval? = nil) -> ConversationHistory {
    ConversationHistory(conversations: [Conversation(
        turns: [TurnRecord(transcript: "Where are settings?", reply: "Click the gear.")],
        startedAt: Date(timeIntervalSince1970: 1_000), lastActivity: Date(timeIntervalSince1970: lastActivity), endedAt: endedAt.map { Date(timeIntervalSince1970: $0) }
    )])
}

private func startTurn(_ transcript: String, captures: [ScreenCapture] = [], on engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
    _ = engine.handle(.pushToTalkPressed)
    _ = engine.handle(.pushToTalkReleased)
    _ = engine.handle(.transcriptFinished(transcript))
    return engine.handle(.screensCaptured(captures))
}

private let gearSummary = BuddyEngine.Effect.writeSummary(SummaryRequest(
    id: 1, conversation: 0, summary: nil, turns: [TurnRecord(transcript: "Where are settings?", reply: "Click the gear.")]
))
