import BuddyCore
import Foundation
import Testing

struct NotchConversationTests {
    @Test func clearingABlurredDraftClosesAndEscDoesNotImmediatelyReopenUnderThePointer() {
        let clock = ConversationClock()
        var engine = BuddyEngine(providerConnected: true, now: { clock.now })
        _ = engine.handle(.textBoxFocused)
        _ = engine.handle(.textBoxChanged("unfinished"))
        _ = engine.handle(.textBoxDismissed)
        _ = engine.handle(.textBoxChanged(""))
        #expect(engine.state.notchConversation.isOpen == false)
        _ = engine.handle(.notchPointerChanged(true))
        clock.set(1_001)
        _ = engine.handle(.notchHoverElapsed)
        #expect(engine.state.notchConversation.isOpen == true)
        _ = engine.handle(.interrupted)
        clock.set(1_002)
        _ = engine.handle(.notchHoverElapsed)
        #expect(engine.state.notchConversation.isOpen == false)
        #expect(engine.state.notchConversation.focused == false)
    }

    @Test func endingByIdleTimeAlsoStartsAnEmptyThread() {
        let clock = ConversationClock()
        var engine = BuddyEngine(history: ConversationHistory(conversations: [Conversation(
            turns: [TurnRecord(transcript: "hello", reply: "Hi.")], lastActivity: clock.now
        )]), now: { clock.now })
        clock.set(1_600)
        _ = engine.handle(.clockTick)
        #expect(engine.state.notchConversation.entries == [])
        #expect(engine.state.history.conversations.first?.endedAt == Date(timeIntervalSince1970: 1_600))
    }

    @Test func newConversationEndsHistoryAndRequestsItsSummaryWhileEmptyingTheThread() {
        let date = Date(timeIntervalSince1970: 1_000)
        let history = ConversationHistory(conversations: [Conversation(
            turns: [TurnRecord(transcript: "Where is Settings?", reply: "Click the gear.")], lastActivity: date
        )])
        var engine = BuddyEngine(providerConnected: true, history: history, now: { date })
        #expect(engine.state.notchConversation.entries == [.owner("Where is Settings?"), .buddy("Click the gear.")])
        _ = engine.handle(.textBoxFocused)
        _ = engine.handle(.textBoxChanged("discard this draft"))
        let effects = engine.handle(.newConversationRequested)
        #expect(engine.state.notchConversation.entries == [])
        #expect(engine.state.notchConversation.draft == "")
        #expect(engine.state.notchConversation.focused == false)
        #expect(engine.state.history.conversations.map(\.endedAt) == [date])
        #expect(effects.contains(.resetProvider))
        #expect(effects.contains(.writeSummary(SummaryRequest(
            id: 1, conversation: 0, summary: nil,
            turns: [TurnRecord(transcript: "Where is Settings?", reply: "Click the gear.")]
        ))))
    }

    @Test func repeatedLinesAndRunOffersRemainPlainTextAndReadingDoesNotDuplicateASpokenLine() {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.textBoxFocused)
        _ = engine.handle(.textBoxSubmitted("help"))
        _ = engine.handle(.screensCaptured([]))
        _ = engine.handle(.provider(.textDelta("Again.\nAgain.\n[RUN:Rename screenshots] Shall I rename them?\n")))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.spokenRepliesChanged(false))
        #expect(engine.state.notchConversation.entries == [.owner("help"), .buddy("Again.")])
        _ = engine.handle(.replyLineRead)
        _ = engine.handle(.replyLineRead)
        #expect(engine.state.notchConversation.entries == [
            .owner("help"), .buddy("Again."), .buddy("Again."), .buddy("Shall I rename them?")
        ])
        #expect(engine.state.runOffer?.request == "Rename screenshots")
        _ = engine.handle(.typingRefused)
        #expect(engine.state.notchConversation.entries.last == .notice("I didn't type that, because secure input is on, as in a password field."))
    }

    @Test func leavingBeforeTheHoverDelayCancelsOpeningAndAnEmptyBlurCloses() {
        let clock = ConversationClock()
        var engine = BuddyEngine(providerConnected: true, now: { clock.now })
        _ = engine.handle(.notchPointerChanged(true))
        _ = engine.handle(.notchPointerChanged(false))
        clock.set(1_001)
        _ = engine.handle(.notchHoverElapsed)
        #expect(engine.state.notchConversation.isOpen == false)
        _ = engine.handle(.textBoxFocused)
        #expect(engine.state.notchConversation.focused == true)
        _ = engine.handle(.textBoxDismissed)
        #expect(engine.state.notchConversation.isOpen == false)
        #expect(engine.state.notchConversation.focused == false)
    }

    @Test func voiceAndTypedTurnsShareTheThreadAndRepliesAppearOnlyWhenSpoken() {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("Where is Settings?"))
        #expect(engine.state.notchConversation.entries == [.owner("Where is Settings?")])
        _ = engine.handle(.screensCaptured([]))
        _ = engine.handle(.provider(.textDelta("Click the gear.\nThen choose Sound.\n")))
        _ = engine.handle(.provider(.completed))
        #expect(engine.state.notchConversation.entries == [.owner("Where is Settings?")])
        _ = engine.handle(.lineStarted)
        #expect(engine.state.notchConversation.entries == [.owner("Where is Settings?"), .buddy("Click the gear.")])
        _ = engine.handle(.lineFinished)
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        _ = engine.handle(.textBoxFocused)
        #expect(engine.handle(.textBoxSubmitted("  What next?  ")).contains(.captureScreens))
        #expect(engine.state.notchConversation.entries == [
            .owner("Where is Settings?"), .buddy("Click the gear."), .buddy("Then choose Sound."), .owner("What next?")
        ])
    }

    @Test func focusOrDraftKeepsTheNotchOpenButEscAlwaysClosesIt() {
        var engine = BuddyEngine(providerConnected: true)
        _ = controlDoubleTap.flatMap { engine.handle($0) }
        #expect(engine.state.notchConversation.isOpen == true)
        #expect(engine.state.notchConversation.focused == true)
        _ = engine.handle(.notchPointerChanged(false))
        #expect(engine.state.notchConversation.isOpen == true)
        _ = engine.handle(.textBoxChanged("A follow-up"))
        _ = engine.handle(.textBoxDismissed)
        #expect(engine.state.notchConversation.focused == false)
        #expect(engine.state.notchConversation.isOpen == true)
        #expect(engine.state.notchConversation.draft == "A follow-up")
        _ = engine.handle(.interrupted)
        #expect(engine.state.notchConversation.isOpen == false)
        #expect(engine.state.notchConversation.focused == false)
    }

    @Test func hoverOpensAfterTheDelayWithoutTakingFocusAndLeavingCloses() {
        let clock = ConversationClock()
        var engine = BuddyEngine(now: { clock.now })
        #expect(engine.handle(.notchPointerChanged(true)) == [])
        clock.set(1_000.14)
        _ = engine.handle(.notchHoverElapsed)
        #expect(engine.state.notchConversation.isOpen == false)
        clock.set(1_001)
        #expect(engine.handle(.notchHoverElapsed) == [])
        #expect(engine.state.notchConversation.isOpen == true)
        #expect(engine.state.notchConversation.focused == false)
        #expect(engine.state.turn == .idle)
        _ = engine.handle(.notchPointerChanged(false))
        #expect(engine.state.notchConversation.isOpen == false)
    }
}
