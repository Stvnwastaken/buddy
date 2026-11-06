import Foundation
import Testing
import BuddyCore

/// Screen 1 has no cursor: a 1920x1080 display captured at 1280x720. Screen 2 has the cursor: a 1440x900 display left
/// of it, captured at 1280x800.
private let main = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1920, height: 1080),
    pixelWidth: 1280, pixelHeight: 720, containsCursor: false
)
private let left = ScreenCapture(
    jpeg: Data([2]), display: DisplayRect(x: -1440, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)
private let request = "rename the photos in Photo Booth"
private let reason = "Photo Booth has no AppleScript, so I'll rename the photos in its window."
private let run1 = RunID(1)
private let noScreen = "You don't have the screen. Ask for it with begin_takeover first."
private let given = "You have the mouse and keyboard now. Your owner's own input is blocked until you call end_takeover, and they can take back control at any time."
private let ownerTookIt = "Your owner took back the screen. Ask again with begin_takeover only if you still need it."
private let gaveItForAnswer = "Buddy gave your owner the screen back so they could answer you. Ask again with begin_takeover if you still need it."
private let done = "Done. Check the result with capture_screen before you go on."

private func runningEngine(
    captures: [ScreenCapture] = [main, left], accessibility: PermissionStatus = .granted, limits: RunLimits = .standard,
    requests: [String] = [request]
) -> BuddyEngine {
    var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) }, runLimits: limits, home: "/Users/owner")
    _ = engine.handle(.permissionsObserved(PermissionSnapshot(accessibility: accessibility)))
    for (index, request) in requests.enumerated() {
        for event: BuddyEngine.Event in [
            .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("agent, \(request)"), .screensCaptured(captures),
            .lineStarted, .lineFinished, .run(RunID(index + 1), .started(folder: "/Users/owner/Library/Application Support/Buddy/Runs/\(index + 1)"))
        ] { _ = engine.handle(event) }
    }
    return engine
}

/// A run holding the screen after the owner allowed its call 1.
private func holdingEngine(
    captures: [ScreenCapture] = [main, left], limits: RunLimits = .standard, requests: [String] = [request]
) -> BuddyEngine {
    var engine = runningEngine(captures: captures, limits: limits, requests: requests)
    _ = engine.handle(call(1, .beginTakeover(reason: reason)))
    _ = engine.handle(.runTakeoverAnswered(run1, ToolCallID(1), approved: true))
    return engine
}

private func call(_ number: Int, _ tool: BuddyTool, of run: RunID = run1) -> BuddyEngine.Event {
    .run(run, .toolCalled(ToolCallID(number), tool))
}

private func screen(_ number: Int, _ action: ScreenAction<ScreenSpot>) -> BuddyEngine.Event {
    call(number, .screen(action))
}

private func spot(_ x: Int, _ y: Int, screen: Int? = nil) -> ScreenSpot {
    ScreenSpot(x: x, y: y, screen: screen)
}

private func text(_ number: Int, _ text: String) -> BuddyEngine.Effect {
    .answerTool(ToolCallID(number), ToolAnswer(content: [.text(text)]))
}

private func error(_ number: Int, _ text: String) -> BuddyEngine.Effect {
    .answerTool(ToolCallID(number), ToolAnswer(content: [.text(text)], isError: true))
}

struct TakeoverTests {
    @Test func aRequestForTheScreenWaitsOnTheCardAndNothingMovesUntilTheOwnerAllowsIt() {
        var engine = runningEngine()
        #expect(engine.handle(call(1, .beginTakeover(reason: "  \(reason)\n"))) == [.playCue(.needsOwner)])
        #expect(engine.state.runs.first?.status == .needsOwner)
        #expect(engine.state.runs.first?.asks == [.takeover(ToolCallID(1), reason: reason)])
        #expect(engine.handle(screen(2, .click(spot(640, 400), button: .left, count: 1))) == [error(2, noScreen)])
        #expect(engine.handle(screen(3, .type("hello"))) == [error(3, noScreen)])
        #expect(engine.handle(.runTakeoverAnswered(run1, ToolCallID(1), approved: true)) == [.beginTakeover(run1), text(1, given)])
        #expect(engine.state.runs.first?.status == .takingOver)
        #expect(engine.state.runs.first?.asks == [])
        #expect(engine.state.runs.first?.isActive == true)
        #expect(engine.state.runs.first?.reportDocument == nil)
    }

    @Test func anEmptyReasonIsAnErrorAndNothingWaits() {
        var engine = runningEngine()
        #expect(engine.handle(call(1, .beginTakeover(reason: " \n"))) == [
            error(1, "Say why you need the screen, so your owner can decide.")
        ])
        #expect(engine.state.runs.first?.status == .running)
    }

    @Test func aRefusalIsRecordedInTheRunNoteAndTheScreenToolsStayRefused() {
        var engine = runningEngine()
        _ = engine.handle(call(1, .updateRunNote("- [ ] Rename the photos")))
        _ = engine.handle(call(2, .beginTakeover(reason: reason)))
        #expect(engine.handle(.runTakeoverAnswered(run1, ToolCallID(2), approved: false)) == [
            .saveRunNote(run1, "- [ ] Rename the photos\n\n## Denied\n- `Take over the screen: \(reason)`: You said no.\n"),
            text(2, "Your owner said no. Don't take over the screen; finish another way or explain in your report.")
        ])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.state.runs.first?.denials == [Denial(action: "Take over the screen: \(reason)", reason: "You said no.")])
        #expect(engine.handle(screen(3, .key(KeyPress(modifiers: [.command], keyCode: 0x01)))) == [error(3, noScreen)])
        #expect(engine.handle(.runTakeoverAnswered(run1, ToolCallID(2), approved: true)) == [])
    }

    @Test func withoutAccessibilityTheOwnersYesGivesNoScreen() {
        var engine = runningEngine(accessibility: .notGranted)
        _ = engine.handle(call(1, .beginTakeover(reason: reason)))
        #expect(engine.handle(.runTakeoverAnswered(run1, ToolCallID(1), approved: true)) == [
            .showNotch(.notice("Buddy needs Accessibility permission to use the mouse and keyboard.")),
            error(1, "Buddy needs Accessibility permission to use the mouse and keyboard, so you don't have the screen. Finish another way or explain in your report.")
        ])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.handle(screen(2, .move(spot(10, 10)))) == [error(2, noScreen)])
    }

    @Test func aYesWhileAnotherRequestWaitsGivesNoScreenYet() {
        var engine = runningEngine()
        _ = engine.handle(call(1, .beginTakeover(reason: reason)))
        #expect(engine.handle(call(2, .askOwner("Which album?", choices: []))) == [])
        #expect(engine.handle(.runTakeoverAnswered(run1, ToolCallID(1), approved: true)) == [
            error(1, "Your owner allowed it, but they still have to answer your other request. Ask again with begin_takeover after that.")
        ])
        #expect(engine.state.runs.first?.status == .needsOwner)
        #expect(engine.state.runs.first?.asks == [.question(ToolCallID(2), "Which album?", choices: [])])
    }

    @Test func eachActionMapsItsPixelInTheLatestScreenshotToTheDisplay() {
        var engine = holdingEngine()
        #expect(engine.handle(screen(2, .click(spot(640, 400), button: .left, count: 1))) == [
            .act(run1, ToolCallID(2), .click(DisplayPoint(x: -720, y: 450), button: .left, count: 1))
        ])
        #expect(engine.handle(screen(3, .click(spot(200, 100, screen: 1), button: .right, count: 2))) == [
            .act(run1, ToolCallID(3), .click(DisplayPoint(x: 300, y: 930), button: .right, count: 2))
        ])
        #expect(engine.handle(screen(4, .move(spot(100, 80, screen: 2)))) == [
            .act(run1, ToolCallID(4), .move(DisplayPoint(x: -1327.5, y: 810)))
        ])
        #expect(engine.handle(screen(5, .scroll(spot(0, 0), down: -3, right: 2))) == [
            .act(run1, ToolCallID(5), .scroll(DisplayPoint(x: -1440, y: 900), down: -3, right: 2))
        ])
        #expect(engine.handle(screen(6, .type("Beach 1\nBeach 2"))) == [.act(run1, ToolCallID(6), .type("Beach 1\nBeach 2"))])
        let save = KeyPress(modifiers: [.command, .shift], keyCode: 0x01)
        #expect(engine.handle(screen(7, .key(save))) == [.act(run1, ToolCallID(7), .key(save))])
    }

    @Test func theAppsReportOfAnActionAnswersItsCall() {
        var engine = holdingEngine()
        _ = engine.handle(screen(2, .click(spot(640, 400), button: .left, count: 1)))
        #expect(engine.handle(.run(run1, .acted(ToolCallID(2), failure: nil))) == [text(2, done)])
        _ = engine.handle(screen(3, .type("secret")))
        #expect(engine.handle(.run(run1, .acted(ToolCallID(3), failure: "Secure input is on, as in a password field, so Buddy typed nothing."))) == [
            error(3, "Secure input is on, as in a password field, so Buddy typed nothing.")
        ])
        #expect(engine.state.runs.first?.status == .takingOver)
    }

    @Test func aSpotMustBeOnAScreenOfTheLatestScreenshot() {
        var engine = holdingEngine()
        #expect(engine.handle(screen(2, .click(spot(10, 10, screen: 3), button: .left, count: 1))) == [
            error(2, "Your latest screenshot has no screen 3.")
        ])
        #expect(engine.handle(screen(3, .move(spot(10, 10, screen: 0)))) == [error(3, "Your latest screenshot has no screen 0.")])
        #expect(engine.handle(screen(4, .click(spot(1280, 20), button: .left, count: 1))) == [
            error(4, "(1280, 20) is outside screen 2, which is 1280x800 pixels.")
        ])
        #expect(engine.handle(screen(5, .scroll(spot(-1, 700, screen: 1), down: 1, right: 0))) == [
            error(5, "(-1, 700) is outside screen 1, which is 1280x720 pixels.")
        ])
        #expect(engine.handle(screen(6, .move(spot(20, 720, screen: 1)))) == [
            error(6, "(20, 720) is outside screen 1, which is 1280x720 pixels.")
        ])
        #expect(engine.handle(screen(7, .type(""))) == [error(7, "There was no text to type.")])
        #expect(engine.state.runs.first?.status == .takingOver)
    }

    @Test func withoutAnyScreenshotTheRunMustCaptureFirstAndThenUsesTheFreshOne() {
        var engine = holdingEngine(captures: [])
        #expect(engine.handle(screen(2, .click(spot(10, 10), button: .left, count: 1))) == [
            error(2, "Take a screenshot with capture_screen first.")
        ])
        #expect(engine.handle(screen(3, .key(KeyPress(modifiers: [], keyCode: 0x24)))) == [
            .act(run1, ToolCallID(3), .key(KeyPress(modifiers: [], keyCode: 0x24)))
        ])
        _ = engine.handle(call(4, .captureScreen))
        _ = engine.handle(.run(run1, .screensCaptured(ToolCallID(4), [main])))
        #expect(engine.handle(screen(5, .click(spot(200, 100), button: .left, count: 3))) == [
            .act(run1, ToolCallID(5), .click(DisplayPoint(x: 300, y: 930), button: .left, count: 3))
        ])
    }

    @Test func endingTheTakeoverGivesTheScreenBack() {
        var engine = holdingEngine()
        #expect(engine.handle(call(2, .endTakeover)) == [.endTakeover(run1), text(2, "You gave the screen back to your owner.")])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.handle(screen(3, .move(spot(10, 10)))) == [error(3, noScreen)])
        #expect(engine.handle(call(4, .endTakeover)) == [text(4, "You didn't have the screen.")])
    }

    @Test func escTakesTheScreenBackAndTheRunIsToldWhy() {
        var engine = holdingEngine()
        #expect(engine.handle(.interrupted) == [.endTakeover(run1), .showNotch(.idle)])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.handle(screen(2, .click(spot(10, 10), button: .left, count: 1))) == [error(2, ownerTookIt)])
        #expect(engine.handle(.interrupted) == [])
        #expect(engine.handle(call(3, .beginTakeover(reason: reason))) == [.playCue(.needsOwner)])
        _ = engine.handle(.runTakeoverAnswered(run1, ToolCallID(3), approved: true))
        #expect(engine.handle(screen(4, .move(spot(10, 10, screen: 1)))) == [
            .act(run1, ToolCallID(4), .move(DisplayPoint(x: 15, y: 1065)))
        ])
    }

    @Test func pushToTalkTakesTheScreenBackBeforeListening() {
        var engine = holdingEngine()
        #expect(engine.handle(.pushToTalkPressed) == [.endTakeover(run1), .showNotch(.listening(heard: "")), .startListening])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.handle(screen(2, .type("hi"))) == [error(2, ownerTookIt)])
    }

    @Test func pushToTalkTakesTheScreenBackEvenWhileAlreadyHeld() {
        var engine = runningEngine()
        _ = engine.handle(call(1, .beginTakeover(reason: reason)))
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.runTakeoverAnswered(run1, ToolCallID(1), approved: true))
        #expect(engine.state.runs.first?.status == .takingOver)
        #expect(engine.handle(.pushToTalkPressed) == [.endTakeover(run1)])
        #expect(engine.state.runs.first?.status == .running)
    }

    @Test func theTextBoxDoesNotOpenDuringATakeover() {
        var engine = holdingEngine()
        #expect(controlDoubleTap.flatMap { engine.handle($0) } == [])
        #expect(engine.state.turn == .idle)
        _ = engine.handle(call(2, .endTakeover))
        #expect((controlTap(at: 1_000) + controlTap(at: 1_250)).flatMap { engine.handle($0) } == [.hideBuddy, .showNotch(.idle), .showTextBox])
    }

    @Test func anApprovalOrAQuestionGivesTheScreenBackSoTheOwnerCanAnswer() {
        var engine = holdingEngine()
        #expect(engine.handle(.run(run1, .approvalRequested(id: "r0", .read(path: "brief.md")))) == [
            .answerApproval(run1, id: "r0", .allow)
        ])
        #expect(engine.state.runs.first?.status == .takingOver)
        #expect(engine.handle(.run(run1, .approvalRequested(id: "r1", .command("rm ~/Pictures/old.jpg")))) == [
            .endTakeover(run1), .playCue(.needsOwner)
        ])
        #expect(engine.state.runs.first?.status == .needsOwner)
        #expect(engine.handle(screen(2, .move(spot(10, 10)))) == [error(2, gaveItForAnswer)])

        var asking = holdingEngine()
        #expect(asking.handle(call(2, .askOwner("Which album?", choices: ["Beach", "Home"]))) == [
            .endTakeover(run1), .playCue(.needsOwner)
        ])
        #expect(asking.state.runs.first?.asks == [.question(ToolCallID(2), "Which album?", choices: ["Beach", "Home"])])
        _ = asking.handle(.runQuestionAnswered(run1, ToolCallID(2), "Beach"))
        #expect(asking.handle(screen(3, .type("Beach"))) == [error(3, gaveItForAnswer)])
    }

    @Test func aRunThatEndsWhileHoldingTheScreenGivesItBackBeforeItStops() {
        var finishing = holdingEngine()
        #expect(finishing.handle(.run(run1, .finished(report: "Renamed 3 photos."))) == [
            .endTakeover(run1), .stopRun(run1), .saveRunReport(run1, "Asked: \(request)\n\nRenamed 3 photos.\n"), .playCue(.done)
        ])
        var failing = holdingEngine()
        #expect(failing.handle(.run(run1, .failed(.error("The run crashed.")))).first == .endTakeover(run1))
        var stopped = holdingEngine()
        #expect(stopped.handle(.runStopRequested(run1)) == [
            .endTakeover(run1), .stopRun(run1), .saveRunReport(run1, "Asked: \(request)\n\nStopped by the owner.\n")
        ])
        var timedOut = holdingEngine()
        #expect(timedOut.handle(.runTimeUp(run1)) == [
            .endTakeover(run1), .stopRun(run1), .saveRunReport(run1, "Asked: \(request)\n\nStopped at its time cap of 20 minutes.\n"),
            .playCue(.done)
        ])
        var capped = holdingEngine(limits: RunLimits(steps: 1, seconds: 60))
        #expect(capped.handle(.run(run1, .toolUsed)) == [])
        #expect(capped.handle(.run(run1, .toolUsed)) == [
            .endTakeover(run1), .stopRun(run1), .saveRunReport(run1, "Asked: \(request)\n\nStopped at its step cap of 1 step.\n"),
            .playCue(.done)
        ])
        #expect(capped.handle(.interrupted) == [.showNotch(.idle)])
    }

    @Test func whenTheAppCannotBlockInputTheTakeoverEndsWithANotice() {
        let message = "Buddy couldn't block your keyboard and mouse, so it gave the screen back."
        var engine = holdingEngine()
        #expect(engine.handle(.run(run1, .takeoverFailed(message))) == [.endTakeover(run1), .showNotch(.notice(message))])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.handle(screen(2, .move(spot(10, 10)))) == [error(2, message)])
        #expect(engine.handle(.run(run1, .takeoverFailed(message))) == [])
    }

    @Test func onlyOneRequestForTheScreenWaitsAndAHolderIsNotAskedAgain() {
        var engine = runningEngine()
        _ = engine.handle(call(1, .beginTakeover(reason: reason)))
        #expect(engine.handle(call(2, .beginTakeover(reason: "Rename them faster."))) == [
            error(2, "Your owner hasn't answered your last request for the screen yet.")
        ])
        #expect(engine.state.runs.first?.asks == [.takeover(ToolCallID(1), reason: reason)])
        _ = engine.handle(.runTakeoverAnswered(run1, ToolCallID(1), approved: true))
        #expect(engine.handle(call(3, .beginTakeover(reason: reason))) == [text(3, "You already have the mouse and keyboard.")])
        #expect(engine.state.runs.first?.status == .takingOver)
    }

    @Test func answersForAnotherRunOrAnUnknownCallDoNothing() {
        var engine = runningEngine()
        _ = engine.handle(call(1, .beginTakeover(reason: reason)))
        #expect(engine.handle(.runTakeoverAnswered(RunID(2), ToolCallID(1), approved: true)) == [])
        #expect(engine.handle(.runTakeoverAnswered(run1, ToolCallID(9), approved: true)) == [])
        #expect(engine.state.runs.first?.asks == [.takeover(ToolCallID(1), reason: reason)])
    }

    @Test func anotherRunWaitsInNeedsOwnerWhileOneHoldsTheScreen() {
        var engine = holdingEngine(requests: [request, "crop the photos in Preview"])
        let run2 = RunID(2)
        let crop = "Preview needs a drag to crop."
        #expect(engine.handle(call(7, .beginTakeover(reason: crop), of: run2)) == [.playCue(.needsOwner)])
        #expect(engine.handle(call(8, .screen(.click(spot(640, 400), button: .left, count: 1)), of: run2)) == [error(8, noScreen)])
        #expect(engine.handle(.runTakeoverAnswered(run2, ToolCallID(7), approved: true)) == [
            .showNotch(.notice("“Rename the photos in Photo Booth” is using the screen. Allow this run after it gives the screen back."))
        ])
        #expect(engine.state.runs.map(\.status) == [.takingOver, .needsOwner])
        #expect(engine.state.runs.map(\.asks) == [[], [.takeover(ToolCallID(7), reason: crop)]])
        // The owner couldn't click run 2's card while their input was blocked, so its cue plays again.
        #expect(engine.handle(call(9, .endTakeover)) == [
            .endTakeover(run1), .playCue(.needsOwner), text(9, "You gave the screen back to your owner.")
        ])
        #expect(engine.handle(.runTakeoverAnswered(run2, ToolCallID(7), approved: true)) == [.beginTakeover(run2), text(7, given)])
        #expect(engine.state.runs.map(\.status) == [.running, .takingOver])
        #expect(engine.handle(screen(10, .move(spot(10, 10)))) == [error(10, noScreen)])
        #expect(engine.handle(call(11, .screen(.move(spot(640, 400))), of: run2)) == [
            .act(run2, ToolCallID(11), .move(DisplayPoint(x: -720, y: 450)))
        ])
    }

    @Test func twoRunsAskingAtOnceBothWaitAndTheOwnerChoosesOne() {
        var engine = runningEngine(requests: [request, "crop the photos in Preview"])
        let run2 = RunID(2)
        _ = engine.handle(call(1, .beginTakeover(reason: reason)))
        #expect(engine.handle(call(2, .beginTakeover(reason: "Preview needs a drag to crop."), of: run2)) == [.playCue(.needsOwner)])
        #expect(engine.state.runs.map(\.status) == [.needsOwner, .needsOwner])
        #expect(engine.handle(.runTakeoverAnswered(run2, ToolCallID(2), approved: true)) == [.beginTakeover(run2), text(2, given)])
        #expect(engine.handle(.runTakeoverAnswered(run1, ToolCallID(1), approved: true)) == [
            .showNotch(.notice("“Crop the photos in Preview” is using the screen. Allow this run after it gives the screen back."))
        ])
        #expect(engine.state.runs.map(\.status) == [.needsOwner, .takingOver])
        // Esc also clears the notice.
        #expect(engine.handle(.interrupted) == [.endTakeover(run2), .playCue(.needsOwner), .hideBuddy, .showNotch(.idle)])
        #expect(engine.state.runs.map(\.status) == [.needsOwner, .running])
    }

    @Test func theScreenComingBackRemindsTheOwnerOfAWaitingRunUnlessTheyAreAboutToSpeakOrTheHolderEnded() {
        let crop = call(7, .beginTakeover(reason: "Preview needs a drag to crop."), of: RunID(2))
        let message = "Buddy couldn't block your keyboard and mouse, so it gave the screen back."
        var failed = holdingEngine(requests: [request, "crop the photos in Preview"])
        _ = failed.handle(crop)
        #expect(failed.handle(.run(run1, .takeoverFailed(message))) == [.endTakeover(run1), .playCue(.needsOwner), .showNotch(.notice(message))])

        var speaking = holdingEngine(requests: [request, "crop the photos in Preview"])
        _ = speaking.handle(crop)
        #expect(speaking.handle(.pushToTalkPressed) == [.endTakeover(run1), .showNotch(.listening(heard: "")), .startListening])

        // The holder's done cue already draws the owner to the dock, so the two cues don't overlap.
        var finishing = holdingEngine(requests: [request, "crop the photos in Preview"])
        _ = finishing.handle(crop)
        #expect(finishing.handle(.run(run1, .finished(report: "Renamed 3 photos."))) == [
            .endTakeover(run1), .stopRun(run1), .saveRunReport(run1, "Asked: \(request)\n\nRenamed 3 photos.\n"), .playCue(.done)
        ])
    }

    @Test func aRunStoppedMidTakeoverFreesTheScreenForAnotherRun() {
        var engine = holdingEngine(requests: [request, "crop the photos in Preview"])
        let run2 = RunID(2)
        _ = engine.handle(screen(2, .click(spot(640, 400), button: .left, count: 1)))
        #expect(engine.handle(.runStopRequested(run1)).first == .endTakeover(run1))
        #expect(engine.handle(.run(run1, .acted(ToolCallID(2), failure: nil))) == [error(2, "This run has ended.")])
        #expect(engine.handle(screen(3, .move(spot(10, 10)))) == [error(3, "This run has ended.")])
        #expect(engine.handle(.runTakeoverAnswered(run1, ToolCallID(1), approved: true)) == [])
        _ = engine.handle(call(5, .beginTakeover(reason: "Preview needs a drag to crop."), of: run2))
        #expect(engine.handle(.runTakeoverAnswered(run2, ToolCallID(5), approved: true)) == [.beginTakeover(run2), text(5, given)])
        #expect(engine.handle(call(6, .screen(.move(spot(640, 400))), of: run2)) == [
            .act(run2, ToolCallID(6), .move(DisplayPoint(x: -720, y: 450)))
        ])
    }

    @Test func theDockSummaryTellsTalkThatARunWaitsForTheScreen() throws {
        var engine = runningEngine()
        _ = engine.handle(call(1, .beginTakeover(reason: reason)))
        let effects = [.pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("How is the agent doing?"), .screensCaptured([main])]
            .flatMap { engine.handle($0) }
        let turn = try #require(effects.lazy.compactMap { if case .sendTurn(let turn) = $0 { turn } else { nil } }.first)
        #expect(turn.content[1] == .text("""
            The dock's agent runs, oldest first:

            Run 1 is waiting for the owner.
            The owner asked: \(request)
            It waits for the owner to allow or refuse it the mouse and keyboard on its card: \(reason)
            """))
    }

    @Test(arguments: [
        ("return", KeyPress(modifiers: [], keyCode: 0x24)),
        ("cmd+s", KeyPress(modifiers: [.command], keyCode: 0x01)),
        ("Shift+Tab", KeyPress(modifiers: [.shift], keyCode: 0x30)),
        ("cmd+shift+]", KeyPress(modifiers: [.command, .shift], keyCode: 0x1E)),
        (" ctrl + option + fn + F12 ", KeyPress(modifiers: [.control, .option, .function], keyCode: 0x6F)),
        ("command+opt+escape", KeyPress(modifiers: [.command, .option], keyCode: 0x35)),
        ("alt+control+left", KeyPress(modifiers: [.option, .control], keyCode: 0x7B)),
        ("enter", KeyPress(modifiers: [], keyCode: 0x4C)),
        ("delete", KeyPress(modifiers: [], keyCode: 0x33)),
        ("cmd+\\", KeyPress(modifiers: [.command], keyCode: 0x2A)),
        ("`", KeyPress(modifiers: [], keyCode: 0x32))
    ])
    func keyNamesParseToTheirKeyCodeAndModifiers(keys: String, press: KeyPress) {
        #expect(KeyPress(parsing: keys) == press)
    }

    @Test(arguments: ["", "cmd", "cmd+shift", "cmd+banana", "a+b", "cmd+", "+", "cmd++", "f13", "return+tab"])
    func anUnknownNameOrAnythingButOneKeyDoesNotParse(keys: String) {
        #expect(KeyPress(parsing: keys) == nil)
    }
}
