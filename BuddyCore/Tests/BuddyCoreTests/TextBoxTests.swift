import Testing
import BuddyCore

func controlTap(at start: Int, holding held: Int = 100) -> [BuddyEngine.Event] {
    [.modifiersChanged([.control], at: .milliseconds(start)), .modifiersChanged([], at: .milliseconds(start + held))]
}

let controlDoubleTap = controlTap(at: 0) + controlTap(at: 250)
private let opens: [BuddyEngine.Effect] = [.hideBuddy, .showTextBox]

private func typingEngine(providerConnected: Bool = true) -> BuddyEngine {
    var engine = BuddyEngine(providerConnected: providerConnected)
    for event in controlDoubleTap { _ = engine.handle(event) }
    return engine
}

struct TextBoxTests {
    @Test func doubleTappingControlOpensTheTextBox() {
        var engine = BuddyEngine(providerConnected: true)
        #expect(controlTap(at: 0).flatMap { engine.handle($0) } == [])
        #expect(controlTap(at: 250).flatMap { engine.handle($0) } == opens)
        #expect(engine.state.turn == .typing)
    }

    @Test(arguments: [
        (100, 150, 100, opens),
        (400, 150, 100, opens),
        (401, 150, 100, []),
        (100, 400, 100, opens),
        (100, 401, 100, []),
        (100, 150, 400, opens),
        (100, 150, 401, []),
        (100, 2_000, 100, [])
    ] as [(Int, Int, Int, [BuddyEngine.Effect])])
    func eachTapAndTheGapBetweenThemMustFitTheWindow(firstHeld: Int, gap: Int, secondHeld: Int, effects: [BuddyEngine.Effect]) {
        var engine = BuddyEngine(providerConnected: true)
        let taps = controlTap(at: 0, holding: firstHeld) + controlTap(at: firstHeld + gap, holding: secondHeld)
        #expect(taps.flatMap { engine.handle($0) } == effects)
    }

    @Test(arguments: [
        ("a key during the first tap",
         [.modifiersChanged([.control], at: .milliseconds(0)), .keyOrButtonPressed, .modifiersChanged([], at: .milliseconds(80))]
            + controlTap(at: 200)),
        ("a key between the taps", controlTap(at: 0) + [.keyOrButtonPressed] + controlTap(at: 250)),
        ("a click during the second tap",
         controlTap(at: 0) + [.modifiersChanged([.control], at: .milliseconds(250)), .keyOrButtonPressed,
                              .modifiersChanged([], at: .milliseconds(330))]),
        ("shift with the first tap",
         [.modifiersChanged([.control], at: .milliseconds(0)), .modifiersChanged([.control, .shift], at: .milliseconds(40)),
          .modifiersChanged([.control], at: .milliseconds(80)), .modifiersChanged([], at: .milliseconds(120))]
            + controlTap(at: 250)),
        ("shift held through both taps",
         [.modifiersChanged([.shift], at: .milliseconds(0)),
          .modifiersChanged([.shift, .control], at: .milliseconds(50)), .modifiersChanged([.shift], at: .milliseconds(150)),
          .modifiersChanged([.shift, .control], at: .milliseconds(300)), .modifiersChanged([.shift], at: .milliseconds(400)),
          .modifiersChanged([], at: .milliseconds(500))]),
        ("option tapped twice",
         [.modifiersChanged([.option], at: .milliseconds(0)), .modifiersChanged([], at: .milliseconds(100)),
          .modifiersChanged([.option], at: .milliseconds(250)), .modifiersChanged([], at: .milliseconds(350))])
    ] as [(String, [BuddyEngine.Event])])
    func tapsCombinedWithOtherKeysDoNotCount(_ combination: String, events: [BuddyEngine.Event]) {
        var engine = BuddyEngine(providerConnected: true)
        #expect(events.flatMap { engine.handle($0) } == [])
        #expect(engine.state.turn == .idle)
        #expect(controlTap(at: 2_000).flatMap { engine.handle($0) } == [])
        #expect(controlTap(at: 2_250).flatMap { engine.handle($0) } == opens)
    }

    @Test func releasingTalkThenTappingControlOnceDoesNotOpenTheBox() {
        var engine = BuddyEngine(providerConnected: true)
        #expect(engine.handle(.modifiersChanged(.control, at: .milliseconds(0))) == [])
        #expect(engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(30))) == [
            .showNotch(.listening(heard: "")), .startListening
        ])
        #expect(engine.handle(.modifiersChanged(.control, at: .milliseconds(200))) == [
            .stopListening, .showBuddy, .showNotch(.thinking)
        ])
        #expect(engine.handle(.modifiersChanged([], at: .milliseconds(260))) == [])
        #expect(controlTap(at: 400).flatMap { engine.handle($0) } == [])
        #expect(engine.state.turn == .transcribing)
        #expect(engine.handle(.transcriptFinished("")) == [.hideBuddy, .showNotch(.idle)])
        #expect(controlTap(at: 2_000).flatMap { engine.handle($0) } == [])
        #expect(controlTap(at: 2_250).flatMap { engine.handle($0) } == opens)
    }

    @Test func aThirdTapStartsANewPairAndTheNextDoubleTapClosesTheBox() {
        var engine = BuddyEngine(providerConnected: true)
        #expect(controlDoubleTap.flatMap { engine.handle($0) } == opens)
        #expect(controlTap(at: 500).flatMap { engine.handle($0) } == [])
        #expect(controlTap(at: 750).flatMap { engine.handle($0) } == [.hideTextBox])
        #expect(engine.state.turn == .idle)
    }

    @Test(arguments: [false, true])
    func anInputHeldBeforeTheFirstTapPreventsTheShortcut(releasedDuringFirstTap: Bool) {
        var engine = BuddyEngine(providerConnected: true)
        let taps: [BuddyEngine.Event] = [
            .modifiersChanged([.control], at: .milliseconds(0), otherInputHeld: true),
            .modifiersChanged([], at: .milliseconds(100), otherInputHeld: !releasedDuringFirstTap),
            .modifiersChanged([.control], at: .milliseconds(250), otherInputHeld: !releasedDuringFirstTap),
            .modifiersChanged([], at: .milliseconds(350), otherInputHeld: !releasedDuringFirstTap)
        ]
        #expect(taps.flatMap { engine.handle($0) } == [])
        #expect(engine.state.turn == .idle)
        #expect((controlTap(at: 2_000) + controlTap(at: 2_250)).flatMap { engine.handle($0) } == opens)
    }

    @Test func escapeOrClickingAwayClosesTheTextBoxWithoutAsking() {
        var escaped = typingEngine()
        #expect(escaped.handle(.interrupted) == [.hideTextBox, .hideBuddy])
        #expect(escaped.state.turn == .idle)
        #expect(escaped.handle(.textBoxSubmitted("where is the wi-fi menu")) == [])

        var dismissed = typingEngine()
        #expect(dismissed.handle(.textBoxDismissed) == [.hideTextBox])
        #expect(dismissed.state.turn == .idle)
        #expect(dismissed.handle(.textBoxSubmitted("where is the wi-fi menu")) == [])
        #expect(dismissed.handle(.textBoxDismissed) == [])
    }

    @Test func enterSendsTheTrimmedQuestionAndCapturesTheScreens() {
        var engine = typingEngine()
        #expect(engine.handle(.textBoxSubmitted(" \n ")) == [])
        #expect(engine.state.turn == .typing)
        #expect(engine.handle(.textBoxSubmitted("  where is the wi-fi menu\n")) == [
            .hideTextBox, .showBuddy, .showNotch(.thinking), .captureScreens
        ])
        #expect(engine.state.turn == .capturing(transcript: "where is the wi-fi menu"))
        #expect(engine.handle(.textBoxDismissed) == [])
        #expect(engine.state.turn == .capturing(transcript: "where is the wi-fi menu"))
    }

    @Test func aTypedQuestionWithNoProviderEndsWithANotice() {
        var engine = typingEngine(providerConnected: false)
        #expect(engine.handle(.textBoxSubmitted("help")) == [.hideTextBox, .showNotch(.notice("No provider connected."))])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(.noticeExpired) == [.hideBuddy, .showNotch(.idle)])
    }

    @Test func openingTheTextBoxPreservesAReplyAndClearsAnIdleNotice() {
        var replying = BuddyEngine(providerConnected: true)
        _ = replying.handle(.pushToTalkPressed)
        _ = replying.handle(.pushToTalkReleased)
        _ = replying.handle(.transcriptFinished("help"))
        _ = replying.handle(.screensCaptured([]))
        #expect(replying.handle(.provider(.textDelta("Click the gear.\nThen"))) == [.speak("Click the gear.", voice: .apple)])
        #expect(controlDoubleTap.flatMap { replying.handle($0) } == [.showTextBox])
        #expect(replying.handle(.lineStarted) == [.showNotch(.line("Click the gear."))])
        #expect(replying.handle(.provider(.textDelta(" open General.\n"))) == [])
        #expect(replying.state.notchConversation.focused)
        #expect(replying.handle(.lineFinished) == [.speak("Then open General.", voice: .apple)])

        var noticeShowing = BuddyEngine()
        _ = noticeShowing.handle(.pushToTalkPressed)
        _ = noticeShowing.handle(.pushToTalkReleased)
        #expect(controlDoubleTap.flatMap { noticeShowing.handle($0) } == [.hideBuddy, .showNotch(.idle), .showTextBox])
        #expect(noticeShowing.state.notice == nil)
        #expect(noticeShowing.handle(.noticeExpired) == [])
    }

    @Test func pushToTalkWhileTypingClosesTheTextBoxAndListens() {
        var engine = typingEngine()
        #expect(engine.handle(.pushToTalkPressed) == [.hideTextBox, .showNotch(.listening(heard: "")), .startListening])
        #expect(engine.state.turn == .held)
        #expect(engine.handle(.textBoxSubmitted("help")) == [])
    }
}
