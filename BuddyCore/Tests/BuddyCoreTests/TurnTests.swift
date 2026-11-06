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
private let monitorAbove = ScreenCapture(
    jpeg: Data([3]), display: DisplayRect(x: 0, y: 900, width: 2560, height: 1440),
    pixelWidth: 1280, pixelHeight: 720, containsCursor: false
)
private let leftMonitorWithCursor = ScreenCapture(
    jpeg: Data([2]), display: leftMonitor.display,
    pixelWidth: 1280, pixelHeight: 720, containsCursor: true
)
private let laptopWithoutCursor = ScreenCapture(
    jpeg: Data([1]), display: laptop.display,
    pixelWidth: 1280, pixelHeight: 800, containsCursor: false
)

private struct FakePorts {
    var heard = "help"
    var screens = [laptop]
    var brain: [ProviderEvent] = []

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
        case .captureScreens: [.screensCaptured(screens)]
        case .sendTurn: brain.map { .provider($0) }
        case .speak: [.lineStarted, .lineFinished]
        default: []
        }
    }
}

private func replyingEngine(screens: [ScreenCapture] = [laptop]) -> BuddyEngine {
    var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
    _ = FakePorts(screens: screens).run([.pushToTalkPressed, .pushToTalkReleased], on: &engine)
    return engine
}

/// A one-line reply from its text to the moment the mouth starts speaking it.
private func effectsOfReply(_ reply: String, screens: [ScreenCapture] = [laptop]) -> [BuddyEngine.Effect] {
    var engine = replyingEngine(screens: screens)
    #expect(engine.handle(.provider(.textDelta(reply))) == [])
    return engine.handle(.provider(.completed)) + engine.handle(.lineStarted)
}

private func spoken(_ reply: String, pointing point: BuddyEngine.Effect? = nil) -> [BuddyEngine.Effect] {
    [savedTurn(transcript: "help", reply: reply), .speak(reply, voice: .apple), .showNotch(.line(reply))]
        + (point.map { [$0] } ?? [])
}

struct TurnTests {
    @Test func fakeBrainRunsAFullScriptedTurn() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        let ports = FakePorts(heard: "where is the wi-fi menu", brain: [
            .textDelta("[POINT:1150,12:wi-fi menu] it's in the menu bar, "),
            .textDelta("top right.\nclick it to pick a net"),
            .textDelta("work."),
            .completed
        ])
        #expect(ports.run([.pushToTalkPressed, .pushToTalkReleased], on: &engine) == [
            .showNotch(.listening(heard: "")), .startListening,
            .stopListening, .showBuddy, .showNotch(.thinking),
            .captureScreens,
            .sendTurn(TurnRequest(transcript: "where is the wi-fi menu", captures: [laptop])),
            .speak("it's in the menu bar, top right.", voice: .apple),
            savedTurn(
                transcript: "where is the wi-fi menu",
                reply: "it's in the menu bar, top right.\nclick it to pick a network."
            ),
            .showNotch(.line("it's in the menu bar, top right.")),
            .point(DisplayPoint(x: 1293.75, y: 886.5), on: laptop.display, label: "wi-fi menu"),
            .speak("click it to pick a network.", voice: .apple),
            .showNotch(.line("click it to pick a network.")),
            .hideBuddy, .showNotch(.closing)
        ])
        #expect(engine.state.turn == .idle)
        #expect(engine.state.notice == nil)
    }

    @Test func typedQuestionIsAnsweredLikeASpokenOne() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        let ports = FakePorts(brain: [
            .textDelta("[POINT:1150,12:wi-fi menu] it's in the menu bar, top right.\n"),
            .textDelta("click it to pick a network."),
            .completed
        ])
        #expect(ports.run(controlDoubleTap + [.textBoxSubmitted("where is the wi-fi menu")], on: &engine) == [
            .hideBuddy, .showTextBox,
            .hideTextBox, .showBuddy, .showNotch(.thinking),
            .captureScreens,
            .sendTurn(TurnRequest(transcript: "where is the wi-fi menu", captures: [laptop])),
            .speak("it's in the menu bar, top right.", voice: .apple),
            savedTurn(
                transcript: "where is the wi-fi menu",
                reply: "it's in the menu bar, top right.\nclick it to pick a network."
            ),
            .showNotch(.line("it's in the menu bar, top right.")),
            .point(DisplayPoint(x: 1293.75, y: 886.5), on: laptop.display, label: "wi-fi menu"),
            .speak("click it to pick a network.", voice: .apple),
            .showNotch(.line("click it to pick a network.")),
            .hideBuddy, .showNotch(.closing)
        ])
        #expect(engine.state.turn == .idle)
    }

    @Test(arguments: [
        ("[POINT:640,400:settings] click the gear.",
         spoken("click the gear.", pointing: .point(DisplayPoint(x: 720, y: 450), on: laptop.display, label: "settings"))),
        ("click the gear. [POINT:640,400:settings]",
         spoken("click the gear.", pointing: .point(DisplayPoint(x: 720, y: 450), on: laptop.display, label: "settings"))),
        ("right here [POINT:100,80]",
         spoken("right here", pointing: .point(DisplayPoint(x: 112.5, y: 810), on: laptop.display, label: nil))),
        ("[POINT:none] [POINT:640,400:save] press save",
         spoken("press save", pointing: .point(DisplayPoint(x: 720, y: 450), on: laptop.display, label: "save"))),
        ("[POINT:none] html is the skeleton of a page.", spoken("html is the skeleton of a page.")),
        ("html is the skeleton of a page. [POINT:none]", spoken("html is the skeleton of a page.")),
        ("[POINT:640,400:save] press save [POINT:100,80:cancel]",
         spoken("press save", pointing: .point(DisplayPoint(x: 720, y: 450), on: laptop.display, label: "save"))),
        ("[POINT:12,abc:file] [POINT:100,80] press save",
         spoken("press save", pointing: .point(DisplayPoint(x: 112.5, y: 810), on: laptop.display, label: nil))),
        ("it's a markup language.", spoken("it's a markup language.")),
        ("try the file menu [POINT:12,abc:file]", spoken("try the file menu")),
        ("[POINT:12,abc:file] try the file menu", spoken("try the file menu")),
        ("open the [POINT:640,400:save] menu",
         spoken("open the menu", pointing: .point(DisplayPoint(x: 720, y: 450), on: laptop.display, label: "save")))
    ])
    func pointTagFiresWhereverItSitsInItsLine(reply: String, expected: [BuddyEngine.Effect]) {
        #expect(effectsOfReply(reply) == expected)
    }

    @Test(arguments: [
        ("[POINT:640,400:x]", DisplayPoint(x: 720, y: 450)),
        ("[POINT:0,0:x]", DisplayPoint(x: 0, y: 900)),
        ("[POINT:1280,800:x]", DisplayPoint(x: 1440, y: 0)),
        ("[POINT:2000,900:x]", DisplayPoint(x: 1440, y: 0))
    ])
    func singleDisplayMapsScreenshotPixelsToDisplayPoints(tag: String, expected: DisplayPoint) {
        #expect(effectsOfReply("look " + tag).last == .point(expected, on: laptop.display, label: "x"))
    }

    @Test(arguments: [
        ("[POINT:640,360:x:screen2]", [laptop, leftMonitor], DisplayPoint(x: -960, y: 720), leftMonitor.display),
        ("[POINT:0,0:x:screen2]", [laptop, leftMonitor], DisplayPoint(x: -1920, y: 1260), leftMonitor.display),
        ("[POINT:100,50:x:screen2]", [laptop, monitorAbove], DisplayPoint(x: 200, y: 2240), monitorAbove.display),
        ("[POINT:640,400:x:screen1]", [laptop, leftMonitor], DisplayPoint(x: 720, y: 450), laptop.display),
        ("[POINT:640,400:x]", [laptop, leftMonitor], DisplayPoint(x: 720, y: 450), laptop.display),
        ("[POINT:640,400:x:screen3]", [laptop, leftMonitor], DisplayPoint(x: 720, y: 450), laptop.display),
        ("[POINT:640,360:x]", [leftMonitorWithCursor, laptopWithoutCursor], DisplayPoint(x: -960, y: 720), leftMonitor.display),
        ("[POINT:640,360:x]", [laptopWithoutCursor, leftMonitorWithCursor], DisplayPoint(x: -960, y: 720), leftMonitor.display),
        ("[POINT:640,400:x:screen2]", [leftMonitorWithCursor, laptopWithoutCursor], DisplayPoint(x: 720, y: 450), laptop.display)
    ])
    func screenNumberPicksTheDisplayAndDefaultsToTheCursorDisplay(
        tag: String, screens: [ScreenCapture], expected: DisplayPoint, display: DisplayRect
    ) {
        #expect(effectsOfReply("look " + tag, screens: screens).last == .point(expected, on: display, label: "x"))
    }

    @Test func replyDeltasSplitAnywhereAssembleOneReply() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("click the "))) == [])
        #expect(engine.handle(.provider(.textDelta("gear. [POI"))) == [])
        #expect(engine.handle(.provider(.textDelta("NT:640,400:sett"))) == [])
        #expect(engine.handle(.provider(.textDelta("ings]"))) == [])
        #expect(engine.handle(.provider(.completed)) + engine.handle(.lineStarted)
            == spoken("click the gear.", pointing: .point(DisplayPoint(x: 720, y: 450), on: laptop.display, label: "settings")))
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
    }

    @Test func firstLineIsSpokenWhileTheRestOfTheReplyStreams() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("The Wi-Fi menu is up top.\nIt's the fan"))) == [.speak("The Wi-Fi menu is up top.", voice: .apple)])
        #expect(engine.handle(.provider(.textDelta(" icon."))) == [])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("The Wi-Fi menu is up top."))])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "help", reply: "The Wi-Fi menu is up top.\nIt's the fan icon.")
        ])
        #expect(engine.handle(.provider(.textDelta("\nlate"))) == [])
        #expect(engine.handle(.provider(.completed)) == [])
        #expect(engine.handle(.lineFinished) == [.speak("It's the fan icon.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("It's the fan icon."))])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
    }

    @Test func eachLinesPointFiresWhenTheMouthStartsThatLine() {
        var engine = replyingEngine(screens: [laptop, leftMonitor])
        #expect(engine.handle(.provider(.textDelta(
            "[POINT:92,11:File menu] Open the File menu.\nPick New Folder.\n[POINT:640,360:Finder:screen2] It opens here.\n"
        ))) == [.speak("Open the File menu.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Open the File menu.")),
            .point(DisplayPoint(x: 103.5, y: 887.625), on: laptop.display, label: "File menu")
        ])
        #expect(engine.handle(.lineStarted) == [])
        #expect(engine.handle(.lineFinished) == [.speak("Pick New Folder.", voice: .apple)])
        #expect(engine.handle(.lineFinished) == [.speak("It opens here.", voice: .apple)])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "help", reply: "Open the File menu.\nPick New Folder.\nIt opens here.")
        ])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("It opens here.")),
            .point(DisplayPoint(x: -960, y: 720), on: leftMonitor.display, label: "Finder")
        ])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
    }

    @Test(arguments: [1, 2, 3, 5, 8, 21, 1_000])
    func deltasSplitAnywhereProduceTheSameBeats(chunkSize: Int) {
        let text = "[POINT:92,11:File menu] Open the File menu.\r\n\n[POINT:500,500:nowhere]\n"
            + "Then pick New Folder. [POINT:150,120:New Folder]\r\n  [POINT:none] That's it.  "
        let reply = Array(text.unicodeScalars)
        let deltas = stride(from: 0, to: reply.count, by: chunkSize).map { start in
            reply[start..<min(start + chunkSize, reply.count)].reduce(into: "") { $0.unicodeScalars.append($1) }
        }
        var engine = replyingEngine()
        #expect(deltas.flatMap { engine.handle(.provider(.textDelta($0))) } == [.speak("Open the File menu.", voice: .apple)])
        let rest: [BuddyEngine.Event] = [.provider(.completed)] + Array(repeating: [.lineStarted, .lineFinished], count: 3).flatMap { $0 }
        #expect(rest.flatMap { engine.handle($0) } == [
            savedTurn(transcript: "help", reply: "Open the File menu.\nThen pick New Folder.\nThat's it."),
            .showNotch(.line("Open the File menu.")),
            .point(DisplayPoint(x: 103.5, y: 887.625), on: laptop.display, label: "File menu"),
            .speak("Then pick New Folder.", voice: .apple),
            .showNotch(.line("Then pick New Folder.")),
            .point(DisplayPoint(x: 168.75, y: 765), on: laptop.display, label: "New Folder"),
            .speak("That's it.", voice: .apple),
            .showNotch(.line("That's it.")),
            .hideBuddy, .showNotch(.closing)
        ])
    }

    @Test(arguments: [
        ([], BuddyEngine.Event.interrupted, [BuddyEngine.Effect.cancelReply, .hideBuddy, .showNotch(.idle)]),
        ([.provider(.textDelta("Click the gear.\nThen"))], .interrupted,
         [.cancelReply, .stopSpeaking, .hideBuddy, .showNotch(.idle)]),
        ([.provider(.textDelta("Click the gear.\nThen")), .lineStarted], .interrupted,
         [.cancelReply, .stopSpeaking, .hideBuddy, .showNotch(.idle)]),
        ([.provider(.textDelta("Click the gear.\nThen")), .lineStarted], .pushToTalkPressed,
         [.cancelReply, .stopSpeaking, .showNotch(.listening(heard: "")), .startListening]),
        ([.provider(.textDelta("Click the gear.\nThen")), .lineStarted, .lineFinished], .pushToTalkPressed,
         [.cancelReply, .showNotch(.listening(heard: "")), .startListening]),
        ([.provider(.textDelta("Click the gear.\nThen")), .lineStarted, .provider(.completed)], .interrupted,
         [.stopSpeaking, .hideBuddy, .showNotch(.idle)]),
        ([.provider(.textDelta("Click the gear.\nThen")), .lineStarted, .provider(.completed), .lineFinished], .pushToTalkPressed,
         [.stopSpeaking, .showNotch(.listening(heard: "")), .startListening])
    ] as [([BuddyEngine.Event], BuddyEngine.Event, [BuddyEngine.Effect])])
    func interruptionStopsTheProviderThenTheMouthThenReturnsTheBuddy(
        before: [BuddyEngine.Event], interruption: BuddyEngine.Event, stops: [BuddyEngine.Effect]
    ) {
        var engine = replyingEngine()
        for event in before { _ = engine.handle(event) }
        #expect(engine.handle(interruption) == stops)
        let late: [BuddyEngine.Event] = [
            .lineStarted, .lineFinished, .lineFailed, .provider(.textDelta(" open General.\nDone.\n")), .lineStarted, .provider(.completed), .lineFailed, .lineFinished
        ]
        #expect(late.flatMap { engine.handle($0) } == [])
    }

    @Test func providerFailureWhileSpeakingStopsTheMouthAndShowsItsNotice() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("Click the gear.\n"))) == [.speak("Click the gear.", voice: .apple)])
        #expect(engine.handle(.provider(.failed(.error("API Error: 529 Overloaded"))))
            == [.stopSpeaking, .showNotch(.notice("Claude Code failed: API Error: 529 Overloaded"))])
        #expect(engine.handle(.lineFinished) == [])
        #expect(engine.state.turn == .idle)
    }

    @Test func turnStepsAdvanceInOrderAndIgnoreOutOfOrderEvents() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(engine.handle(.transcriptFinished("early")) == [])
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: "")), .startListening])
        #expect(engine.state.turn == .held)
        #expect(engine.handle(.screensCaptured([laptop])) == [])
        #expect(engine.handle(.pushToTalkReleased) == [.stopListening, .showBuddy, .showNotch(.thinking)])
        #expect(engine.state.turn == .transcribing)
        #expect(engine.handle(.transcriptFinished("  help \n")) == [.captureScreens])
        #expect(engine.state.turn == .capturing(transcript: "help"))
        #expect(engine.handle(.provider(.completed)) == [])
        #expect(engine.handle(.screensCaptured([laptop])) == [.sendTurn(TurnRequest(transcript: "help", captures: [laptop]))])
        #expect(engine.handle(.lineStarted) == [])
        #expect(engine.handle(.lineFinished) == [])
        #expect(engine.handle(.provider(.textDelta("ok"))) == [])
        #expect(engine.handle(.provider(.completed)) == [savedTurn(transcript: "help", reply: "ok"), .speak("ok", voice: .apple)])
    }

    @Test func silentTurnEndsWithoutCapturingTheScreen() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        let ports = FakePorts(heard: "  ")
        #expect(ports.run([.pushToTalkPressed, .pushToTalkReleased], on: &engine) == [
            .showNotch(.listening(heard: "")), .startListening, .stopListening, .showBuddy, .showNotch(.thinking),
            .hideBuddy, .showNotch(.idle)
        ])
        #expect(engine.state.turn == .idle)
    }

    @Test func replyWithOnlyATagEndsWithoutSpeaking() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("[POINT:640,400:save]"))) == [])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "help", reply: ""), .hideBuddy, .showNotch(.idle)
        ])
        #expect(engine.state.turn == .idle)
    }

    @Test func pressBeforeTheFirstLineInterruptsTheProviderAndStartsANewTurn() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("it's "))) == [])
        #expect(engine.handle(.pushToTalkPressed) == [.cancelReply, .showNotch(.listening(heard: "")), .startListening])
        #expect(engine.state.turn == .held)
        #expect(engine.handle(.provider(.textDelta("late"))) == [])
        #expect(engine.handle(.provider(.completed)) == [])
        #expect(engine.state.turn == .held)
    }

    @Test func pressDuringSpeakingStopsTheMouthAndStartsANewTurn() {
        var engine = replyingEngine()
        _ = engine.handle(.provider(.textDelta("it's up top.")))
        _ = engine.handle(.provider(.completed))
        #expect(engine.handle(.pushToTalkPressed) == [.stopSpeaking, .showNotch(.listening(heard: "")), .startListening])
        #expect(engine.handle(.lineFinished) == [])
        #expect(engine.state.turn == .held)
    }

    @Test func pressWhileWaitingForTheTranscriptOrScreensStartsANewTurn() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: "")), .startListening])
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("help"))
        #expect(engine.state.turn == .capturing(transcript: "help"))
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: "")), .startListening])
        #expect(engine.handle(.screensCaptured([laptop])) == [])
    }

    @Test func escapeStopsWhateverTheTurnIsDoing() {
        var held = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = held.handle(.pushToTalkPressed)
        #expect(held.handle(.interrupted) == [.stopListening, .hideBuddy, .showNotch(.idle)])
        #expect(held.handle(.transcriptFinished("help")) == [])
        #expect(held.handle(.pushToTalkReleased) == [])

        var transcribing = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = transcribing.handle(.pushToTalkPressed)
        _ = transcribing.handle(.pushToTalkReleased)
        #expect(transcribing.handle(.interrupted) == [.hideBuddy, .showNotch(.idle)])
        #expect(transcribing.handle(.transcriptFinished("help")) == [])

        var capturing = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = capturing.handle(.pushToTalkPressed)
        _ = capturing.handle(.pushToTalkReleased)
        _ = capturing.handle(.transcriptFinished("help"))
        #expect(capturing.handle(.interrupted) == [.hideBuddy, .showNotch(.idle)])
        #expect(capturing.handle(.screensCaptured([laptop])) == [])

        var waiting = replyingEngine()
        #expect(waiting.handle(.interrupted) == [.cancelReply, .hideBuddy, .showNotch(.idle)])
        #expect(waiting.handle(.provider(.completed)) == [])

        var speaking = replyingEngine()
        _ = speaking.handle(.provider(.textDelta("it's up top.")))
        _ = speaking.handle(.provider(.completed))
        #expect(speaking.handle(.interrupted) == [.stopSpeaking, .hideBuddy, .showNotch(.idle)])
        #expect(speaking.handle(.lineFinished) == [])
        #expect(speaking.state.turn == .idle)
        #expect(speaking.handle(.interrupted) == [])

        var noticeShowing = BuddyEngine()
        _ = noticeShowing.handle(.pushToTalkPressed)
        _ = noticeShowing.handle(.pushToTalkReleased)
        #expect(noticeShowing.handle(.interrupted) == [.hideBuddy, .showNotch(.idle)])
        #expect(noticeShowing.state.notice == nil)
        #expect(noticeShowing.handle(.noticeExpired) == [])
    }

    @Test(arguments: [
        (ProviderFailure.notInstalled, "Claude Code isn't installed. Install it and sign in, then try again."),
        (.signedOut, "Claude Code is signed out. Run claude in Terminal to sign in."),
        (.error("API Error: 529 Overloaded"), "Claude Code failed: API Error: 529 Overloaded")
    ])
    func providerFailureEndsTheTurnWithItsNotice(failure: ProviderFailure, notice: String) {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("it's "))) == [])
        #expect(engine.handle(.provider(.failed(failure))) == [.showNotch(.notice(notice))])
        #expect(engine.state.turn == .idle)
        #expect(engine.state.notice == notice)
        #expect(engine.handle(.provider(.completed)) == [])
        #expect(engine.handle(.noticeExpired) == [.hideBuddy, .showNotch(.idle)])
    }

    @Test func usageReportedMidReplyLeavesTheReplyUnchanged() {
        var engine = replyingEngine()
        let usage = ProviderUsage(
            fiveHour: UsageWindow(utilization: 0.05, resetsAt: Date(timeIntervalSince1970: 1_793_509_200)),
            sevenDay: UsageWindow(utilization: 0.23, resetsAt: Date(timeIntervalSince1970: 1_793_667_600))
        )
        #expect(engine.handle(.provider(.textDelta("click the gear. "))) == [])
        #expect(engine.handle(.provider(.usage(usage))) == [])
        #expect(engine.handle(.provider(.textDelta("[POINT:640,400:settings]"))) == [])
        #expect(engine.handle(.provider(.completed)) + engine.handle(.lineStarted)
            == spoken("click the gear.", pointing: .point(DisplayPoint(x: 720, y: 450), on: laptop.display, label: "settings")))
    }

    @Test(arguments: [
        ([laptop], [
            .text("Your owner's profile is empty. They haven't asked you to remember anything about them."),
            .text("The dock has no agent runs."),
            .text("Screen 1 of 1, 1280x800 pixels, with the cursor:"), .jpeg(Data([1])),
            .text("where is the terminal")
        ]),
        ([laptopWithoutCursor, leftMonitorWithCursor], [
            .text("Your owner's profile is empty. They haven't asked you to remember anything about them."),
            .text("The dock has no agent runs."),
            .text("Screen 1 of 2, 1280x800 pixels:"), .jpeg(Data([1])),
            .text("Screen 2 of 2, 1280x720 pixels, with the cursor:"), .jpeg(Data([2])),
            .text("where is the terminal")
        ])
    ] as [([ScreenCapture], [TurnContent])])
    func turnSentToTheProviderLabelsEachScreenInPointingOrder(screens: [ScreenCapture], content: [TurnContent]) {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        let effects = FakePorts(heard: "where is the terminal", screens: screens)
            .run([.pushToTalkPressed, .pushToTalkReleased], on: &engine)
        #expect(effects.last.flatMap { effect -> [TurnContent]? in
            guard case .sendTurn(let request) = effect else { return nil }
            return request.content
        } == content)
    }

    @Test func captureFailureEndsTheTurnWithItsNotice() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("help"))
        #expect(engine.handle(.captureFailed("No display available for capture")) == [.showNotch(.notice("No display available for capture"))])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(.screensCaptured([laptop])) == [])
        #expect(engine.handle(.captureFailed("late")) == [])
    }

    @Test func listeningFailureWhileHeldEndsTheTurnWithItsNotice() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = engine.handle(.pushToTalkPressed)
        #expect(engine.handle(.listeningFailed("On-device speech recognition is unavailable on this Mac."))
            == [.showNotch(.notice("On-device speech recognition is unavailable on this Mac."))])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(.pushToTalkReleased) == [])
    }

    @Test func lateFailureFromAnEarlierTurnLeavesTheNextTurnListening() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("help"))
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: "")), .startListening])
        #expect(engine.handle(.captureFailed("No display available for capture")) == [])
        #expect(engine.state.turn == .held)
        #expect(engine.handle(.pushToTalkReleased) == [.stopListening, .showBuddy, .showNotch(.thinking)])
        #expect(engine.handle(.listeningFailed("late")) == [])
    }

    @Test func losingInputMonitoringStopsTheEarsOfAHeldTurn() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        _ = engine.handle(.permissionsObserved(.init(inputMonitoring: .granted)))
        _ = engine.handle(.pushToTalkPressed)
        #expect(engine.handle(.permissionsObserved(.init(inputMonitoring: .notGranted)))
            == [.stopListening, .hideBuddy, .showNotch(.idle)])
        #expect(engine.state.turn == .idle)
    }
}
