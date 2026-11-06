import Foundation
import Testing
import BuddyCore

struct ApprovalModeTests {
    private static let runFolder = "/Users/owner/Library/Application Support/Buddy/Runs/2026-11-02-090000-1"

    private static func engineWithRun(_ mode: ApprovalMode) -> BuddyEngine {
        var engine = BuddyEngine(
            providerConnected: true, approvalMode: mode, home: "/Users/owner",
            fileExists: { $0 == "/Users/owner/Desktop" || $0 == "/Users/owner/Documents/journal.md" }
        )
        let events: [BuddyEngine.Event] = [
            .pushToTalkPressed,
            .pushToTalkReleased,
            .transcriptFinished("agent, make a folder on my Desktop"),
            .screensCaptured([]),
            .run(RunID(1), .started(folder: runFolder))
        ]
        for event in events { _ = engine.handle(event) }
        return engine
    }

    private static func answer(_ request: ApprovalRequest, in mode: ApprovalMode) -> (effects: [BuddyEngine.Effect], asks: [OwnerAsk]) {
        var engine = engineWithRun(mode)
        let effects = engine.handle(.run(RunID(1), .approvalRequested(id: "r1", request)))
        return (effects, engine.state.runs.first?.asks ?? [])
    }

    private static let allowed: [BuddyEngine.Effect] = [.answerApproval(RunID(1), id: "r1", .allow)]

    @Test(arguments: [
        ApprovalRequest.command("ls -la ~/Desktop"),
        .command("mkdir -p ~/Desktop/Open\\ Apps"),
        .write(path: "\(runFolder)/output/apps.txt"),
        .changes([.write(path: "\(runFolder)/output/apps.txt"), .edit(path: "\(runFolder)/scratch/plan.md")])
    ])
    func approveOnlyAsksTheOwnerAboutWhatAutoWouldAllow(request: ApprovalRequest) {
        #expect(Self.answer(request, in: .auto).effects == Self.allowed)
        let answered = Self.answer(request, in: .approveOnly)
        #expect(answered.effects == [.playCue(.needsOwner)])
        #expect(answered.asks.count == 1)
        guard case .approval(let id, _, let reason) = answered.asks.first else { return }
        #expect(id == "r1")
        #expect(reason == "You approve every command and file change.")
    }

    @Test(arguments: [
        ApprovalRequest.read(path: "~/Documents/journal.md"),
        .buddyTool("mcp__buddy__update_run_note")
    ])
    func approveOnlyLetsReadsAndBuddysToolsThrough(request: ApprovalRequest) {
        #expect(Self.answer(request, in: .approveOnly).effects == Self.allowed)
    }

    @Test(arguments: [
        ApprovalRequest.command("cd ~/Desktop"),
        .command("curl -s https://example.com"),
        .other(tool: "WebFetch")
    ])
    func approveOnlyKeepsWhatAutoDeniesOrAsks(request: ApprovalRequest) {
        let auto = Self.answer(request, in: .auto)
        let approveOnly = Self.answer(request, in: .approveOnly)
        #expect(approveOnly.effects == auto.effects)
        #expect(approveOnly.asks == auto.asks)
    }

    @Test(arguments: [
        ApprovalRequest.command("cd ~/Desktop"),
        .command("curl -s https://example.com"),
        .command("( set -o noclobber; echo hi > ~/Desktop/a.txt )"),
        .delete(path: "/Users/owner/Documents/journal.md"),
        .other(tool: "WebFetch")
    ])
    func yoloAllowsEverything(request: ApprovalRequest) {
        #expect(Self.answer(request, in: .yolo).effects == Self.allowed)
    }

    @Test func aRunKeepsTheModeItStartedWithAndTheNextRunUsesTheNewOne() throws {
        var engine = Self.engineWithRun(.auto)
        #expect(engine.handle(.approvalModeChosen(.yolo)) == [])
        #expect(engine.state.approvalMode == .yolo)
        #expect(engine.state.runs.first?.approvalMode == .auto)
        #expect(engine.handle(.run(RunID(1), .approvalRequested(id: "r1", .command("cd ~/Desktop")))) == [
            .saveRunNote(RunID(1), try #require(engine.state.runs.first?.noteDocument)),
            .answerApproval(RunID(1), id: "r1", .deny("Buddy keeps commands in the run folder; use paths instead of `cd`."))
        ])

        _ = engine.handle(.runStopRequested(RunID(1)))
        for event: BuddyEngine.Event in [.pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("agent, list my open apps")] {
            _ = engine.handle(event)
        }
        #expect(engine.handle(.screensCaptured([])).contains(
            .startRun(RunID(2), RunBrief(request: "list my open apps", captures: []), .claudeCode, .yolo)
        ))
        _ = engine.handle(.run(RunID(2), .started(folder: Self.runFolder)))
        #expect(engine.state.runs.map(\.approvalMode) == [.auto, .yolo])
        #expect(engine.handle(.run(RunID(2), .approvalRequested(id: "r2", .command("cd ~/Desktop"))))
            == [.answerApproval(RunID(2), id: "r2", .allow)])
    }
}
