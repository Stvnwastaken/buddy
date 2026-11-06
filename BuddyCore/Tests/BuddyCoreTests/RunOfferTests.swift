import Foundation
import Testing
import BuddyCore

private let laptop = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)
private let renameRequest = "rename the screenshots on my Desktop by date"
private let offerReply = "[RUN:Rename the screenshots on the Desktop so each name starts with its date] Want me to do that as an agent run?"
private let offeredBrief = RunBrief(request: "Rename the screenshots on the Desktop so each name starts with its date", captures: [laptop])
private let offerRecord = TurnRecord(transcript: renameRequest, reply: "Want me to do that as an agent run?")
private let confirmation = "On it. I'll work on that in the background."

private struct FakePorts {
    var heard = ""
    var replies: [String: String] = [renameRequest: offerReply]

    func run(_ events: [BuddyEngine.Event], on engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
        var queue = events
        var performed: [BuddyEngine.Effect] = []
        while !queue.isEmpty {
            let effects = engine.handle(queue.removeFirst())
            performed += effects
            queue += effects.flatMap(reactions)
        }
        return performed
    }

    private func reactions(to effect: BuddyEngine.Effect) -> [BuddyEngine.Event] {
        switch effect {
        case .stopListening: [.transcriptFinished(heard)]
        case .captureScreens: [.screensCaptured([laptop])]
        case .sendTurn(let request): [.provider(.textDelta(replies[request.transcript] ?? "Okay.")), .provider(.completed)]
        case .speak: [.lineStarted, .lineFinished]
        case .waitForReading: [.replyLineRead]
        default: []
        }
    }
}

private func say(_ heard: String, to engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
    FakePorts(heard: heard).run([.pushToTalkPressed, .pushToTalkReleased], on: &engine)
}

private func type(_ text: String, to engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
    FakePorts().run(controlDoubleTap + [.textBoxSubmitted(text)], on: &engine)
}

private func offeringEngine(spokenReplies: Bool = true, clock: ConversationClock = ConversationClock()) -> BuddyEngine {
    var engine = BuddyEngine(providerConnected: true, spokenReplies: spokenReplies, now: { clock.now })
    _ = say(renameRequest, to: &engine)
    return engine
}

/// An engine whose provider has just streamed `reply` to the rename request, before the mouth starts any line.
private func streaming(_ reply: String) -> (BuddyEngine, [BuddyEngine.Effect]) {
    var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
    _ = engine.handle(.pushToTalkPressed)
    _ = engine.handle(.pushToTalkReleased)
    _ = engine.handle(.transcriptFinished(renameRequest))
    _ = engine.handle(.screensCaptured([laptop]))
    let effects = engine.handle(.provider(.textDelta(reply)))
    return (engine, effects)
}

private func history(_ turns: [TurnRecord]) -> ConversationHistory {
    ConversationHistory(conversations: [Conversation(turns: turns, lastActivity: Date(timeIntervalSince1970: 1_000))])
}

struct RunOfferTests {
    @Test func buddyAsksAloudWhetherToDoTheOfferedBriefAsAnAgentRun() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(say(renameRequest, to: &engine) == [
            .showNotch(.listening(heard: "")), .startListening,
            .stopListening, .showBuddy, .showNotch(.thinking),
            .captureScreens,
            .sendTurn(TurnRequest(transcript: renameRequest, captures: [laptop])),
            .saveHistory(history([offerRecord])),
            .speak("Want me to do that as an agent run?", voice: .apple),
            .showNotch(.line("Want me to do that as an agent run?")),
            .hideBuddy, .showNotch(.closing)
        ])
        #expect(engine.state.runOffer == offeredBrief)
        #expect(engine.state.runs.isEmpty)
    }

    @Test func aYesOnTheNextTurnStartsTheRunWithTheOfferedBrief() {
        var engine = offeringEngine()
        #expect(say("Yes.", to: &engine) == [
            .showNotch(.listening(heard: "")), .startListening,
            .stopListening, .showBuddy, .showNotch(.thinking),
            .startRun(RunID(1), offeredBrief, .claudeCode, .auto),
            .scheduleRunTimeUp(RunID(1), seconds: 1200), .playCue(.launch),
            .saveHistory(history([offerRecord, TurnRecord(transcript: "Yes.", reply: confirmation)])),
            .speak(confirmation, voice: .apple),
            .showNotch(.line(confirmation)),
            .hideBuddy, .showNotch(.closing)
        ])
        #expect(engine.state.runs.first?.brief == offeredBrief)
        #expect(engine.state.runOffer == nil)
    }

    @Test(arguments: ["yes", "Yeah, go ahead.", "OK, do it!", "sure", "Yes please", "Go for it.", "Yep, sounds good."])
    func aTypedYesAcceptsTheOffer(answer: String) {
        var engine = offeringEngine()
        let effects = type(answer, to: &engine)
        #expect(effects.contains(.startRun(RunID(1), offeredBrief, .claudeCode, .auto)))
        #expect(!effects.contains(.captureScreens))
        #expect(engine.state.runs.first?.status == .running)
    }

    @Test func anUnrelatedRequestDropsTheOfferAndIsAnsweredAsUsual() {
        var engine = offeringEngine()
        #expect(say("what time is it", to: &engine) == [
            .showNotch(.listening(heard: "")), .startListening,
            .stopListening, .showBuddy, .showNotch(.thinking),
            .captureScreens,
            .sendTurn(TurnRequest(transcript: "what time is it", captures: [laptop], recentTurns: [offerRecord])),
            .saveHistory(history([offerRecord, TurnRecord(transcript: "what time is it", reply: "Okay.")])),
            .speak("Okay.", voice: .apple),
            .showNotch(.line("Okay.")),
            .hideBuddy, .showNotch(.closing)
        ])
        #expect(engine.state.runOffer == nil)

        let lateYes = say("yes", to: &engine)
        #expect(lateYes.contains(.captureScreens))
        #expect(!lateYes.contains { if case .startRun = $0 { true } else { false } })
        #expect(engine.state.runs.isEmpty)
    }

    @Test(arguments: ["no", "No thanks.", "yes, but only the PDFs", "what's an agent run?", "thanks", "OK, thanks.", "please", "Yes, 2", "Do it?"])
    func anythingButAYesDropsTheOffer(answer: String) {
        var engine = offeringEngine()
        let effects = type(answer, to: &engine)
        #expect(effects.contains(.captureScreens))
        #expect(!effects.contains { if case .startRun = $0 { true } else { false } })
        #expect(engine.state.runOffer == nil)
        #expect(engine.state.runs.isEmpty)
    }

    @Test func aWrittenOfferIsAcceptedTheSameWay() {
        var engine = offeringEngine(spokenReplies: false)
        #expect(engine.state.runOffer == offeredBrief)
        #expect(type("yes", to: &engine).contains(.startRun(RunID(1), offeredBrief, .claudeCode, .auto)))
    }

    @Test func anOfferCutOffBeforeItsLineIsNotKept() {
        var (engine, effects) = streaming("Sure, I can help with that.\n\(offerReply)\n")
        #expect(effects == [.speak("Sure, I can help with that.", voice: .apple)])
        _ = engine.handle(.interrupted)
        #expect(engine.state.runOffer == nil)
        #expect(say("yes", to: &engine).contains(.captureScreens))
        #expect(engine.state.runs.isEmpty)
    }

    @Test func anOfferWhoseLineNeverStartsIsNotKept() {
        var (interrupted, effects) = streaming(offerReply + "\n")
        #expect(effects == [.speak("Want me to do that as an agent run?", voice: .apple)])
        _ = interrupted.handle(.interrupted)
        #expect(interrupted.state.runOffer == nil)

        var (failed, _) = streaming(offerReply + "\n")
        #expect(failed.handle(.lineFailed) == [])
        #expect(failed.state.runOffer == nil)
        #expect(say("yes", to: &failed).contains(.captureScreens))
    }

    @Test func aTaggedLineThatDoesNotAskOffersNothing() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        let effects = FakePorts(heard: "help", replies: ["help": "[RUN:Rename the screenshots] I'll rename them now."])
            .run([.pushToTalkPressed, .pushToTalkReleased], on: &engine)
        #expect(effects.contains(.speak("I'll rename them now.", voice: .apple)))
        #expect(engine.state.runOffer == nil)
    }

    @Test func aYesByPushToTalkWhileBuddyIsStillTalkingStartsTheRun() {
        var (engine, _) = streaming(offerReply + "\nIt only takes a minute.\n")
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.pushToTalkPressed) == [.cancelReply, .stopSpeaking, .showNotch(.listening(heard: "")), .startListening])
        _ = engine.handle(.pushToTalkReleased)
        let effects = engine.handle(.transcriptFinished("yes"))
        #expect(effects.contains(.startRun(RunID(1), offeredBrief, .claudeCode, .auto)))
        #expect(!effects.contains(.captureScreens))
    }

    @Test func aLaterQuestionInTheSameReplyDropsTheOffer() {
        var (engine, _) = streaming(offerReply + "\nOr would you rather do it by hand?\n")
        _ = engine.handle(.lineStarted)
        #expect(engine.state.runOffer == offeredBrief)
        #expect(engine.handle(.lineFinished) == [.speak("Or would you rather do it by hand?", voice: .apple)])
        _ = engine.handle(.lineStarted)
        #expect(engine.state.runOffer == nil)
    }

    @Test func aLaterStatementInTheSameReplyKeepsTheOffer() {
        var (engine, _) = streaming(offerReply + "\nIt only takes a minute.\n")
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        _ = engine.handle(.lineStarted)
        #expect(engine.state.runOffer == offeredBrief)
    }

    @Test func aRunsBeatsDropAnOfferHeldBeforeThem() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = say("agent, list my open apps", to: &engine)
        _ = engine.handle(.run(RunID(1), .started(folder: "/Runs/1")))
        _ = say(renameRequest, to: &engine)
        #expect(engine.state.runOffer == offeredBrief)
        _ = engine.handle(.run(RunID(1), .toolCalled(ToolCallID(1), .showBeats("Found your apps."))))
        #expect(engine.state.runOffer == nil)
    }

    @Test func escapeOrAFailedReplyDropsAnOfferThatWasAsked() {
        var escaped = offeringEngine()
        #expect(escaped.state.runOffer == offeredBrief)
        _ = escaped.handle(.interrupted)
        #expect(escaped.state.runOffer == nil)
        #expect(say("yes", to: &escaped).contains(.captureScreens))

        var (failed, _) = streaming(offerReply + "\n")
        _ = failed.handle(.lineStarted)
        #expect(failed.state.runOffer == offeredBrief)
        _ = failed.handle(.provider(.failed(.signedOut)))
        #expect(failed.state.runOffer == nil)
        #expect(say("yes", to: &failed).contains(.captureScreens))
    }

    @Test func anOfferGoesStaleAfterTenMinutesEvenWithoutAConversation() {
        let clock = ConversationClock()
        var engine = BuddyEngine(providerConnected: true, now: { clock.now })
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished(renameRequest))
        _ = engine.handle(.screensCaptured([laptop]))
        _ = engine.handle(.provider(.textDelta(offerReply + "\n")))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished(""))
        #expect(engine.state.history == ConversationHistory())
        #expect(engine.state.runOffer == offeredBrief)
        clock.set(1_599)
        _ = engine.handle(.clockTick)
        #expect(engine.state.runOffer == offeredBrief)
        clock.set(1_600)
        _ = engine.handle(.clockTick)
        #expect(engine.state.runOffer == nil)
        let effects = say("yes", to: &engine)
        #expect(effects.contains(.captureScreens))
        #expect(!effects.contains { if case .startRun = $0 { true } else { false } })
    }

    @Test func endingTheConversationDropsTheOffer() {
        let clock = ConversationClock()
        var engine = offeringEngine(clock: clock)
        clock.set(1_600)
        #expect(engine.handle(.clockTick).contains(.resetProvider))
        #expect(engine.state.runOffer == nil)
        #expect(say("yes", to: &engine).contains(.captureScreens))
        #expect(engine.state.runs.isEmpty)
    }

    @Test func newConversationOrClearingHistoryDropsTheOffer() {
        var restarted = offeringEngine()
        #expect(say("new conversation", to: &restarted).contains(.showNotch(.notice("Started a new conversation."))))
        #expect(restarted.state.runOffer == nil)
        #expect(say("yes", to: &restarted).contains(.captureScreens))

        var cleared = offeringEngine()
        #expect(cleared.handle(.clearHistoryRequested).contains(.clearHistory))
        #expect(cleared.state.runOffer == nil)
    }

    @Test func aYesWhileAnotherRunIsGoingStartsASecondRun() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = say("agent, list my open apps", to: &engine)
        _ = say(renameRequest, to: &engine)
        #expect(say("yes", to: &engine).contains(.startRun(RunID(2), offeredBrief, .claudeCode, .auto)))
        #expect(engine.state.runs.map(\.brief.request) == ["list my open apps", offeredBrief.request])
        #expect(engine.state.runOffer == nil)
    }

    @Test func aRunsOwnBeatsNeverOfferARun() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = say("agent, list my open apps", to: &engine)
        _ = engine.handle(.run(RunID(1), .started(folder: "/Runs/1")))
        let effects = engine.handle(.run(RunID(1), .toolCalled(ToolCallID(1), .showBeats(offerReply))))
        #expect(effects.contains(.speak("Want me to do that as an agent run?", voice: .apple)))
        #expect(engine.state.runOffer == nil)
    }

    @Test(arguments: [
        ("Want me to do that as an agent run? [RUN:Sort the Downloads folder]", "Sort the Downloads folder"),
        ("[POINT:640,400:Desktop] [RUN: Tidy the Desktop ] Want me to?", "Tidy the Desktop"),
        ("[RUN:Tidy the Desktop] [RUN:Sort the Downloads folder] Want me to?", "Tidy the Desktop")
    ])
    func aLineOffersItsFirstRunTagWhereverItSits(reply: String, request: String) {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = FakePorts(heard: "help", replies: ["help": reply]).run([.pushToTalkPressed, .pushToTalkReleased], on: &engine)
        #expect(engine.state.runOffer == RunBrief(request: request, captures: [laptop]))
    }

    @Test(arguments: ["[RUN: ] Want me to?", "[RUN:Rename files: add dates] Want me to?"])
    func aRunTagWithNoBriefOrAnExtraFieldOffersNothing(reply: String) {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        let effects = FakePorts(heard: "help", replies: ["help": reply]).run([.pushToTalkPressed, .pushToTalkReleased], on: &engine)
        #expect(effects.contains(.speak("Want me to?", voice: .apple)))
        #expect(engine.state.runOffer == nil)
    }
}
