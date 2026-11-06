import Foundation
import Testing
import BuddyCore

private let now = Date(timeIntervalSince1970: 1_793_500_000)
private let id = RunID(1)

struct RunFallbackTests {
    @Test func newRunUsesTheProviderWithMoreHeadroom() {
        let usage = UsageSnapshots(
            claude: ProviderUsage(fiveHour: UsageWindow(utilization: 0.9, resetsAt: now.addingTimeInterval(3600)), sevenDay: nil),
            codex: ProviderUsage(fiveHour: UsageWindow(utilization: 0.1, resetsAt: now.addingTimeInterval(3600)), sevenDay: nil)
        )
        var engine = BuddyEngine(providerConnected: true, usage: usage, now: { now })
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("agent, list open apps"))
        let effects = engine.handle(.screensCaptured([]))
        #expect(effects.first == .startRun(id, RunBrief(request: "list open apps", captures: []), .codex, .auto))
        #expect(engine.state.runs.first?.cli == .codex)
    }

    @Test func limitPausesThenResumesInTheSameRunWithItsProgress() throws {
        var engine = running()
        _ = engine.handle(.run(id, .toolCalled(ToolCallID(1), .updateRunNote("# Apps\n- [x] Listed apps\n- [ ] Save list"))))
        let effects = engine.handle(.run(id, .limitReached(partialReport: "Found Finder and Safari. No file written yet.")))
        let note = "# Apps\n- [x] Listed apps\n- [ ] Save list\n\n## Provider switch\nClaude reached its limit. Switched to Codex; continuing from the saved progress."
        let brief = RunBrief(request: "list open apps", captures: [], continuation: RunContinuation(
            note: note, partialReport: "Found Finder and Safari. No file written yet."
        ))
        #expect(effects == [
            .saveUsage(UsageSnapshots(claude: ProviderUsage(
                fiveHour: UsageWindow(utilization: 1, resetsAt: now.addingTimeInterval(18000)), sevenDay: nil
            ))),
            .pauseRun(id), .saveRunNote(id, note),
            .saveRunReport(id, "Found Finder and Safari. No file written yet."),
            .resumeRun(id, brief, .codex, .auto)
        ])
        #expect(engine.state.runs.first?.status == .paused)
        #expect(engine.state.runs.first?.folder == "/tmp/run-30")
        #expect(engine.state.runs.first?.cli == .codex)
        #expect(engine.state.runs.first?.noteBody == "- [x] Listed apps\n- [ ] Save list\n\n## Provider switch\nClaude reached its limit. Switched to Codex; continuing from the saved progress.")
        #expect(engine.handle(.run(id, .started(folder: "/tmp/run-30"))) == [])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.handle(.run(id, .finished(report: "Saved output/apps.txt."))) == [
            .stopRun(id), .saveRunReport(id, "Asked: list open apps\n\nSaved output/apps.txt.\n"), .playCue(.done)
        ])
        #expect(engine.state.runs.first?.status == .done)
        #expect(engine.state.runs.count == 1)
    }

    @Test func pendingApprovalAndQuestionSurviveUntilTheOwnerAnswersWithoutReplayingOldIDs() throws {
        var engine = running(mode: .approveOnly)
        _ = engine.handle(.run(id, .approvalRequested(id: "old-command", .command("mkdir output/apps"))))
        _ = engine.handle(.run(id, .toolCalled(ToolCallID(2), .askOwner("Which apps?", choices: ["All", "Visible"]))))
        let effects = engine.handle(.run(id, .failed(.limitReached)))
        #expect(!effects.contains { if case .resumeRun = $0 { true } else { false } })
        #expect(engine.state.runs.first?.status == .needsOwner)
        #expect(engine.state.runs.first?.asks.count == 2)
        let answered = engine.handle(.runApprovalAnswered(id, request: "old-command", approved: false))
        #expect(!answered.contains { if case .answerApproval = $0 { true } else { false } })
        #expect(engine.state.runs.first?.asks == [.question(ToolCallID(2), "Which apps?", choices: ["All", "Visible"])])
        let resumed = engine.handle(.runQuestionAnswered(id, ToolCallID(2), "Visible"))
        let brief = try #require(resumed.compactMap { effect -> RunBrief? in
            if case .resumeRun(id, let brief, .codex, .approveOnly) = effect { brief } else { nil }
        }.first)
        #expect(brief.continuation?.note.contains("Your owner answered \"Which apps?\": Visible") == true)
        #expect(brief.continuation?.note.contains("`mkdir output/apps`: You said no.") == true)
        #expect(!resumed.contains { if case .answerTool = $0 { true } else { false } })
        _ = engine.handle(.run(id, .started(folder: "/tmp/run-30")))
        #expect(engine.state.runs.first?.approvalMode == .approveOnly)
        #expect(engine.handle(.run(id, .approvalRequested(id: "new-command", .command("mkdir output/apps")))) == [.playCue(.needsOwner)])
    }

    @Test func aLimitReleasesTheScreenAndNeverTransfersConsent() {
        var engine = running()
        _ = engine.handle(.permissionsObserved(PermissionSnapshot(accessibility: .granted)))
        _ = engine.handle(.run(id, .toolCalled(ToolCallID(3), .beginTakeover(reason: "Read the app"))))
        _ = engine.handle(.runTakeoverAnswered(id, ToolCallID(3), approved: true))
        let effects = engine.handle(.run(id, .failed(.limitReached)))
        #expect(effects.contains(.endTakeover(id)))
        #expect(!effects.contains(.beginTakeover(id)))
        _ = engine.handle(.run(id, .started(folder: "/tmp/run-30")))
        #expect(engine.handle(.run(id, .toolCalled(ToolCallID(4), .screen(.type("hello"))))) == [
            .answerTool(ToolCallID(4), ToolAnswer(content: [.text("You don't have the screen. Ask for it with begin_takeover first.")], isError: true))
        ])
    }

    @Test func aSecondLimitFailsWithoutBouncingBackOrResettingTheStepCap() {
        var engine = running(limits: RunLimits(steps: 1, seconds: 90))
        _ = engine.handle(.run(id, .toolUsed))
        _ = engine.handle(.run(id, .failed(.limitReached)))
        _ = engine.handle(.run(id, .started(folder: "/tmp/run-30")))
        #expect(engine.handle(.run(id, .toolUsed)) == [
            .stopRun(id), .saveRunReport(id, "Asked: list open apps\n\nStopped at its step cap of 1 step.\n"), .playCue(.done)
        ])
        var exhausted = running()
        _ = exhausted.handle(.run(id, .failed(.limitReached)))
        _ = exhausted.handle(.run(id, .started(folder: "/tmp/run-30")))
        let effects = exhausted.handle(.run(id, .failed(.limitReached)))
        #expect(!effects.contains { if case .resumeRun = $0 { true } else { false } })
        #expect(exhausted.state.runs.first?.status == .failed("Codex reached its usage limit. Try again after it resets."))
    }

    @Test func stoppingWhilePausedCancelsTheReplacementAndTimeCapStillApplies() {
        var engine = running()
        _ = engine.handle(.run(id, .failed(.limitReached)))
        #expect(engine.handle(.runStopRequested(id)) == [
            .stopRun(id), .saveRunReport(id, "Asked: list open apps\n\nStopped by the owner.\n")
        ])
        #expect(engine.handle(.run(id, .started(folder: "/tmp/run-30"))) == [])
        #expect(engine.state.runs.first?.status == .stopped(.owner))
        var timed = running()
        _ = timed.handle(.run(id, .failed(.limitReached)))
        #expect(timed.handle(.runTimeUp(id)) == [
            .stopRun(id), .saveRunReport(id, "Asked: list open apps\n\nStopped at its time cap of 20 minutes.\n"), .playCue(.done)
        ])
    }

    @Test func manualRunChoiceWinsAndTalkAccountChoicesDoNotRouteRuns() {
        var engine = BuddyEngine(providerConnected: true, talkSetup: .proxied(.codex), now: { now })
        _ = engine.handle(.runProviderChosen(.claude))
        start(on: &engine)
        let effects = engine.handle(.run(id, .failed(.limitReached)))
        #expect(engine.state.runs.first?.cli == .claudeCode)
        #expect(!effects.contains { if case .resumeRun = $0 { true } else { false } })
        #expect(engine.state.talkSetup == .proxied(.codex))
    }

    @Test func codexCanHandOffToClaudeAndTheSwitchNoteSurvivesNewNotes() {
        let usage = UsageSnapshots(
            claude: ProviderUsage(fiveHour: UsageWindow(utilization: 0.8, resetsAt: now.addingTimeInterval(3600)), sevenDay: nil),
            codex: ProviderUsage(fiveHour: UsageWindow(utilization: 0.1, resetsAt: now.addingTimeInterval(3600)), sevenDay: nil)
        )
        var engine = BuddyEngine(providerConnected: true, usage: usage, now: { now })
        start(on: &engine)
        #expect(engine.state.runs.first?.cli == .codex)
        let effects = engine.handle(.run(id, .limitReached(partialReport: "Ready to save.")))
        #expect(effects.contains { if case .resumeRun(id, _, .claudeCode, .auto) = $0 { true } else { false } })
        _ = engine.handle(.run(id, .started(folder: "/tmp/run-30")))
        let saved = engine.handle(.run(id, .toolCalled(ToolCallID(6), .updateRunNote("# Apps\n- [x] Saved"))))
        #expect(saved.first == .saveRunNote(id, "# Apps\n- [x] Saved\n\n## Provider switch\nCodex reached its limit. Switched to Claude; continuing from the saved progress."))
    }

    @Test func approvedPendingTakeoverStillRequiresNewConsentAndStaleEventsCannotActWhilePaused() {
        var engine = running()
        _ = engine.handle(.permissionsObserved(PermissionSnapshot(accessibility: .granted)))
        _ = engine.handle(.run(id, .toolCalled(ToolCallID(9), .beginTakeover(reason: "Use the app"))))
        _ = engine.handle(.run(id, .failed(.limitReached)))
        #expect(engine.handle(.run(id, .toolCalled(ToolCallID(10), .screen(.type("late"))))) == [
            .answerTool(ToolCallID(10), ToolAnswer(content: [.text("This run is switching providers.")], isError: true))
        ])
        #expect(engine.handle(.run(id, .toolUsed)) == [])
        let effects = engine.handle(.runTakeoverAnswered(id, ToolCallID(9), approved: true))
        #expect(!effects.contains(.beginTakeover(id)))
        #expect(effects.contains { if case .resumeRun = $0 { true } else { false } })
        _ = engine.handle(.run(id, .started(folder: "/tmp/run-30")))
        #expect(engine.state.runs.first?.status == .running)
    }

    @Test func multipleQuestionsKeepTheirAnswersAssociatedWhenAnsweredOutOfOrderDuringHandoff() throws {
        var engine = running()
        _ = engine.handle(.run(id, .toolCalled(ToolCallID(11), .askOwner("Which folder?", choices: ["Desktop", "Documents"]))))
        _ = engine.handle(.run(id, .toolCalled(ToolCallID(12), .askOwner("Which format?", choices: ["Text", "CSV"]))))
        _ = engine.handle(.run(id, .failed(.limitReached)))
        #expect(engine.handle(.runQuestionAnswered(id, ToolCallID(12), "CSV")) == [
            .saveRunNote(id, "## Provider switch\nClaude reached its limit. Switched to Codex; continuing from the saved progress.\nYour owner answered \"Which format?\": CSV")
        ])
        let effects = engine.handle(.runQuestionAnswered(id, ToolCallID(11), "Desktop"))
        let brief = try #require(effects.compactMap { effect -> RunBrief? in
            if case .resumeRun(id, let brief, .codex, .auto) = effect { brief } else { nil }
        }.first)
        #expect(brief.continuation?.note == "## Provider switch\nClaude reached its limit. Switched to Codex; continuing from the saved progress.\nYour owner answered \"Which format?\": CSV\nYour owner answered \"Which folder?\": Desktop")
    }

    private func running(mode: ApprovalMode = .auto, limits: RunLimits = .standard) -> BuddyEngine {
        var engine = BuddyEngine(providerConnected: true, approvalMode: mode, now: { now }, runLimits: limits)
        start(on: &engine)
        return engine
    }

    private func start(on engine: inout BuddyEngine) {
        for event: BuddyEngine.Event in [
            .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("agent, list open apps"), .screensCaptured([]),
            .lineStarted, .lineFinished, .run(id, .started(folder: "/tmp/run-30"))
        ] { _ = engine.handle(event) }
    }
}
