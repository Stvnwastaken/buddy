import Foundation
import Testing
import BuddyCore

private let laptop = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)
private let leftMonitor = ScreenCapture(
    jpeg: Data([2]), display: DisplayRect(x: -1920, y: 180, width: 1920, height: 1080),
    pixelWidth: 1280, pixelHeight: 720, containsCursor: false
)

private let ringAroundSave = BuddyEngine.Effect.annotate(
    .shape(.ring, from: DisplayPoint(x: 675, y: 472.5), to: DisplayPoint(x: 765, y: 427.5)), on: laptop.display
)
private let insideSave = DisplayPoint(x: 720, y: 450)
private let twoLineWalkthrough = "[TARGET:600,380,680,420] Click Save.\nThen pick a folder.\n"

private func replyingEngine(
    screens: [ScreenCapture] = [laptop],
    spokenReplies: Bool = true,
    accessibility: PermissionStatus = .unknown,
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000) }
) -> BuddyEngine {
    var engine = BuddyEngine(providerConnected: true, spokenReplies: spokenReplies, now: now)
    _ = engine.handle(.permissionsObserved(PermissionSnapshot(accessibility: accessibility)))
    let start: [BuddyEngine.Event] = [.pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("help"), .screensCaptured(screens)]
    for event in start { _ = engine.handle(event) }
    return engine
}

/// An engine whose reply has spoken its target line and now waits for the click.
private func waitingEngine(
    _ reply: String = twoLineWalkthrough, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000) }
) -> BuddyEngine {
    var engine = replyingEngine(now: now)
    _ = engine.handle(.provider(.textDelta(reply)))
    _ = engine.handle(.provider(.completed))
    #expect(engine.handle(.lineStarted) == [.showNotch(.line("Click Save.")), ringAroundSave])
    #expect(engine.handle(.lineFinished) == [])
    return engine
}

private func history(_ reply: String, lastActivity: TimeInterval = 1_000) -> ConversationHistory {
    ConversationHistory(conversations: [Conversation(
        turns: [TurnRecord(transcript: "help", reply: reply)], startedAt: Date(timeIntervalSince1970: 1_000),
        lastActivity: Date(timeIntervalSince1970: lastActivity)
    )])
}

struct TargetTests {
    @Test func aTargetRingsItsBoxAndHoldsLaterLinesUntilAClickInsideIt() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta(twoLineWalkthrough))) == [.speak("Click Save.", voice: .apple)])
        #expect(engine.handle(.provider(.completed)) == [.saveHistory(history("Click Save.\nThen pick a folder."))])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Click Save.")), ringAroundSave])
        #expect(engine.handle(.lineFinished) == [])
        #expect(engine.handle(.clockTick) == [])
        #expect(engine.handle(.clicked(DisplayPoint(x: 100, y: 100))) == [])
        #expect(engine.handle(.clicked(insideSave)) == [.clearAnnotations, .speak("Then pick a folder.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Then pick a folder."))])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
    }

    @Test(arguments: [
        DisplayPoint(x: 664, y: 450), DisplayPoint(x: 776, y: 450), DisplayPoint(x: 720, y: 417),
        DisplayPoint(x: 720, y: 483), DisplayPoint(x: -720, y: 450), DisplayPoint(x: 0, y: 0)
    ])
    func clicksOutsideTheTargetDoNotReleaseIt(outside: DisplayPoint) {
        var engine = waitingEngine()
        #expect(engine.handle(.clicked(outside)) == [])
        #expect(engine.handle(.clicked(outside)) == [])
        #expect(engine.handle(.clicked(insideSave)) == [.clearAnnotations, .speak("Then pick a folder.", voice: .apple)])
    }

    @Test(arguments: [
        DisplayPoint(x: 666, y: 450), DisplayPoint(x: 774, y: 450), DisplayPoint(x: 720, y: 418),
        DisplayPoint(x: 720, y: 482), DisplayPoint(x: 765, y: 427.5), DisplayPoint(x: 720, y: 450)
    ])
    func aClickInsideTheTargetOrJustShortOfItsEdgeReleasesIt(inside: DisplayPoint) {
        var engine = waitingEngine()
        #expect(engine.handle(.clicked(inside)) == [.clearAnnotations, .speak("Then pick a folder.", voice: .apple)])
    }

    @Test func aClickOnTheTargetWhileItsLineIsSpokenLetsTheNextLineFollowAtOnce() {
        var engine = replyingEngine()
        _ = engine.handle(.provider(.textDelta(twoLineWalkthrough)))
        _ = engine.handle(.provider(.completed))
        #expect(engine.handle(.clicked(insideSave)) == [])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Click Save.")), ringAroundSave])
        #expect(engine.handle(.clicked(DisplayPoint(x: 100, y: 100))) == [])
        #expect(engine.handle(.clicked(insideSave)) == [.clearAnnotations])
        #expect(engine.handle(.clicked(insideSave)) == [])
        #expect(engine.handle(.lineFinished) == [.speak("Then pick a folder.", voice: .apple)])
    }

    @Test func aWalkthroughWithNoClickEndsPolitelyAfterAMinute() {
        let clock = ConversationClock()
        var engine = waitingEngine(now: { clock.now })
        clock.set(1_059)
        #expect(engine.handle(.clockTick) == [])
        clock.set(1_060)
        #expect(engine.handle(.clockTick) == [
            .clearAnnotations, .speak("I'll stop here. Ask me again whenever you want to keep going.", voice: .apple)
        ])
        #expect(engine.handle(.clicked(insideSave)) == [])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("I'll stop here. Ask me again whenever you want to keep going."))
        ])
        #expect(engine.handle(.lineFinished) == [
            .saveHistory(history("Click Save.\nThen pick a folder.", lastActivity: 1_060)), .hideBuddy, .showNotch(.closing)
        ])
        #expect(engine.state.turn == .idle)
        #expect(engine.state.history == history("Click Save.\nThen pick a folder.", lastActivity: 1_060))
        #expect(engine.handle(.clicked(insideSave)) == [])
    }

    @Test func aWalkthroughStillStreamingWhenItTimesOutStopsTheProvider() {
        let clock = ConversationClock()
        var engine = replyingEngine(now: { clock.now })
        _ = engine.handle(.provider(.textDelta("[TARGET:600,380,680,420] Click Save.\n")))
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.lineFinished) == [])
        clock.set(1_060)
        #expect(engine.handle(.clockTick) == [
            .cancelReply, .clearAnnotations,
            .speak("I'll stop here. Ask me again whenever you want to keep going.", voice: .apple)
        ])
        #expect(engine.handle(.provider(.textDelta("Then pick a folder.\n"))) == [])
    }

    @Test func aClickOnALastLineTargetAsksAgainWithAFreshLookAtTheScreen() {
        var engine = waitingEngine("[TARGET:600,380,680,420] Click Save.")
        #expect(engine.handle(.clicked(insideSave)) == [.clearAnnotations, .showNotch(.thinking), .captureScreens])
        #expect(engine.handle(.screensCaptured([laptop, leftMonitor])) == [.sendTurn(TurnRequest(
            transcript: "I clicked it.", captures: [laptop, leftMonitor],
            recentTurns: [TurnRecord(transcript: "help", reply: "Click Save.")]
        ))])
    }

    @Test func aClickDuringALastLineTargetAsksAgainOnceTheLineEnds() {
        var engine = replyingEngine()
        _ = engine.handle(.provider(.textDelta("[TARGET:600,380,680,420] Click Save.")))
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.clicked(insideSave)) == [.clearAnnotations])
        #expect(engine.handle(.lineFinished) == [.showNotch(.thinking), .captureScreens])
    }

    @Test(arguments: [false, true])
    func aClickOnTheLastTargetBeforeTheReplyCompletesAsksAgainOnceItDoes(duringTheLine: Bool) {
        var engine = replyingEngine()
        _ = engine.handle(.provider(.textDelta("[TARGET:600,380,680,420] Click Save.\n")))
        _ = engine.handle(.lineStarted)
        if duringTheLine {
            #expect(engine.handle(.clicked(insideSave)) == [.clearAnnotations])
            #expect(engine.handle(.lineFinished) == [])
        } else {
            #expect(engine.handle(.lineFinished) == [])
            #expect(engine.handle(.clicked(insideSave)) == [.clearAnnotations])
        }
        #expect(engine.handle(.provider(.completed)) == [
            .saveHistory(history("Click Save.")), .showNotch(.thinking), .captureScreens
        ])
        #expect(engine.handle(.screensCaptured([laptop])) == [.sendTurn(TurnRequest(
            transcript: "I clicked it.", captures: [laptop], recentTurns: [TurnRecord(transcript: "help", reply: "Click Save.")]
        ))])
    }

    @Test func aClickWhileTheProviderStillStreamsLetsLaterLinesPlayAsTheyArrive() {
        var engine = replyingEngine()
        _ = engine.handle(.provider(.textDelta("[TARGET:600,380,680,420] Click Save.\n")))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        #expect(engine.handle(.clicked(insideSave)) == [.clearAnnotations])
        #expect(engine.handle(.provider(.textDelta("Then pick a folder.\n"))) == [.speak("Then pick a folder.", voice: .apple)])
        #expect(engine.handle(.provider(.completed)) == [.saveHistory(history("Click Save.\nThen pick a folder."))])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Then pick a folder."))])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
    }

    @Test(arguments: ["Continue.", "next", "Okay!", "go on", "I did it."])
    func sayingContinueDuringPushToTalkPlaysTheHeldLines(said: String) {
        var engine = waitingEngine()
        #expect(engine.handle(.pushToTalkPressed) == [.clearAnnotations, .showNotch(.listening(heard: "")), .startListening])
        #expect(engine.handle(.pushToTalkReleased) == [.stopListening, .showBuddy, .showNotch(.thinking)])
        #expect(engine.handle(.transcriptFinished(said)) == [.speak("Then pick a folder.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Then pick a folder."))])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.history == history("Click Save.\nThen pick a folder."))
    }

    @Test func typingContinueInTheTextBoxPlaysTheHeldLines() {
        var engine = waitingEngine()
        #expect(controlDoubleTap.flatMap { engine.handle($0) } == [.showTextBox])
        #expect(engine.handle(.textBoxSubmitted("continue")) == [
            .clearAnnotations, .hideTextBox, .showBuddy, .showNotch(.thinking), .speak("Then pick a folder.", voice: .apple)
        ])
    }

    @Test func pressingPushToTalkToAskSomethingElseEndsTheWalkthrough() {
        var engine = waitingEngine()
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished("What's this button?")) == [.captureScreens])
        #expect(engine.handle(.clicked(insideSave)) == [])
        _ = engine.handle(.screensCaptured([laptop]))
        _ = engine.handle(.provider(.textDelta("That's Save.")))
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished("Continue.")) == [.captureScreens])
    }

    @Test func aClickThatAsksAgainUsesUpARunOfferFromTheSameReply() {
        var engine = replyingEngine()
        _ = engine.handle(.provider(.textDelta(
            "[RUN:Tidy the Desktop into folders] Want me to tidy it as an agent run?\n[TARGET:600,380,680,420] Or click Save first."
        )))
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.lineStarted)
        #expect(engine.state.runOffer == RunBrief(request: "Tidy the Desktop into folders", captures: [laptop]))
        _ = engine.handle(.lineFinished)
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        #expect(engine.handle(.clicked(insideSave)) == [.clearAnnotations, .showNotch(.thinking), .captureScreens])
        #expect(engine.state.runOffer == nil)
    }

    @Test func okayWithBothARunOfferAndAHeldWalkthroughPlaysTheWalkthrough() {
        var engine = replyingEngine()
        _ = engine.handle(.provider(.textDelta(
            "[RUN:Tidy the Desktop into folders] Want me to tidy it as an agent run?\n" + twoLineWalkthrough
        )))
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.lineFinished) == [])
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished("Okay.")) == [.speak("Then pick a folder.", voice: .apple)])
        #expect(engine.state.runOffer == nil)
        #expect(engine.state.runs.isEmpty)
    }

    /// "Okay" could answer either, and sending an unmeant answer to an agent run is worse than playing the next step.
    @Test func okayWithARunsQuestionWaitingPlaysTheHeldWalkthroughAndTheQuestionWaitsForTheNextTurn() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        for event: BuddyEngine.Event in [
            .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("agent, tidy the Desktop"), .screensCaptured([]),
            .lineStarted, .lineFinished, .run(RunID(1), .started(folder: "/tmp/runs/1")),
            .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("help"), .screensCaptured([laptop]),
            .provider(.textDelta(twoLineWalkthrough)), .provider(.completed), .lineStarted, .lineFinished,
            .run(RunID(1), .toolCalled(ToolCallID(1), .askOwner("Keep the old folders?", choices: []))),
            .pushToTalkPressed, .pushToTalkReleased
        ] { _ = engine.handle(event) }
        #expect(engine.handle(.transcriptFinished("Okay.")) == [.speak("Then pick a folder.", voice: .apple)])
        #expect(engine.state.runs.first?.status == .needsOwner)
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        let passedOn = "Thanks, I'll pass that on to agent run 1."
        #expect(engine.handle(.transcriptFinished("Keep them.")) == [
            .answerTool(ToolCallID(1), ToolAnswer(content: [.text("Your owner answered: Keep them.")])),
            .saveHistory(ConversationHistory(conversations: [Conversation(
                turns: [
                    TurnRecord(transcript: "agent, tidy the Desktop", reply: "On it. I'll work on that in the background."),
                    TurnRecord(transcript: "help", reply: "Click Save.\nThen pick a folder."),
                    TurnRecord(transcript: "Keep them.", reply: passedOn)
                ],
                lastActivity: Date(timeIntervalSince1970: 1_000)
            )])),
            .speak(passedOn, voice: .apple)
        ])
        #expect(engine.state.runs.first?.status == .running)
    }

    @Test func escapeWhileListeningDropsTheHeldWalkthrough() {
        var engine = waitingEngine()
        _ = engine.handle(.pushToTalkPressed)
        #expect(engine.handle(.interrupted) == [.stopListening, .hideBuddy, .showNotch(.idle)])
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished("Continue.")) == [.captureScreens])
    }

    @Test func clearingHistoryWhileListeningDropsTheHeldWalkthrough() {
        var engine = waitingEngine()
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.clearHistoryRequested)
        _ = engine.handle(.historyCleared(error: nil))
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished("Continue.")) == [.captureScreens])
    }

    @Test func escapeWhileWaitingEndsTheWalkthroughAndItsMarks() {
        var engine = waitingEngine()
        #expect(engine.handle(.interrupted) == [.clearAnnotations, .hideBuddy, .showNotch(.idle)])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(.clicked(insideSave)) == [])
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished("Continue.")) == [.captureScreens])
    }

    @Test func aWrittenReplyHoldsLaterLinesTheSameWay() {
        var engine = replyingEngine(spokenReplies: false)
        #expect(engine.handle(.provider(.textDelta(twoLineWalkthrough))) == [
            .showNotch(.line("Click Save.")), ringAroundSave, .waitForReading(.seconds(3))
        ])
        _ = engine.handle(.provider(.completed))
        #expect(engine.handle(.replyLineRead) == [])
        #expect(engine.handle(.clicked(insideSave)) == [
            .clearAnnotations, .showNotch(.line("Then pick a folder.")), .waitForReading(.seconds(3))
        ])
    }

    @Test func aTargetOnAnotherScreenRingsAndWaitsThere() {
        var engine = replyingEngine(screens: [laptop, leftMonitor])
        _ = engine.handle(.provider(.textDelta("[TARGET:540,300,740,420:screen2] [TARGET:0,0,10,10] Click it.\nNow wait.\n")))
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Click it.")),
            .annotate(.shape(.ring, from: DisplayPoint(x: -1110, y: 810), to: DisplayPoint(x: -810, y: 630)), on: leftMonitor.display)
        ])
        #expect(engine.handle(.lineFinished) == [])
        #expect(engine.handle(.clicked(DisplayPoint(x: 5, y: 895))) == [])
        #expect(engine.handle(.clicked(DisplayPoint(x: -960, y: 720))) == [.clearAnnotations, .speak("Now wait.", voice: .apple)])
    }
}

struct TypeTests {
    @Test(arguments: [
        ("[TYPE:640,400:wallpaper] I'm typing wallpaper.", "I'm typing wallpaper.", [laptop],
         BuddyEngine.Effect.type("wallpaper", at: DisplayPoint(x: 720, y: 450))),
        ("Typing it now. [TYPE:640,360: https://example.com/a:b :screen2]", "Typing it now.", [laptop, leftMonitor],
         .type("https://example.com/a:b", at: DisplayPoint(x: -960, y: 720))),
        ("[TYPE:0,0:first] Typing [TYPE:10,10:second] it.", "Typing it.", [laptop],
         .type("first", at: DisplayPoint(x: 0, y: 900)))
    ] as [(String, String, [ScreenCapture], BuddyEngine.Effect)])
    func aTypeTagTypesItsTextIntoTheFieldAtItsSpotAsItsLineStarts(
        reply: String, words: String, screens: [ScreenCapture], typing: BuddyEngine.Effect
    ) {
        var engine = replyingEngine(screens: screens, accessibility: .granted)
        #expect(engine.handle(.provider(.textDelta(reply))) == [])
        #expect(engine.handle(.provider(.completed)) == [.saveHistory(history(words)), .speak(words, voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line(words)), typing])
    }

    @Test func aTypeTagFiresAfterTheLinesPointAndMarks() {
        var engine = replyingEngine(accessibility: .granted)
        _ = engine.handle(.provider(.textDelta("[TYPE:640,400:cats] [POINT:640,400:Search] [RING:600,380,680,420] Typing cats.\n")))
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Typing cats.")), .point(insideSave, on: laptop.display, label: "Search"), ringAroundSave,
            .type("cats", at: insideSave)
        ])
    }

    @Test(arguments: [PermissionStatus.unknown, .notGranted, .denied])
    func withoutAccessibilityBuddySaysItCantTypeAndTypesNothing(accessibility: PermissionStatus) {
        var engine = replyingEngine(accessibility: accessibility)
        _ = engine.handle(.provider(.textDelta("[TYPE:640,400:wallpaper] I'm typing wallpaper.\n")))
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("I'm typing wallpaper.")),
            .showNotch(.notice("Buddy needs Accessibility permission to type for you."))
        ])
    }

    @Test func refusedTypingShowsWhyWithoutEndingTheReply() {
        var engine = replyingEngine(accessibility: .granted)
        _ = engine.handle(.provider(.textDelta("[TYPE:640,400:hunter2] Typing it.\nDone.\n")))
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.typingRefused) == [
            .showNotch(.notice("I didn't type that, because secure input is on, as in a password field."))
        ])
        #expect(engine.handle(.lineFinished) == [.speak("Done.", voice: .apple)])
    }

    @Test func refusedTypingAfterTheReplyLeavesANoticeThatExpires() {
        var engine = replyingEngine(accessibility: .granted)
        _ = engine.handle(.provider(.textDelta("[TYPE:640,400:hunter2] Typing it.")))
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        #expect(engine.handle(.typingRefused) == [
            .showNotch(.notice("I didn't type that, because secure input is on, as in a password field."))
        ])
        #expect(engine.state.notice == "I didn't type that, because secure input is on, as in a password field.")
        #expect(engine.handle(.noticeExpired) == [.hideBuddy, .showNotch(.idle)])
    }

    @Test func aWrittenReplyTypesAsItsLineIsShown() {
        var engine = replyingEngine(spokenReplies: false, accessibility: .granted)
        #expect(engine.handle(.provider(.textDelta("[TYPE:640,400:cats] Typing cats.\n"))) == [
            .showNotch(.line("Typing cats.")), .type("cats", at: insideSave), .waitForReading(.seconds(3))
        ])
    }
}
