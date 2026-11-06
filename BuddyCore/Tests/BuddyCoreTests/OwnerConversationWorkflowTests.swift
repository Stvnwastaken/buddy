import BuddyCore
import Foundation
import Testing

struct OwnerConversationWorkflowTests {
    enum Phase: CaseIterable, Sendable { case capturing, streaming, presenting }
    enum Departure: CaseIterable, Sendable { case pointerLeave, blur, pointerLeaveAndBlur }
    enum Cancellation: CaseIterable, Sendable { case escape, newTurn }

    private let previousTurn = TurnRecord(transcript: "What is my kite called?", reply: "Copper Finch.")

    private func engine(at phase: Phase, spoken: Bool) -> BuddyEngine {
        let date = Date(timeIntervalSince1970: 1_000)
        var engine = BuddyEngine(providerConnected: true, history: ConversationHistory(conversations: [
            Conversation(turns: [previousTurn], lastActivity: date)
        ]), spokenReplies: spoken, now: { date })
        _ = engine.handle(.notchPointerChanged(true))
        _ = engine.handle(.textBoxFocused)
        #expect(engine.handle(.textBoxSubmitted("Describe its wings.")).contains(.captureScreens))
        if phase != .capturing {
            #expect(engine.handle(.screensCaptured([])) == [.sendTurn(TurnRequest(
                transcript: "Describe its wings.", captures: [], recentTurns: [previousTurn]
            ))])
        }
        if phase == .presenting {
            _ = engine.handle(.provider(.textDelta("Its wings are gold.\n")))
            if spoken { _ = engine.handle(.lineStarted) }
            #expect(engine.state.notchConversation.entries.last == .buddy("Its wings are gold."))
        }
        return engine
    }

    @Test(arguments: Phase.allCases.flatMap { phase in Departure.allCases.map { (phase, $0) } }, [false, true])
    func leavingTheConversationKeepsCaptureStreamingAndPresentationAlive(
        path: (Phase, Departure), spoken: Bool
    ) {
        let (phase, departure) = path
        var engine = engine(at: phase, spoken: spoken)
        let beforeLeaving = engine.state.turn
        if departure != .blur { #expect(engine.handle(.notchPointerChanged(false)) == []) }
        if departure != .pointerLeave { #expect(engine.handle(.textBoxDismissed) == []) }
        #expect(engine.state.turn == beforeLeaving)
        #expect(engine.state.notchConversation.focused == false)
        if departure != .blur { #expect(engine.state.notchConversation.isOpen == false) }

        var effects: [BuddyEngine.Effect] = []
        if phase == .capturing {
            let captured = engine.handle(.screensCaptured([]))
            #expect(captured == [.sendTurn(TurnRequest(
                transcript: "Describe its wings.", captures: [], recentTurns: [previousTurn]
            ))])
            effects += captured
        }
        if phase != .presenting {
            effects += engine.handle(.provider(.textDelta("Its wings are gold.\n")))
            if spoken { effects += engine.handle(.lineStarted) }
        }
        effects += engine.handle(.provider(.textDelta("They catch the light.\n")))
        effects += engine.handle(.provider(.completed))
        effects += engine.handle(spoken ? .lineFinished : .replyLineRead)
        if spoken { effects += engine.handle(.lineStarted) }
        effects += engine.handle(spoken ? .lineFinished : .replyLineRead)

        let expectedTurns = [previousTurn, TurnRecord(
            transcript: "Describe its wings.", reply: "Its wings are gold.\nThey catch the light."
        )]
        #expect(engine.state.history.conversations.first?.turns == expectedTurns)
        #expect(engine.state.notchConversation.entries == [
            .owner("What is my kite called?"), .buddy("Copper Finch."),
            .owner("Describe its wings."), .buddy("Its wings are gold."), .buddy("They catch the light.")
        ])
        #expect(effects.contains { effect in
            if case .saveHistory(let history) = effect { return history.conversations.first?.turns == expectedTurns }
            return false
        })
        #expect(effects.contains(.cancelReply) == false)
        #expect(effects.contains(.cancelCapture) == false)
        #expect(effects.contains(.cancelReading) == false)
        #expect(effects.contains(.stopSpeaking) == false)
        #expect(engine.state.turn == .idle)
    }

    @Test(arguments: Phase.allCases.flatMap { phase in Cancellation.allCases.map { (phase, $0) } }, [false, true])
    func explicitEscOrANewTurnCancelsInsteadOfContinuingTheOldReply(
        path: (Phase, Cancellation), spoken: Bool
    ) {
        let (phase, cancellation) = path
        var engine = engine(at: phase, spoken: spoken)
        let effects = engine.handle(cancellation == .escape ? .interrupted : .pushToTalkPressed)
        #expect(engine.state.turn == (cancellation == .escape ? .idle : .held))
        #expect(effects.contains(.cancelReply) == (phase != .capturing))
        if phase == .presenting { #expect(effects.contains(spoken ? .stopSpeaking : .cancelReading)) }
        #expect(engine.handle(.screensCaptured([])) == [])
        #expect(engine.handle(.provider(.textDelta("This late answer must be ignored.\n"))) == [])
        #expect(engine.handle(.provider(.completed)) == [])
        #expect(engine.handle(.replyLineRead) == [])
        #expect(engine.handle(.lineFinished) == [])
        #expect(engine.state.history.conversations.first?.turns == [previousTurn])
        #expect(engine.state.notchConversation.entries.contains(.buddy("This late answer must be ignored.")) == false)
    }

    @Test(arguments: [Phase.capturing, .streaming], [false, true])
    func returningToTheComposerKeepsTheBackgroundReplyAlive(phase: Phase, spoken: Bool) {
        var engine = engine(at: phase, spoken: spoken)
        _ = engine.handle(.notchPointerChanged(false))
        _ = engine.handle(.textBoxDismissed)
        let background = engine.state.turn
        let focus = engine.handle(.textBoxFocused)
        #expect(engine.state.turn == background)
        #expect(engine.state.notchConversation.focused)
        #expect(focus == [.showTextBox])
        _ = engine.handle(.textBoxChanged("A follow-up draft"))
        #expect(engine.handle(.conversationsRequested) == [.hideTextBox])
        #expect(engine.state.notchConversation.page == .history)
        #expect(engine.state.notchConversation.focused == false)
        #expect(engine.state.turn == background)
        #expect(engine.handle(.conversationThreadRequested) == [])
        _ = engine.handle(.textBoxDismissed)
        #expect(engine.state.turn == background)
        #expect(engine.state.notchConversation.focused == false)
        if phase == .capturing { _ = engine.handle(.screensCaptured([])) }
        _ = engine.handle(.provider(.textDelta("Its wings are gold.\n")))
        _ = engine.handle(.provider(.completed))
        if spoken { _ = engine.handle(.lineStarted) }
        _ = engine.handle(spoken ? .lineFinished : .replyLineRead)
        #expect(engine.state.history.conversations.last?.turns.last == TurnRecord(
            transcript: "Describe its wings.", reply: "Its wings are gold."
        ))
        #expect(engine.state.notchConversation.draft == "A follow-up draft")
        #expect(engine.state.turn == .idle)
    }

    @Test func submittingTheFollowUpDraftExplicitlyReplacesTheBackgroundReply() {
        var engine = engine(at: .streaming, spoken: false)
        _ = engine.handle(.textBoxFocused)
        _ = engine.handle(.textBoxChanged("What about the tail?"))
        let submitted = engine.handle(.textBoxSubmitted("What about the tail?"))
        #expect(submitted.contains(.cancelReply))
        #expect(submitted.contains(.captureScreens))
        #expect(engine.state.notchConversation.draft == "")
        #expect(engine.state.notchConversation.focused == false)
        #expect(engine.handle(.screensCaptured([])) == [.sendTurn(TurnRequest(
            transcript: "What about the tail?", captures: [], recentTurns: [previousTurn]
        ))])
    }

    @Test func continuousHoverWaitsThreeHundredMillisecondsAndOpensWithoutTakingFocus() {
        let clock = ConversationClock()
        var engine = BuddyEngine(providerConnected: true, now: { clock.now })
        #expect(engine.handle(.notchPointerChanged(true)) == [])
        clock.set(1_000.299)
        #expect(engine.handle(.notchHoverElapsed) == [])
        #expect(engine.state.notchConversation.isOpen == false)
        #expect(engine.state.notchConversation.focused == false)
        clock.set(1_000.3)
        #expect(engine.handle(.notchHoverElapsed) == [])
        #expect(engine.state.notchConversation.isOpen == true)
        #expect(engine.state.notchConversation.focused == false)
        #expect(engine.state.turn == .idle)
    }

    @Test func leavingBeforeThreeHundredMillisecondsCancelsHoverAndReentryStartsANewFullDelay() {
        let clock = ConversationClock()
        var engine = BuddyEngine(providerConnected: true, now: { clock.now })
        _ = engine.handle(.notchPointerChanged(true))
        clock.set(1_000.15)
        _ = engine.handle(.notchPointerChanged(false))
        clock.set(1_001)
        #expect(engine.handle(.notchHoverElapsed) == [])
        #expect(engine.state.notchConversation.isOpen == false)
        _ = engine.handle(.notchPointerChanged(true))
        clock.set(1_001.299)
        #expect(engine.handle(.notchHoverElapsed) == [])
        #expect(engine.state.notchConversation.isOpen == false)
        clock.set(1_001.3)
        #expect(engine.handle(.notchHoverElapsed) == [])
        #expect(engine.state.notchConversation.isOpen == true)
        #expect(engine.state.notchConversation.focused == false)
    }
}
