import Foundation
import Testing
import BuddyCore

private let laptop = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)

private func asking(_ question: String, on engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
    _ = engine.handle(.pushToTalkPressed)
    _ = engine.handle(.pushToTalkReleased)
    _ = engine.handle(.transcriptFinished(question))
    return engine.handle(.screensCaptured([laptop]))
}

struct ProviderCLITests {
    @Test(arguments: [
        (ProviderFailure.notInstalled, "Codex isn't installed. Install it and sign in, then try again."),
        (.signedOut, "Codex isn't signed in with ChatGPT. Run codex login in Terminal to sign in."),
        (.error("stream disconnected"), "Codex failed: stream disconnected")
    ])
    func codexFailureEndsTheTurnWithCodexsNotice(failure: ProviderFailure, notice: String) {
        var engine = BuddyEngine(providerConnected: true, talkSetup: .direct(.codex))
        #expect(asking("where's save?", on: &engine) == [.sendTurn(TurnRequest(transcript: "where's save?", captures: [laptop]))])
        #expect(engine.handle(.provider(.failed(failure))) == [.showNotch(.notice(notice))])
        #expect(engine.state.notice == notice)
    }

    @Test func chosenSetupNamesTheNextFailure() {
        var engine = BuddyEngine(providerConnected: true)
        #expect(engine.handle(.talkSetupChosen(.direct(.codex))) == [])
        _ = asking("where's save?", on: &engine)
        #expect(engine.handle(.provider(.failed(.signedOut))) == [
            .showNotch(.notice("Codex isn't signed in with ChatGPT. Run codex login in Terminal to sign in."))
        ])
        #expect(engine.handle(.talkSetupChosen(.proxied(.codex))) == [])
        _ = asking("where's save?", on: &engine)
        #expect(engine.handle(.provider(.failed(.signedOut))) == [
            .showNotch(.notice("Claude Code is signed out. Run claude in Terminal to sign in."))
        ])
    }

    @Test func agentRunFailureNamesClaudeCodeWhileCodexAnswersTalk() {
        var engine = BuddyEngine(providerConnected: true, talkSetup: .direct(.codex), home: "/Users/owner")
        let effects = asking("agent, make a folder on my Desktop", on: &engine)
        #expect(effects.contains(.startRun(RunID(1), RunBrief(request: "make a folder on my Desktop", captures: [laptop]), .claudeCode, .auto)))
        _ = engine.handle(.run(RunID(1), .started(folder: "/tmp/run-1")))
        _ = engine.handle(.run(RunID(1), .failed(.signedOut)))
        #expect(engine.state.runs.first?.status == .failed("Claude Code is signed out. Run claude in Terminal to sign in."))
    }

    @Test func chosenRunCLIStartsTheNextRunWithoutChangingTalk() {
        var engine = BuddyEngine(providerConnected: true, home: "/Users/owner")
        #expect(engine.handle(.runCLIChosen(.codex)) == [])
        #expect(engine.state.runCLI == .codex)
        #expect(engine.state.talkSetup == .direct(.auto))
        #expect(engine.state.provider == .claude)
        let effects = asking("agent, make a folder on my Desktop", on: &engine)
        #expect(effects.contains(.startRun(RunID(1), RunBrief(request: "make a folder on my Desktop", captures: [laptop]), .codex, .auto)))
        #expect(engine.state.runs.first?.cli == .codex)
    }

    @Test(arguments: [
        (ProviderFailure.notInstalled, "Codex isn't installed. Install it and sign in, then try again."),
        (.signedOut, "Codex isn't signed in with ChatGPT. Run codex login in Terminal to sign in."),
        (.error("it wouldn't ask Buddy before each command"), "Codex failed: it wouldn't ask Buddy before each command")
    ])
    func codexRunKeepsItsCLIWhenTheOwnerChoosesAnotherForLaterRuns(failure: ProviderFailure, notice: String) {
        var engine = BuddyEngine(providerConnected: true, runCLI: .codex, home: "/Users/owner")
        _ = asking("agent, make a folder on my Desktop", on: &engine)
        #expect(engine.handle(.runCLIChosen(.claudeCode)) == [])
        _ = engine.handle(.run(RunID(1), .started(folder: "/tmp/run-1")))
        #expect(engine.handle(.run(RunID(1), .failed(failure))) == [
            .stopRun(RunID(1)),
            .saveRunReport(RunID(1), "Asked: make a folder on my Desktop\n\n\(notice)\n"),
            .playCue(.done)
        ])
        #expect(engine.state.runs.first?.status == .failed(notice))
        #expect(engine.state.runs.first?.cli == .codex)
        #expect(engine.state.runCLI == .claudeCode)
    }
}
