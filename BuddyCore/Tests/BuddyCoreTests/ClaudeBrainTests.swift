import Foundation
import Testing
import BuddyCore

/// A stand-in for `claude` that reads each turn's line from stdin and answers with a shell script.
private func fakeClaude(_ script: String, _ arguments: String...) -> ProcessLaunch {
    ProcessLaunch(
        executable: "/bin/sh",
        arguments: ["-c", script, "fake-claude"] + arguments,
        environment: [:],
        workingDirectory: FileManager.default.temporaryDirectory.path
    )
}

private let emptyDock = "The dock has no agent runs."
private let emptyProfile = "Your owner's profile is empty. They haven't asked you to remember anything about them."

@MainActor
private func reply(from brain: ClaudeBrain, to turn: TurnRequest) async -> [ProviderEvent] {
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
@Suite(.timeLimit(.minutes(1)))
struct ClaudeBrainTests {
    @Test(arguments: [false, true])
    func onlyAFreshProcessReceivesRecentText(prewarmed: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = folder.appending(path: "requests.jsonl")
        let brain = ClaudeBrain { fakeClaude(#"while IFS= read -r turn; do printf '%s\n' "$turn" >> "$1"; printf '%s\n' '{"type":"result","is_error":false}'; done"#, wire.path) }
        defer { brain.stop() }
        if prewarmed { brain.start() }
        let request = TurnRequest(transcript: "Which gear?", captures: [], recentTurns: [TurnRecord(transcript: "Where are settings?", reply: "Click the gear.")])
        #expect(await reply(from: brain, to: request) == [.completed])
        #expect(await reply(from: brain, to: request) == [.completed])
        brain.stop()
        #expect(await reply(from: brain, to: request) == [.completed])
        let messages = try String(contentsOf: wire, encoding: .utf8).split(separator: "\n").map { line -> [String] in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let message = object["message"] as! [String: Any]
            return (message["content"] as! [[String: String]]).map { $0["text"]! }
        }
        #expect(messages == [
            [emptyProfile, emptyDock, "Recent exchanges in this conversation (text only):\nOwner: Where are settings?\nBuddy: Click the gear.", "Which gear?"],
            [emptyProfile, emptyDock, "Which gear?"],
            [emptyProfile, emptyDock, "Recent exchanges in this conversation (text only):\nOwner: Where are settings?\nBuddy: Click the gear.", "Which gear?"]
        ])
    }

    @Test func aWarmProcessStillReceivesTheProfileEveryTurn() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = folder.appending(path: "requests.jsonl")
        let brain = ClaudeBrain { fakeClaude(#"while IFS= read -r turn; do printf '%s\n' "$turn" >> "$1"; printf '%s\n' '{"type":"result","is_error":false}'; done"#, wire.path) }
        defer { brain.stop() }
        let profile = Profile(notes: ["Goes by Sam."])
        #expect(await reply(from: brain, to: TurnRequest(transcript: "Hi.", captures: [], profile: profile)) == [.completed])
        #expect(await reply(from: brain, to: TurnRequest(transcript: "Who am I?", captures: [], profile: profile)) == [.completed])
        let messages = try String(contentsOf: wire, encoding: .utf8).split(separator: "\n").map { line -> [String] in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let message = object["message"] as! [String: Any]
            return (message["content"] as! [[String: String]]).map { $0["text"]! }
        }
        let profileText = "Your owner's profile, the notes they asked you to remember about them:\n- Goes by Sam."
        #expect(messages == [[profileText, emptyDock, "Hi."], [profileText, emptyDock, "Who am I?"]])
    }

    @Test func summariesPrimeOnlyTheFirstMessageToAProcessButTheProfileGoesInEveryMessage() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-summaries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = folder.appending(path: "requests.jsonl")
        let brain = ClaudeBrain { fakeClaude(#"while IFS= read -r turn; do printf '%s\n' "$turn" >> "$1"; printf '%s\n' '{"type":"result","is_error":false}'; done"#, wire.path) }
        defer { brain.stop() }
        let request = TurnRequest(
            transcript: "What is my kite called?", captures: [], earlierSummaries: ["The owner's kite is Copper Finch."],
            summary: "They talked about kites.", recentTurns: [TurnRecord(transcript: "Hi", reply: "Hello.")],
            profile: Profile(notes: ["Goes by Sam."])
        )
        #expect(await reply(from: brain, to: request) == [.completed])
        #expect(await reply(from: brain, to: request) == [.completed])
        let messages = try String(contentsOf: wire, encoding: .utf8).split(separator: "\n").map { line -> [String] in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let message = object["message"] as! [String: Any]
            return (message["content"] as! [[String: String]]).map { $0["text"]! }
        }
        let profileText = "Your owner's profile, the notes they asked you to remember about them:\n- Goes by Sam."
        #expect(messages == [
            [
                profileText, emptyDock,
                "Summaries of earlier conversations, oldest first:\n- The owner's kite is Copper Finch.",
                "Summary of this conversation so far:\nThey talked about kites.",
                "Recent exchanges in this conversation (text only):\nOwner: Hi\nBuddy: Hello.",
                "What is my kite called?"
            ],
            [profileText, emptyDock, "What is my kite called?"]
        ])
    }

    @Test func aProcessThatExitsWhileIdleReceivesPrimingAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-context-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = folder.appending(path: "requests.jsonl")
        let brain = ClaudeBrain { fakeClaude(#"IFS= read -r turn; printf '%s\n' "$turn" >> "$1"; printf '%s\n' '{"type":"result","is_error":false}'"#, wire.path) }
        defer { brain.stop() }
        let request = TurnRequest(transcript: "Which gear?", captures: [], recentTurns: [TurnRecord(transcript: "Where are settings?", reply: "Click the gear.")])
        #expect(await reply(from: brain, to: request) == [.completed])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await reply(from: brain, to: request) == [.completed])
        let lines = try String(contentsOf: wire, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let message = object["message"] as! [String: Any]
            #expect((message["content"] as! [[String: String]]).map { $0["text"]! } == [
                emptyProfile, emptyDock, "Recent exchanges in this conversation (text only):\nOwner: Where are settings?\nBuddy: Click the gear.", "Which gear?"
            ])
        }
    }

    @Test func recordedTurnReplaysThroughAProcess() async throws {
        let recording = try fixtureURL("talk-turn")
        let brain = ClaudeBrain { fakeClaude(#"read turn; cat "$1"; read next"#, recording.path) }
        #expect(await reply(from: brain, to: wifiQuestion) == recordedTalkTurn)
        brain.stop()
    }

    @Test func processThatQuitsFailsTheTurnAndTheNextTurnStartsAnother() async {
        let brain = ClaudeBrain { fakeClaude(#"read turn; echo "error: unknown option '--tools'" >&2; exit 1"#) }
        #expect(await reply(from: brain, to: wifiQuestion) == [.failed(.error("error: unknown option '--tools'"))])
        #expect(await reply(from: brain, to: wifiQuestion) == [.failed(.error("error: unknown option '--tools'"))])
    }

    @Test func signedOutProcessIsReplacedForTheNextTurn() async throws {
        let recording = try fixtureURL("signed-out")
        let brain = ClaudeBrain { fakeClaude(#"read turn; cat "$1"; read next"#, recording.path) }
        #expect(await reply(from: brain, to: wifiQuestion) == [.failed(.signedOut)])
        #expect(await reply(from: brain, to: wifiQuestion) == [.failed(.signedOut)])
        brain.stop()
    }

    @Test func missingClaudeFailsTheTurnOnceSendHasReturned() async {
        let brain = ClaudeBrain { nil }
        var events: [ProviderEvent] = []
        await withCheckedContinuation { continuation in
            brain.send(wifiQuestion) { event in
                events.append(event)
                continuation.resume()
            }
            #expect(events == [])
        }
        #expect(events == [.failed(.notInstalled)])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_LIVE_CLAUDE"] == "1", "set BUDDY_LIVE_CLAUDE=1 to spend one tiny real turn"))
    func liveClaudeAnswersATinyTurnFromAnEmptyFolder() async throws {
        let (brain, folder) = try liveBrain()
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_LIVE_CLAUDE"] == "1", "set BUDDY_LIVE_CLAUDE=1 to spend one small real turn"))
    func liveClaudeOffersARunWhenAskedToRenameABatchOfFiles() async throws {
        let (brain, folder) = try liveBrain()
        var engine = BuddyEngine(providerConnected: true)
        for event in controlDoubleTap { _ = engine.handle(event) }
        _ = engine.handle(.textBoxSubmitted("Rename all the screenshots on my Desktop so each name starts with the date it was taken."))
        guard case .sendTurn(let turn) = engine.handle(.screensCaptured([])).first else {
            Issue.record("The request wasn't sent to the provider.")
            return
        }
        let events = await reply(from: brain, to: turn)
        brain.stop()
        #expect(events.last == .completed)
        var queue = events.map { BuddyEngine.Event.provider($0) }
        var spoken: [String] = []
        while !queue.isEmpty {
            for effect in engine.handle(queue.removeFirst()) {
                guard case .speak(let line, _, _) = effect else { continue }
                spoken.append(line)
                queue += [.lineStarted, .lineFinished]
            }
        }
        print("Spoke: \(spoken)\nOffered: \(engine.state.runOffer?.request ?? "nothing")")
        #expect(engine.state.runOffer != nil)
        #expect(spoken.last?.hasSuffix("?") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_LIVE_CLAUDE"] == "1", "set BUDDY_LIVE_CLAUDE=1 to spend one small real turn"))
    func liveClaudeSaysHowARunInTheDockIsGoing() async throws {
        let (brain, folder) = try liveBrain()
        var engine = BuddyEngine(providerConnected: true)
        for event in controlDoubleTap { _ = engine.handle(event) }
        _ = engine.handle(.textBoxSubmitted("agent, rename the screenshots on my Desktop so each starts with its date"))
        _ = engine.handle(.screensCaptured([]))
        _ = engine.handle(.run(RunID(1), .started(folder: "/Runs/1")))
        _ = engine.handle(.run(RunID(1), .toolCalled(ToolCallID(1), .updateRunNote(
            "# Rename screenshots\n\n- [x] Find the screenshots: 12 on the Desktop\n- [ ] Now: renaming them, 5 of 12 done\n- [ ] Check the new names"
        ))))
        for event in controlDoubleTap { _ = engine.handle(event) }
        _ = engine.handle(.textBoxSubmitted("How is the agent doing?"))
        guard case .sendTurn(let turn) = engine.handle(.screensCaptured([])).first else {
            Issue.record("The question wasn't sent to the provider.")
            return
        }
        let events = await reply(from: brain, to: turn)
        brain.stop()
        let text = events.compactMap { event -> String? in
            guard case .textDelta(let text) = event else { return nil }
            return text
        }.joined()
        print("Answered: \(text)")
        #expect(events.last == .completed)
        #expect(text.lowercased().contains("screenshot"))
        #expect(text.contains("5") || text.lowercased().contains("five"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [])
    }
}

/// The production talk brain on the owner's real Claude sign-in, in a new empty folder.
@MainActor
private func liveBrain() throws -> (ClaudeBrain, URL) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let brain = ClaudeBrain {
        ClaudeLaunch.talk(
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: folder.path,
            isExecutable: FileManager.default.isExecutableFile
        )
    }
    return (brain, folder)
}
