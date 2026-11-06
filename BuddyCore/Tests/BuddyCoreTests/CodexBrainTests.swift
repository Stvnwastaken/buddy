import Foundation
import Testing
import BuddyCore

private struct Workspace {
    let screenshots: URL
    let log: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buddy-codex-\(UUID().uuidString)")
        screenshots = root.appending(path: "screens")
        log = root.appending(path: "turns.log")
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
    }

    var logged: String {
        (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    /// The text parts of each `turn/start` the fake server read, across every process it ran as.
    var turnTexts: [[String]] {
        get throws {
            let wire = try String(contentsOfFile: log.path + ".requests", encoding: .utf8)
            return try wire.split(separator: "\n").compactMap { line -> [String]? in
                let message = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                guard message["method"] as? String == "turn/start" else { return nil }
                let params = message["params"] as! [String: Any]
                return (params["input"] as! [[String: String]]).compactMap { $0["text"] }
            }
        }
    }

    func remove() { try? FileManager.default.removeItem(at: screenshots.deletingLastPathComponent()) }
}

private let primedQuestion = TurnRequest(transcript: "Which gear?", captures: [], recentTurns: [
    TurnRecord(transcript: "Where are settings?", reply: "Click the gear.")
], profile: Profile(notes: ["Goes by Sam."]))
private let emptyDock = "The dock has no agent runs."
private let profileText = "Your owner's profile, the notes they asked you to remember about them:\n- Goes by Sam."
private let primedTexts = [
    profileText, emptyDock, "Recent exchanges in this conversation (text only):\nOwner: Where are settings?\nBuddy: Click the gear.", "Which gear?"
]

private func fakeCodex(in workspace: Workspace, replyLines: Int? = nil, exitsDuringReply: Bool = false) throws -> ProcessLaunch {
    let script = #"""
        read initialize; cat "$1"
        while IFS= read -r request; do
          printf '%s\n' "$request" >> "$4.requests"
          case "$request" in
            *'"method":"thread/start"'*)
              id=${request#'{"id":'}; id=${id%%,*}
              printf '{"id":%s,"result":{"thread":{"id":"fresh-thread"}}}\n' "$id";;
            *'"method":"turn/start"'*)
              echo "turn sees:" $(ls "$3") >> "$4"
              id=${request#'{"id":'}; id=${id%%,*}
              sed -n -e "1s/^{\"id\":7,/{\"id\":$id,/" -e "1,${5}p" "$2"
              if [ "$6" = yes ]; then exit; fi;;
          esac
        done
        """#
    return ProcessLaunch(
        executable: "/bin/sh",
        arguments: [
            "-c", script, "fake-codex",
            try fixtureURL("codex-startup").path,
            try fixtureURL("codex-talk-turn").path,
            workspace.screenshots.path,
            workspace.log.path,
            replyLines.map(String.init) ?? "$",
            exitsDuringReply ? "yes" : "no"
        ],
        environment: [:],
        workingDirectory: FileManager.default.temporaryDirectory.path
    )
}

/// Sends `turn` and returns its events once it has completed or failed.
@MainActor
private func reply(from brain: CodexBrain, to turn: TurnRequest) async -> [ProviderEvent] {
    await withCheckedContinuation { continuation in
        var events: [ProviderEvent] = []
        brain.send(turn) { event in
            events.append(event)
            switch event {
            case .completed, .failed: continuation.resume(returning: events)
            case .textDelta, .usage, .searching: break
            }
        }
    }
}

@MainActor
private func stoppingAtFirstText(_ brain: CodexBrain, _ turn: TurnRequest) async -> [ProviderEvent] {
    await withCheckedContinuation { continuation in
        var events: [ProviderEvent] = []
        brain.send(turn) { event in
            events.append(event)
            switch event {
            case .textDelta:
                brain.stop()
                #expect(events.last == event)
            case .failed: continuation.resume(returning: events)
            case .completed, .usage, .searching: break
            }
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CodexBrainTests {
    @Test(arguments: [false, true])
    func recordedTurnsReplayThroughAProcessWithEachScreenshotOnDiskOnlyDuringItsTurn(folderPurged: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        if folderPurged { try FileManager.default.removeItem(at: workspace.screenshots) }
        let launch = try fakeCodex(in: workspace)
        let brain = CodexBrain(imageFolder: workspace.screenshots.path) { launch }
        #expect(await reply(from: brain, to: keepChangesQuestion) == [.usage(codexWeeklyUsage)] + recordedCodexTalkTurn)
        #expect(await reply(from: brain, to: keepChangesQuestion) == recordedCodexTalkTurn)
        brain.stop()
        #expect(workspace.logged == "turn sees: turn-1-screen-1.jpg\nturn sees: turn-2-screen-1.jpg\n")
    }

    @Test func startupUsageReachesTheObserverBeforeAnyTurn() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let launch = try fakeCodex(in: workspace)
        let brain = CodexBrain(imageFolder: workspace.screenshots.path) { launch }
        defer { brain.stop() }
        let reported = await withCheckedContinuation { continuation in
            var waiting = true
            brain.onUsage = { usage in
                guard waiting else { return }
                waiting = false
                continuation.resume(returning: usage)
            }
            brain.start()
        }
        #expect(reported == codexWeeklyUsage)
    }

    @Test func stoppingMidTurnFailsItAndDeletesItsScreenshot() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let launch = try fakeCodex(in: workspace, replyLines: 7)
        let brain = CodexBrain(imageFolder: workspace.screenshots.path) { launch }
        #expect(await stoppingAtFirstText(brain, keepChangesQuestion) == [
            .usage(codexWeeklyUsage), .textDelta("["), .failed(.error("Buddy stopped it."))
        ])
        #expect(await stoppingAtFirstText(brain, TurnRequest(transcript: "And now?", captures: [])) == [
            .usage(codexWeeklyUsage), .textDelta("["), .failed(.error("Buddy stopped it."))
        ])
        #expect(workspace.logged == "turn sees: turn-1-screen-1.jpg\nturn sees:\n")
    }

    @Test func exitedProcessIsRetiredBeforeItsEndCallbackCanRun() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let first = try fakeCodex(in: workspace, replyLines: 7, exitsDuringReply: true)
        let replacement = try fakeCodex(in: workspace)
        var launches = 0
        let brain = CodexBrain(imageFolder: workspace.screenshots.path) {
            launches += 1
            return launches == 1 ? first : replacement
        }
        var oldEvents: [ProviderEvent] = []
        var newEvents: [ProviderEvent] = []
        await withCheckedContinuation { continuation in
            brain.send(keepChangesQuestion) { event in
                oldEvents.append(event)
                if case .textDelta = event {
                    // Keep the main queue busy until the process has exited, so its end callback must wait.
                    Thread.sleep(forTimeInterval: 0.5)
                    brain.send(TurnRequest(transcript: "And now?", captures: [])) { event in
                        newEvents.append(event)
                        if case .completed = event { continuation.resume() }
                    }
                    #expect(oldEvents.last == event)
                }
            }
        }
        brain.stop()
        #expect(oldEvents == [.usage(codexWeeklyUsage), .textDelta("["), .failed(.error("it quit unexpectedly"))])
        #expect(newEvents == [.usage(codexWeeklyUsage)] + recordedCodexTalkTurn)
        #expect(workspace.logged == "turn sees: turn-1-screen-1.jpg\nturn sees:\n")
    }

    @Test func newConversationKeepsTheProcessAndPrimesItsFreshThreadAgain() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let launch = try fakeCodex(in: workspace)
        var launches = 0
        let brain = CodexBrain(imageFolder: workspace.screenshots.path) {
            launches += 1
            return launch
        }
        defer { brain.stop() }
        #expect(await reply(from: brain, to: primedQuestion).last == .completed)
        #expect(await reply(from: brain, to: primedQuestion).last == .completed)
        brain.endConversation()
        #expect(await reply(from: brain, to: primedQuestion).last == .completed)
        #expect(launches == 1)
        #expect(try workspace.turnTexts == [primedTexts, [profileText, emptyDock, "Which gear?"], primedTexts])
    }

    @Test func freshProcessPrimesItsFirstTurnAgain() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let launch = try fakeCodex(in: workspace)
        var launches = 0
        let brain = CodexBrain(imageFolder: workspace.screenshots.path) {
            launches += 1
            return launch
        }
        defer { brain.stop() }
        #expect(await reply(from: brain, to: primedQuestion).last == .completed)
        brain.stop()
        #expect(await reply(from: brain, to: primedQuestion).last == .completed)
        #expect(launches == 2)
        #expect(try workspace.turnTexts == [primedTexts, primedTexts])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_LIVE_CODEX"] == "1", "set BUDDY_LIVE_CODEX=1 to spend one tiny real turn"))
    func liveCodexAnswersATinyTurnFromAnEmptyFolder() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let brain = CodexBrain(imageFolder: workspace.screenshots.path) {
            CodexLaunch.talk(
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: folder.path,
                isExecutable: FileManager.default.isExecutableFile
            )
        }
        let events = await reply(from: brain, to: TurnRequest(transcript: "Say the single word ready.", captures: []))
        brain.stop()
        let text = events.compactMap { event -> String? in
            guard case .textDelta(let text) = event else { return nil }
            return text
        }.joined()
        #expect(events.last == .completed)
        #expect(text.lowercased().contains("ready"))
        #expect(events.contains { if case .usage = $0 { true } else { false } })
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [])
    }
}
