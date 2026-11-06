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
private let laptopWithoutCursor = ScreenCapture(
    jpeg: Data([1]), display: laptop.display,
    pixelWidth: 1280, pixelHeight: 800, containsCursor: false
)
private let leftMonitorWithCursor = ScreenCapture(
    jpeg: Data([2]), display: leftMonitor.display,
    pixelWidth: 1280, pixelHeight: 720, containsCursor: true
)
private let folder = "/Users/owner/Library/Application Support/Buddy/Runs/1"

private struct FakePorts {
    var heard = "agent, make a folder on my Desktop"

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
        case .speak: [.lineStarted, .lineFinished]
        default: []
        }
    }
}

private func runningEngine(limits: RunLimits = .standard) -> BuddyEngine {
    var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) }, runLimits: limits, home: "/Users/owner")
    _ = FakePorts().run([.pushToTalkPressed, .pushToTalkReleased], on: &engine)
    _ = engine.handle(.run(RunID(1), .started(folder: folder)))
    return engine
}

private func capturedTurn(_ transcript: String, on engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
    _ = engine.handle(.pushToTalkPressed)
    _ = engine.handle(.pushToTalkReleased)
    _ = engine.handle(.transcriptFinished(transcript))
    return FakePorts().run([.screensCaptured([laptop])], on: &engine)
}

private func spoken(_ line: String, answering transcript: String, after previous: [TurnRecord] = []) -> [BuddyEngine.Effect] {
    [.saveHistory(ConversationHistory(conversations: [Conversation(
        turns: previous + [TurnRecord(transcript: transcript, reply: line)],
        lastActivity: Date(timeIntervalSince1970: 1_000)
    )])), .speak(line, voice: .apple), .showNotch(.line(line)), .hideBuddy, .showNotch(.closing)]
}

private func showBeats(_ call: Int, _ lines: String) -> BuddyEngine.Event {
    .run(RunID(1), .toolCalled(ToolCallID(call), .showBeats(lines)))
}

struct AgentRunTests {
    @Test func aTypedAgentRequestStartsTheSameBackgroundRun() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        for event in controlDoubleTap { _ = engine.handle(event) }
        #expect(engine.handle(.textBoxSubmitted("agent, list my open apps")) == [
            .hideTextBox, .showBuddy, .showNotch(.thinking), .captureScreens
        ])
        #expect(FakePorts().run([.screensCaptured([laptop])], on: &engine) == [
            .startRun(RunID(1), RunBrief(request: "list my open apps", captures: [laptop]), .claudeCode, .auto),
            .scheduleRunTimeUp(RunID(1), seconds: 1200), .playCue(.launch)
        ] + spoken("On it. I'll work on that in the background.", answering: "agent, list my open apps"))
        #expect(engine.state.runs.first?.status == .running)
    }

    @Test func silentAgentBeatsShowAfterTheWrittenConfirmationEnds() {
        var engine = BuddyEngine(providerConnected: true, spokenReplies: false, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(capturedTurn("agent, list my open apps", on: &engine) == [
            .startRun(RunID(1), RunBrief(request: "list my open apps", captures: [laptop]), .claudeCode, .auto),
            .scheduleRunTimeUp(RunID(1), seconds: 1200), .playCue(.launch),
            savedTurn(transcript: "agent, list my open apps", reply: "On it. I'll work on that in the background."),
            .showNotch(.line("On it. I'll work on that in the background.")),
            .waitForReading(.seconds(4))
        ])
        #expect(engine.handle(.replyLineRead) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(showBeats(1, "[POINT:640,400:apps] Found the apps.")) == [
            .showBuddy,
            .showNotch(.line("Found the apps.")),
            .point(DisplayPoint(x: 720, y: 450), on: laptop.display, label: "apps"),
            .waitForReading(.seconds(3)),
            .answerTool(ToolCallID(1), ToolAnswer(content: [.text("Showing 1 line.")]))
        ])
        #expect(engine.state.runs.first?.status == .running)
    }

    @Test(arguments: [false, true])
    func agentBeatsDrawOnTheLatestCapturedScreenAndClearWithoutStoppingTheRun(spoken: Bool) {
        var engine = runningEngine()
        _ = engine.handle(.spokenRepliesChanged(spoken))
        _ = engine.handle(.run(RunID(1), .screensCaptured(ToolCallID(3), [laptop, leftMonitor])))
        let mark = BuddyEngine.Effect.annotate(
            .shape(.ring, from: DisplayPoint(x: -1110, y: 810), to: DisplayPoint(x: -810, y: 630)),
            on: leftMonitor.display
        )
        #expect(engine.handle(showBeats(4, "[RING:540,300,740,420:screen2] Here it is.")) == [
            .showBuddy
        ] + (spoken ? [.speak("Here it is.", voice: .apple)] : [
            .showNotch(.line("Here it is.")), mark, .waitForReading(.seconds(3))
        ]) + [.answerTool(ToolCallID(4), ToolAnswer(content: [.text("Showing 1 line.")]))])
        #expect(engine.handle(.lineStarted) == (spoken ? [.showNotch(.line("Here it is.")), mark] : []))
        #expect(engine.handle(spoken ? .lineFinished : .replyLineRead) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.handle(.interrupted) == [.clearAnnotations, .showNotch(.idle)])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.state.history.conversations.flatMap(\.turns) == [TurnRecord(
            transcript: "agent, make a folder on my Desktop", reply: "On it. I'll work on that in the background."
        )])
    }

    @Test func agentBeatsNeverWaitForAClickOrType() {
        var engine = runningEngine()
        _ = engine.handle(.permissionsObserved(PermissionSnapshot(accessibility: .granted)))
        _ = engine.handle(.run(RunID(1), .screensCaptured(ToolCallID(3), [laptop])))
        #expect(engine.handle(showBeats(4, "[TARGET:600,380,680,420] [TYPE:640,400:hello] Here it is.\nAnd here.")) == [
            .showBuddy, .speak("Here it is.", voice: .apple), .answerTool(ToolCallID(4), ToolAnswer(content: [.text("Showing 2 lines.")]))
        ])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Here it is."))])
        #expect(engine.handle(.lineFinished) == [.speak("And here.", voice: .apple)])
    }

    @Test func agentTurnStartsARunAndBuddyConfirmsAloud() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        let brief = RunBrief(request: "make a folder on my Desktop with a text file listing my open apps", captures: [laptop])
        let ports = FakePorts(heard: "agent, make a folder on my Desktop with a text file listing my open apps")
        #expect(ports.run([.pushToTalkPressed, .pushToTalkReleased], on: &engine) == [
            .showNotch(.listening(heard: "")), .startListening,
            .stopListening, .showBuddy, .showNotch(.thinking),
            .captureScreens,
            .startRun(RunID(1), brief, .claudeCode, .auto),
            .scheduleRunTimeUp(RunID(1), seconds: 1200), .playCue(.launch),
            savedTurn(
                transcript: "agent, make a folder on my Desktop with a text file listing my open apps",
                reply: "On it. I'll work on that in the background."
            ),
            .speak("On it. I'll work on that in the background.", voice: .apple),
            .showNotch(.line("On it. I'll work on that in the background.")),
            .hideBuddy, .showNotch(.closing)
        ])
        #expect(engine.state.turn == .idle)
        #expect(engine.state.runs.first?.id == RunID(1))
        #expect(engine.state.runs.first?.brief == brief)
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.handle(.run(RunID(1), .started(folder: folder))) == [])
        #expect(engine.state.runs.first?.folder == folder)
    }

    @Test(arguments: [
        ("Agent, make a folder on my Desktop.", "make a folder on my Desktop."),
        ("agent make a folder on my Desktop", "make a folder on my Desktop"),
        ("AGENT: make a folder on my Desktop", "make a folder on my Desktop")
    ])
    func turnThatStartsWithTheWordAgentStartsARun(transcript: String, request: String) {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(capturedTurn(transcript, on: &engine) == [
            .startRun(RunID(1), RunBrief(request: request, captures: [laptop]), .claudeCode, .auto),
            .scheduleRunTimeUp(RunID(1), seconds: 1200), .playCue(.launch)
        ] + spoken("On it. I'll work on that in the background.", answering: transcript))
    }

    @Test(arguments: ["agents are neat", "agentic coding?", "ask my agent"])
    func turnThatOnlyMentionsAnAgentGetsAReply(transcript: String) {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(capturedTurn(transcript, on: &engine) == [.sendTurn(TurnRequest(transcript: transcript, captures: [laptop]))])
        #expect(engine.state.runs.isEmpty)
    }

    @Test(arguments: ["agent", "Agent.", "agent?"])
    func agentAloneAsksWhatTheRunShouldDo(transcript: String) {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(capturedTurn(transcript, on: &engine)
            == spoken("Tell me what the agent should do right after the word agent.", answering: transcript))
        #expect(engine.state.runs.isEmpty)
    }

    @Test func secondAgentTurnStartsASecondRunWithItsOwnProcess() {
        var engine = runningEngine()
        #expect(capturedTurn("agent, open Safari", on: &engine) == [
            .startRun(RunID(2), RunBrief(request: "open Safari", captures: [laptop]), .claudeCode, .auto),
            .scheduleRunTimeUp(RunID(2), seconds: 1200), .playCue(.launch)
        ] + spoken("On it. I'll work on that in the background.", answering: "agent, open Safari", after: [
            TurnRecord(transcript: "agent, make a folder on my Desktop", reply: "On it. I'll work on that in the background.")
        ]))
        #expect(engine.state.runs.map(\.id) == [RunID(1), RunID(2)])
        #expect(engine.state.runs.map(\.status) == [.running, .running])
    }

    @Test func finishedRunIsDoneAndItsFinalMessageIsTheReport() {
        var engine = runningEngine()
        #expect(engine.handle(.run(RunID(1), .finished(report: "Made Open Apps on your Desktop. It lists 6 apps.\n"))) == [
            .stopRun(RunID(1)),
            .saveRunReport(RunID(1), "Asked: make a folder on my Desktop\n\nMade Open Apps on your Desktop. It lists 6 apps.\n"),
            .playCue(.done)
        ])
        #expect(engine.state.runs.first?.status == .done)
        #expect(engine.state.runs.first?.report == "Made Open Apps on your Desktop. It lists 6 apps.\n")
        #expect(engine.handle(.run(RunID(1), .failed(.error("socket hang up")))) == [])
        #expect(engine.state.runs.first?.status == .done)
    }

    @Test(arguments: [
        (ProviderFailure.notInstalled, "Claude Code isn't installed. Install it and sign in, then try again.",
         "Asked: make a folder on my Desktop\n\nClaude Code isn't installed. Install it and sign in, then try again.\n"),
        (.signedOut, "Claude Code is signed out. Run claude in Terminal to sign in.",
         "Asked: make a folder on my Desktop\n\nClaude Code is signed out. Run claude in Terminal to sign in.\n"),
        (.error("socket hang up"), "Claude Code failed: socket hang up",
         "Asked: make a folder on my Desktop\n\nClaude Code failed: socket hang up\n")
    ])
    func failedRunReportsItsFailure(failure: ProviderFailure, message: String, report: String) {
        var engine = runningEngine()
        #expect(engine.handle(.run(RunID(1), .failed(failure))) == [
            .stopRun(RunID(1)), .saveRunReport(RunID(1), report), .playCue(.done)
        ])
        #expect(engine.state.runs.first?.status == .failed(message))
        #expect(engine.state.runs.first?.report == nil)
    }

    @Test func ownerStopsTheRunAtOnceAndItsLateEventsAreIgnored() {
        var engine = runningEngine()
        #expect(engine.handle(.runStopRequested(RunID(2))) == [])
        #expect(engine.handle(.runTimeUp(RunID(2))) == [])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.handle(.runStopRequested(RunID(1))) == [
            .stopRun(RunID(1)), .saveRunReport(RunID(1), "Asked: make a folder on my Desktop\n\nStopped by the owner.\n")
        ])
        #expect(engine.state.runs.first?.status == .stopped(.owner))
        let late: [BuddyEngine.Event] = [
            .runStopRequested(RunID(1)),
            .runTimeUp(RunID(1)),
            .run(RunID(1), .started(folder: "/Users/owner/Desktop")),
            .run(RunID(1), .toolUsed),
            .run(RunID(1), .approvalRequested(id: "approval-1", .other(tool: "WebFetch"))),
            .run(RunID(1), .finished(report: "Made the folder.")),
            .run(RunID(1), .failed(.error("socket hang up")))
        ]
        #expect(late.flatMap { engine.handle($0) } == [])
        #expect(engine.state.runs.first?.status == .stopped(.owner))
        #expect(engine.state.runs.first?.folder == folder)
        #expect(engine.state.runs.first?.denials == [])
        #expect(engine.state.runs.first?.report == nil)
    }

    @Test(arguments: [
        (RunLimits(steps: 2, seconds: 90), "Asked: make a folder on my Desktop\n\nStopped at its step cap of 2 steps.\n"),
        (RunLimits(steps: 1, seconds: 90), "Asked: make a folder on my Desktop\n\nStopped at its step cap of 1 step.\n")
    ])
    func runThatGoesPastItsStepCapStops(limits: RunLimits, report: String) {
        var engine = runningEngine(limits: limits)
        for _ in 0..<limits.steps {
            #expect(engine.handle(.run(RunID(1), .toolUsed)) == [])
        }
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.handle(.run(RunID(1), .toolUsed)) == [.stopRun(RunID(1)), .saveRunReport(RunID(1), report), .playCue(.done)])
        #expect(engine.state.runs.first?.status == .stopped(.stepCap))
        #expect(engine.handle(.run(RunID(1), .toolUsed)) == [])
    }

    @Test(arguments: [
        (1200, "Asked: make a folder on my Desktop\n\nStopped at its time cap of 20 minutes.\n"),
        (60, "Asked: make a folder on my Desktop\n\nStopped at its time cap of 1 minute.\n"),
        (90, "Asked: make a folder on my Desktop\n\nStopped at its time cap of 90 seconds.\n"),
        (1, "Asked: make a folder on my Desktop\n\nStopped at its time cap of 1 second.\n")
    ])
    func runStopsWhenItsTimeIsUp(seconds: Int, report: String) {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) }, runLimits: RunLimits(steps: 2, seconds: seconds))
        #expect(capturedTurn("agent, make a folder on my Desktop", on: &engine).prefix(2) == [
            .startRun(RunID(1), RunBrief(request: "make a folder on my Desktop", captures: [laptop]), .claudeCode, .auto),
            .scheduleRunTimeUp(RunID(1), seconds: seconds)
        ])
        #expect(engine.handle(.runTimeUp(RunID(1))) == [.stopRun(RunID(1)), .saveRunReport(RunID(1), report), .playCue(.done)])
        #expect(engine.state.runs.first?.status == .stopped(.timeCap))
        #expect(engine.handle(.runTimeUp(RunID(1))) == [])
        #expect(engine.handle(.runStopRequested(RunID(1))) == [])
        #expect(engine.state.runs.first?.status == .stopped(.timeCap))
    }

    @Test func closingTheCardClearsOnlyARunThatHasEnded() {
        var engine = runningEngine()
        #expect(engine.handle(.runDismissed(RunID(1))) == [])
        #expect(engine.state.runs.first?.status == .running)
        _ = engine.handle(.run(RunID(1), .finished(report: "Made the folder.")))
        #expect(engine.handle(.runDismissed(RunID(2))) == [])
        #expect(engine.state.runs.first?.status == .done)
        #expect(engine.handle(.runDismissed(RunID(1))) == [])
        #expect(engine.state.runs.isEmpty)
    }

    @Test func runNoteUpdateIsSavedAndAnswered() {
        var engine = runningEngine()
        let update = BuddyEngine.Event.run(
            RunID(1), .toolCalled(ToolCallID(1), .updateRunNote("Plan: list the open apps.\nNow: writing the file."))
        )
        #expect(engine.handle(update) == [
            .saveRunNote(RunID(1), "Plan: list the open apps.\nNow: writing the file."),
            .answerTool(ToolCallID(1), ToolAnswer(content: [.text("Saved the run note.")]))
        ])
        #expect(engine.state.runs.first?.note == "Plan: list the open apps.\nNow: writing the file.")
    }

    @Test func runNoteKeepsBuddysDenialsBelowTheRunsOwnNote() {
        var engine = runningEngine()
        #expect(engine.handle(.run(RunID(1), .approvalRequested(id: "approval-1", .other(tool: "WebFetch")))) == [
            .saveRunNote(RunID(1), "## Denied\n- `WebFetch`: Buddy doesn't allow the WebFetch tool.\n"),
            .answerApproval(RunID(1), id: "approval-1", .deny("Buddy doesn't allow the WebFetch tool."))
        ])
        #expect(engine.handle(.run(RunID(1), .toolCalled(ToolCallID(2), .updateRunNote("Plan: list the open apps.\n")))) == [
            .saveRunNote(RunID(1), "Plan: list the open apps.\n\n## Denied\n- `WebFetch`: Buddy doesn't allow the WebFetch tool.\n"),
            .answerTool(ToolCallID(2), ToolAnswer(content: [.text("Saved the run note.")]))
        ])
        #expect(engine.state.runs.first?.note == "Plan: list the open apps.\n")
        #expect(engine.state.runs.first?.denials == [Denial(action: "WebFetch", reason: "Buddy doesn't allow the WebFetch tool.")])
    }

    @Test func screenCaptureToolAnswersWithEachLabeledScreenshot() {
        var engine = runningEngine()
        #expect(engine.handle(.run(RunID(1), .toolCalled(ToolCallID(3), .captureScreen)))
            == [.captureScreensForTool(RunID(1), ToolCallID(3))])
        #expect(engine.handle(.run(RunID(1), .screensCaptured(ToolCallID(3), [laptopWithoutCursor, leftMonitorWithCursor]))) == [
            .answerTool(ToolCallID(3), ToolAnswer(content: [
                .text("Screen 1 of 2, 1280x800 pixels:"), .jpeg(Data([1])),
                .text("Screen 2 of 2, 1280x720 pixels, with the cursor:"), .jpeg(Data([2]))
            ]))
        ])
    }

    @Test func failedScreenCaptureAnswersWithItsError() {
        var engine = runningEngine()
        _ = engine.handle(.run(RunID(1), .toolCalled(ToolCallID(3), .captureScreen)))
        #expect(engine.handle(.run(RunID(1), .captureFailed(ToolCallID(3), "No display available for capture"))) == [
            .answerTool(ToolCallID(3), ToolAnswer(content: [.text("No display available for capture")], isError: true))
        ])
        #expect(engine.state.runs.first?.status == .running)
    }

    @Test func runsBeatsPlayLikeAReplyWithoutRecordingATurn() {
        var engine = runningEngine()
        #expect(engine.handle(showBeats(4, "[POINT:640,400:Open Apps] Here's your new folder.\nThe list is inside.")) == [
            .showBuddy,
            .speak("Here's your new folder.", voice: .apple),
            .answerTool(ToolCallID(4), ToolAnswer(content: [.text("Showing 2 lines.")]))
        ])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Here's your new folder.")),
            .point(DisplayPoint(x: 720, y: 450), on: laptop.display, label: "Open Apps")
        ])
        #expect(engine.handle(.lineFinished) == [.speak("The list is inside.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("The list is inside."))])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
    }

    @Test func beatsPointIntoTheScreensTheRunCapturedLast() {
        var engine = runningEngine()
        _ = engine.handle(.run(RunID(1), .toolCalled(ToolCallID(3), .captureScreen)))
        _ = engine.handle(.run(RunID(1), .screensCaptured(ToolCallID(3), [laptop, leftMonitor])))
        #expect(engine.handle(showBeats(4, "[POINT:640,360:Terminal:screen2] Your terminal is over here.")) == [
            .showBuddy,
            .speak("Your terminal is over here.", voice: .apple),
            .answerTool(ToolCallID(4), ToolAnswer(content: [.text("Showing 1 line.")]))
        ])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Your terminal is over here.")),
            .point(DisplayPoint(x: -960, y: 720), on: leftMonitor.display, label: "Terminal")
        ])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
    }

    @Test(arguments: [
        ([.pushToTalkPressed], BuddyEngine.Event.pushToTalkReleased, [BuddyEngine.Effect.stopListening, .showBuddy, .showNotch(.thinking)]),
        ([.pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("what's this"), .screensCaptured([laptop])],
         .provider(.textDelta("It's your new folder.\n")), [.speak("It's your new folder.", voice: .apple)])
    ] as [([BuddyEngine.Event], BuddyEngine.Event, [BuddyEngine.Effect])])
    func beatsAreRefusedWhileTheOwnerHasATurn(
        turn: [BuddyEngine.Event], next: BuddyEngine.Event, effects: [BuddyEngine.Effect]
    ) {
        var engine = runningEngine()
        for event in turn { _ = engine.handle(event) }
        #expect(engine.handle(showBeats(4, "Here's your new folder.")) == [
            .answerTool(ToolCallID(4), ToolAnswer(
                content: [.text("Buddy is talking right now, so nothing was shown.")], isError: true
            ))
        ])
        #expect(engine.handle(next) == effects)
    }

    @Test(arguments: ["", "[POINT:640,400:folder]\n  \n"])
    func beatsWithNoWordsShowNothing(lines: String) {
        var engine = runningEngine()
        #expect(engine.handle(showBeats(4, lines)) == [
            .answerTool(ToolCallID(4), ToolAnswer(content: [.text("There were no lines to show.")], isError: true))
        ])
        #expect(engine.state.turn == .idle)
    }

    @Test(arguments: [
        (BuddyEngine.Event.pushToTalkPressed, [BuddyEngine.Effect.stopSpeaking, .showNotch(.listening(heard: "")), .startListening],
         BuddyEngine.TurnPhase.held),
        (.interrupted, [.stopSpeaking, .hideBuddy, .showNotch(.idle)], .idle)
    ])
    func pushToTalkOrEscapeCutsOffARunsBeats(
        interruption: BuddyEngine.Event, stops: [BuddyEngine.Effect], phase: BuddyEngine.TurnPhase
    ) {
        var engine = runningEngine()
        _ = engine.handle(showBeats(4, "Here's your new folder.\nThe list is inside."))
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(interruption) == stops)
        #expect(engine.state.turn == phase)
        #expect([BuddyEngine.Event.lineFinished, .lineStarted, .lineFinished].flatMap { engine.handle($0) } == [])
        #expect(engine.state.runs.first?.status == .running)
    }

    @Test func beatsTakeThePlaceOfANoticeOnScreen() {
        var engine = runningEngine()
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("what's this"))
        #expect(engine.handle(.captureFailed("No display available for capture")) == [.showNotch(.notice("No display available for capture"))])
        #expect(engine.handle(showBeats(4, "Here's your new folder.")) == [
            .showBuddy,
            .speak("Here's your new folder.", voice: .apple),
            .answerTool(ToolCallID(4), ToolAnswer(content: [.text("Showing 1 line.")]))
        ])
        #expect(engine.state.notice == nil)
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.handle(.noticeExpired) == [])
    }

    private static let finishedRun: [BuddyEngine.Effect] = [
        .stopRun(RunID(1)), .saveRunReport(RunID(1), "Asked: make a folder on my Desktop\n\nMade the folder.\n"),
        .playCue(.done)
    ]

    @Test func aWrittenLineARunShowsEndsLikeASpokenOneAndLeavesNothingForTheRunsEnd() {
        var engine = runningEngine()
        _ = engine.handle(.spokenRepliesChanged(false))
        _ = engine.handle(showBeats(4, "[POINT:640,400:Open Apps] Here's your new folder."))
        #expect(engine.handle(.replyLineRead) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)

        #expect(engine.handle(.run(RunID(1), .finished(report: "Made the folder."))) == Self.finishedRun)
        #expect(engine.state.turn == .idle)
    }

    @Test func marksARunLeftOnScreenGoWhenTheRunEnds() {
        var engine = runningEngine()
        _ = engine.handle(.run(RunID(1), .screensCaptured(ToolCallID(3), [laptop])))
        _ = engine.handle(showBeats(4, "[RING:540,300,740,420] Here it is."))
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])

        #expect(engine.handle(.run(RunID(1), .finished(report: "Made the folder."))) == Self.finishedRun + [.clearAnnotations])
        #expect(engine.handle(.interrupted) == [.showNotch(.idle)])
    }

    @Test(arguments: [true, false])
    func aRunsLastLineStillPlayingFinishesThenGoes(spoken: Bool) {
        var engine = runningEngine()
        _ = engine.handle(.spokenRepliesChanged(spoken))
        _ = engine.handle(.run(RunID(1), .screensCaptured(ToolCallID(3), [laptop])))
        _ = engine.handle(showBeats(4, "[RING:540,300,740,420] All done."))
        _ = engine.handle(.lineStarted)

        #expect(engine.handle(.run(RunID(1), .finished(report: "Made the folder."))) == Self.finishedRun)
        #expect(engine.handle(spoken ? .lineFinished : .replyLineRead) == [.clearAnnotations, .hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
    }

    @Test(arguments: [true, false])
    func aRunClosedWhileItsLastLinePlaysStillLeavesTheScreen(spoken: Bool) {
        var engine = runningEngine()
        _ = engine.handle(.spokenRepliesChanged(spoken))
        _ = engine.handle(.run(RunID(1), .screensCaptured(ToolCallID(3), [laptop])))
        _ = engine.handle(showBeats(4, "[RING:540,300,740,420] All done."))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.run(RunID(1), .finished(report: "Made the folder.")))

        #expect(engine.handle(.runDismissed(RunID(1))) == [])
        #expect(engine.handle(spoken ? .lineFinished : .replyLineRead) == [.clearAnnotations, .hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
    }

    @Test func theOwnersOwnTurnStaysWhenARunEnds() {
        var engine = runningEngine()
        _ = engine.handle(.spokenRepliesChanged(false))
        _ = engine.handle(showBeats(4, "Here's your new folder."))
        _ = engine.handle(.replyLineRead)
        _ = capturedTurn("what's this", on: &engine)
        _ = engine.handle(.provider(.textDelta("It's your new folder.\n")))
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.replyLineRead)
        #expect(engine.state.turn == .idle)

        #expect(engine.handle(.run(RunID(1), .finished(report: "Made the folder."))) == Self.finishedRun)
        #expect(engine.state.turn == .idle)
    }

    @Test func toolCallsOfARunThatHasEndedAreStillAnswered() {
        var engine = runningEngine()
        let ended = ToolAnswer(content: [.text("This run has ended.")], isError: true)
        #expect(engine.handle(.run(RunID(2), .toolCalled(ToolCallID(1), .updateRunNote("Plan: open Safari."))))
            == [.answerTool(ToolCallID(1), ended)])
        #expect(engine.state.runs.first?.note == "")
        _ = engine.handle(.run(RunID(1), .toolCalled(ToolCallID(2), .captureScreen)))
        _ = engine.handle(.runStopRequested(RunID(1)))
        let late: [BuddyEngine.Event] = [
            .run(RunID(1), .screensCaptured(ToolCallID(2), [laptop, leftMonitor])),
            .run(RunID(1), .captureFailed(ToolCallID(3), "No display available for capture")),
            .run(RunID(1), .toolCalled(ToolCallID(4), .captureScreen)),
            .run(RunID(1), .toolCalled(ToolCallID(5), .updateRunNote("Plan: list the open apps."))),
            showBeats(6, "Here's your new folder.")
        ]
        #expect(late.flatMap { engine.handle($0) } == [
            .answerTool(ToolCallID(2), ended),
            .answerTool(ToolCallID(3), ended),
            .answerTool(ToolCallID(4), ended),
            .answerTool(ToolCallID(5), ended),
            .answerTool(ToolCallID(6), ended)
        ])
        #expect(engine.state.runs.first?.note == "")
        #expect(engine.state.turn == .idle)
        _ = engine.handle(.runDismissed(RunID(1)))
        #expect(engine.handle(.run(RunID(1), .toolCalled(ToolCallID(7), .captureScreen))) == [.answerTool(ToolCallID(7), ended)])
    }
}
