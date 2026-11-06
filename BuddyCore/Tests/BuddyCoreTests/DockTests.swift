import Foundation
import Testing
import BuddyCore

private let laptop = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)
private let sendLunchEmail = #"osascript -e 'tell application "Mail" to send (make new outgoing message with properties {subject:"Lunch", content:"Noon?", visible:false})'"#
private let emptyProfile = "Your owner's profile is empty. They haven't asked you to remember anything about them."

/// One spoken turn, with Buddy's one-line answer played to its end when there is one, as the app's ports would.
private func say(_ transcript: String, to engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
    var effects = engine.handle(.pushToTalkPressed) + engine.handle(.pushToTalkReleased)
        + engine.handle(.transcriptFinished(transcript))
    if effects.contains(.captureScreens) { effects += engine.handle(.screensCaptured([laptop])) }
    if effects.contains(where: { if case .speak = $0 { true } else { false } }) {
        effects += engine.handle(.lineStarted) + engine.handle(.lineFinished)
    }
    return effects
}

private func dockedEngine(_ requests: [String]) -> BuddyEngine {
    var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) }, home: "/Users/owner")
    for (index, request) in requests.enumerated() {
        _ = say("agent, \(request)", to: &engine)
        _ = engine.handle(.run(RunID(index + 1), .started(folder: "/Runs/\(index + 1)")))
    }
    return engine
}

private func note(_ run: Int, _ call: Int, _ text: String) -> BuddyEngine.Event {
    .run(RunID(run), .toolCalled(ToolCallID(call), .updateRunNote(text)))
}

private func question(_ run: Int, _ call: Int, _ text: String) -> BuddyEngine.Event {
    .run(RunID(run), .toolCalled(ToolCallID(call), .askOwner(text, choices: [])))
}

private func answered(_ call: Int, _ text: String) -> BuddyEngine.Effect {
    .answerTool(ToolCallID(call), ToolAnswer(content: [.text("Your owner answered: \(text)")]))
}

/// The turn a talk question sends to the provider.
private func sentTurn(of effects: [BuddyEngine.Effect]) -> TurnRequest? {
    effects.lazy.compactMap { if case .sendTurn(let turn) = $0 { turn } else { nil } }.first
}

struct DockTests {
    @Test func twoRunsWorkAtOnceAndOneStopsFromItsCardWhileTheOtherFinishes() {
        var engine = dockedEngine(["email Sam about lunch", "rename the screenshots on my Desktop"])
        #expect(engine.state.runs.map(\.id) == [RunID(1), RunID(2)])
        #expect(engine.state.runs.map(\.folder) == ["/Runs/1", "/Runs/2"])

        #expect(engine.handle(note(2, 1, "# Rename screenshots\n- [ ] Find them")) == [
            .saveRunNote(RunID(2), "# Rename screenshots\n- [ ] Find them"),
            .answerTool(ToolCallID(1), ToolAnswer(content: [.text("Saved the run note.")]))
        ])
        #expect(engine.handle(.run(RunID(1), .approvalRequested(id: "r1", .command(sendLunchEmail)))) == [.playCue(.needsOwner)])
        #expect(engine.state.runs.map(\.name) == ["Email Sam about lunch", "Rename screenshots"])
        #expect(engine.state.runs.map(\.noteBody) == ["", "- [ ] Find them"])
        #expect(engine.state.runs.map(\.status) == [.needsOwner, .running])

        #expect(engine.handle(.runStopRequested(RunID(2))) == [
            .stopRun(RunID(2)), .saveRunReport(RunID(2), "Asked: rename the screenshots on my Desktop\n\nStopped by the owner.\n")
        ])
        #expect(engine.state.runs.map(\.status) == [.needsOwner, .stopped(.owner)])
        #expect(engine.handle(.run(RunID(2), .toolCalled(ToolCallID(2), .captureScreen))) == [
            .answerTool(ToolCallID(2), ToolAnswer(content: [.text("This run has ended.")], isError: true))
        ])

        #expect(engine.handle(.runApprovalAnswered(RunID(1), request: "r1", approved: true)) == [
            .answerApproval(RunID(1), id: "r1", .allow)
        ])
        #expect(engine.handle(.run(RunID(1), .finished(report: "Sent Sam the lunch email."))) == [
            .stopRun(RunID(1)), .saveRunReport(RunID(1), "Asked: email Sam about lunch\n\nSent Sam the lunch email.\n"),
            .playCue(.done)
        ])
        #expect(engine.state.runs.map(\.status) == [.done, .stopped(.owner)])

        _ = engine.handle(.runDismissed(RunID(2)))
        #expect(engine.state.runs.map(\.id) == [RunID(1)])
    }

    @Test func aClaudeRunAndACodexRunWorkSideBySideAndEachKeepsItsOwnCLI() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) }, home: "/Users/owner")
        let claudeStart = say("agent, email Sam about lunch", to: &engine)
        _ = engine.handle(.runCLIChosen(.codex))
        _ = engine.handle(.approvalModeChosen(.approveOnly))
        let codexStart = say("agent, rename the screenshots on my Desktop", to: &engine)
        #expect(claudeStart.contains(.startRun(RunID(1), RunBrief(request: "email Sam about lunch", captures: [laptop]), .claudeCode, .auto)))
        #expect(codexStart.contains(
            .startRun(RunID(2), RunBrief(request: "rename the screenshots on my Desktop", captures: [laptop]), .codex, .approveOnly)
        ))
        #expect(engine.state.runs.map(\.cli) == [.claudeCode, .codex])
        #expect(engine.state.runs.map(\.approvalMode) == [.auto, .approveOnly])

        _ = engine.handle(.run(RunID(1), .started(folder: "/Runs/1")))
        _ = engine.handle(.run(RunID(2), .started(folder: "/Runs/2")))
        #expect(engine.handle(.run(RunID(2), .failed(.signedOut))) == [
            .stopRun(RunID(2)),
            .saveRunReport(
                RunID(2),
                "Asked: rename the screenshots on my Desktop\n\nCodex isn't signed in with ChatGPT. Run codex login in Terminal to sign in.\n"
            ),
            .playCue(.done)
        ])
        #expect(engine.state.runs.map(\.status) == [
            .running, .failed("Codex isn't signed in with ChatGPT. Run codex login in Terminal to sign in.")
        ])
    }

    @Test func aRunThatEndsLeavesTheMarksAnotherRunShowedOnScreen() {
        var engine = dockedEngine(["email Sam about lunch", "rename the screenshots on my Desktop"])
        _ = engine.handle(.run(RunID(1), .screensCaptured(ToolCallID(1), [laptop])))
        _ = engine.handle(.run(RunID(1), .toolCalled(ToolCallID(2), .showBeats("[RING:540,300,740,420] Here's the draft."))))
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])

        #expect(engine.handle(.run(RunID(2), .finished(report: "Renamed 12 screenshots."))) == [
            .stopRun(RunID(2)), .saveRunReport(RunID(2), "Asked: rename the screenshots on my Desktop\n\nRenamed 12 screenshots.\n"),
            .playCue(.done)
        ])
        #expect(engine.handle(.run(RunID(1), .finished(report: "Sent Sam the lunch email."))) == [
            .stopRun(RunID(1)), .saveRunReport(RunID(1), "Asked: email Sam about lunch\n\nSent Sam the lunch email.\n"),
            .playCue(.done), .clearAnnotations
        ])
    }

    @Test func eachRunPlaysTheLaunchCueAndOnlyARunThatEndsByItselfPlaysTheDoneCue() {
        var engine = dockedEngine(["email Sam about lunch"])
        #expect(say("agent, open Safari", to: &engine).filter { if case .playCue = $0 { true } else { false } } == [
            .playCue(.launch)
        ])
        #expect(engine.handle(.runStopRequested(RunID(1))).contains(.playCue(.done)) == false)
        #expect(engine.handle(.runTimeUp(RunID(2))).contains(.playCue(.done)))
    }

    @Test func aSpokenAnswerGoesToTheQuestionThatHasWaitedLongestAcrossTheDock() {
        var engine = dockedEngine(["email Sam about lunch", "rename the screenshots on my Desktop"])
        _ = engine.handle(question(2, 3, "Should the date go first?"))
        _ = engine.handle(question(1, 4, "Which Sam?"))
        #expect(engine.state.runs.map(\.status) == [.needsOwner, .needsOwner])

        #expect(engine.state.questionTakingNextTurn == ToolCallID(3))

        let first = say("Yes, date first.", to: &engine)
        #expect(first.contains(answered(3, "Yes, date first.")))
        #expect(first.contains(.speak("Thanks, I'll pass that on to agent run 2.", voice: .apple)))
        #expect(engine.state.questionTakingNextTurn == ToolCallID(4))
        #expect(!first.contains(.captureScreens))
        #expect(engine.state.runs.map(\.status) == [.needsOwner, .running])

        #expect(say("Sam Lee.", to: &engine).contains(answered(4, "Sam Lee.")))
        #expect(engine.state.runs.map(\.status) == [.running, .running])
    }

    @Test func aTalkTurnSaysTheDockIsEmptyWhenNoRunHasACard() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        let turn = sentTurn(of: say("How is the agent doing?", to: &engine))
        #expect(turn?.content.prefix(2) == [.text(emptyProfile), .text("The dock has no agent runs.")])
    }

    @Test func aTalkTurnCarriesASummaryOfEveryCardSoBuddyCanSayHowTheRunsAreGoing() throws {
        var engine = dockedEngine([
            "email Sam about lunch", "rename the screenshots on my Desktop", "open Safari", "list my open apps"
        ])
        _ = engine.handle(note(1, 1, "# Lunch email\n\n- [x] Write the email\n- [ ] Send it"))
        _ = engine.handle(.run(RunID(1), .approvalRequested(id: "r1", .command(sendLunchEmail))))
        _ = engine.handle(.run(RunID(2), .finished(report: "Renamed 12 screenshots on the Desktop.\n")))
        _ = engine.handle(.runStopRequested(RunID(3)))
        _ = engine.handle(.run(RunID(4), .failed(.signedOut)))

        let turn = try #require(sentTurn(of: say("How are my agent runs doing?", to: &engine)))
        #expect(turn.runs == engine.state.runs)
        #expect(turn.content.prefix(2) == [.text(emptyProfile), .text("""
            The dock's agent runs, oldest first:

            Run 1, "Lunch email", is waiting for the owner.
            The owner asked: email Sam about lunch
            It waits for the owner to approve or deny this on its card: \(sendLunchEmail)
            Run note:
            - [x] Write the email
            - [ ] Send it

            Run 2 is done.
            The owner asked: rename the screenshots on my Desktop
            Report: Renamed 12 screenshots on the Desktop.

            Run 3 was stopped by the owner.
            The owner asked: open Safari

            Run 4 failed.
            The owner asked: list my open apps
            Why it failed: Claude Code is signed out. Run claude in Terminal to sign in.
            """)])
    }

    @Test func theDockSummaryClipsALongRunNoteAndSaysWhenARunFinishedWithoutAReport() throws {
        var engine = dockedEngine(["sort my Downloads folder"])
        _ = engine.handle(note(1, 1, String(repeating: "a", count: 501)))
        _ = engine.handle(.run(RunID(1), .finished(report: "  \n")))
        let turn = try #require(sentTurn(of: say("Did it finish?", to: &engine)))
        #expect(turn.content[1] == .text("""
            The dock's agent runs, oldest first:

            Run 1 is done.
            The owner asked: sort my Downloads folder
            Run note:
            \(String(repeating: "a", count: 500))…
            It finished without a report.
            """))
    }

    @Test func aRunIsNamedByItsRunNotesHeadingOnceItWritesOne() {
        var engine = dockedEngine(["sort my Downloads folder"])
        #expect(engine.state.runs.first?.name == "Sort my Downloads folder")
        #expect(engine.state.runs.first?.namesItself == false)
        _ = engine.handle(note(1, 1, "Plan: sort by type.\n# Not a name"))
        #expect(engine.state.runs.first?.name == "Sort my Downloads folder")
        #expect(engine.state.runs.first?.noteBody == "Plan: sort by type.\n# Not a name")
        _ = engine.handle(note(1, 2, "\n## Sort Downloads  \n- [ ] Group by type"))
        #expect(engine.state.runs.first?.name == "Sort Downloads")
        #expect(engine.state.runs.first?.namesItself == true)
        #expect(engine.state.runs.first?.noteBody == "- [ ] Group by type")
    }

    @Test func talkAndRunsAreToldAboutTheDock() {
        #expect(TalkInstructions.system.contains("Every question also comes with a summary of the dock"))
        #expect(TalkInstructions.system.contains("Your owner stops a run with Stop on its card"))
        for mode in [ApprovalMode.auto, .approveOnly, .yolo] {
            #expect(RunInstructions.system(for: mode).contains("Start it with a heading that names the task in two to five words"))
            #expect(RunInstructions.system(for: mode).contains("Other agent runs may be working at the same time"))
        }
    }
}
