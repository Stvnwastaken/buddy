import Foundation
import Testing
import BuddyCore

private let laptop = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)

private func askedEngine(
    spokenReplies: Bool = true,
    at now: Date = Date(timeIntervalSince1970: 1_000),
    timeZone: TimeZone? = nil
) -> (BuddyEngine, [BuddyEngine.Effect]) {
    var engine = BuddyEngine(providerConnected: true, spokenReplies: spokenReplies, now: { now }, timeZone: timeZone)
    var effects = engine.handle(.pushToTalkPressed) + engine.handle(.pushToTalkReleased)
    effects += engine.handle(.transcriptFinished("what's the top news story today"))
    effects += engine.handle(.screensCaptured([laptop]))
    return (engine, effects)
}

private func sentTurn(_ effects: [BuddyEngine.Effect]) -> TurnRequest? {
    effects.lazy.compactMap { effect -> TurnRequest? in
        guard case .sendTurn(let request) = effect else { return nil }
        return request
    }.first
}

struct WebSearchTests {
    @Test(arguments: [false, true])
    func searchCueReturnsToThinkingUntilTheProviderActuallyFinishes(spoken: Bool) {
        var (engine, _) = askedEngine(spokenReplies: spoken)
        _ = engine.handle(.provider(.searching))
        if spoken { _ = engine.handle(.lineStarted) }

        #expect(engine.handle(spoken ? .lineFinished : .replyLineRead) == [.showNotch(.thinking)])
        #expect(engine.handle(.provider(.usage(ProviderUsage(fiveHour: nil, sevenDay: nil)))) == [])
        #expect(engine.handle(.provider(.searching)) == [])
        #expect(engine.handle(.provider(.textDelta("The latest result is ready.\n"))) == (spoken
            ? [.speak("The latest result is ready.", voice: .apple)]
            : [.showNotch(.line("The latest result is ready.")), .waitForReading(.seconds(3))]))
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "what's the top news story today", reply: "The latest result is ready.")
        ])
        if spoken { _ = engine.handle(.lineStarted) }
        #expect(engine.handle(spoken ? .lineFinished : .replyLineRead) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
    }

    @Test func searchBeforeAnyLineSpeaksTheCueThenTheAnswerWithoutSavingTheCue() {
        var (engine, _) = askedEngine()
        #expect(engine.handle(.provider(.searching)) == [.speak("Let me look that up.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Let me look that up."))])
        #expect(engine.handle(.provider(.textDelta("Nine people died in a jet crash in Florida.\n"))) == [])
        #expect(engine.handle(.lineFinished) == [.speak("Nine people died in a jet crash in Florida.", voice: .apple)])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "what's the top news story today", reply: "Nine people died in a jet crash in Florida.")
        ])
    }

    @Test func lineWrittenBeforeTheSearchPlaysAtOnceInPlaceOfTheCue() {
        var (engine, _) = askedEngine()
        #expect(engine.handle(.provider(.textDelta("Let me check the news."))) == [])
        #expect(engine.handle(.provider(.searching)) == [.speak("Let me check the news.", voice: .apple)])
    }

    @Test func secondSearchInTheSameReplyPlaysNoSecondCue() {
        var (engine, _) = askedEngine()
        #expect(engine.handle(.provider(.searching)) == [.speak("Let me look that up.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Let me look that up."))])
        #expect(engine.handle(.lineFinished) == [.showNotch(.thinking)])
        #expect(engine.handle(.provider(.searching)) == [])
    }

    @Test func cueIsShownWhenRepliesAreRead() {
        var (engine, _) = askedEngine(spokenReplies: false)
        #expect(engine.handle(.provider(.searching)) == [.showNotch(.line("Let me look that up.")), .waitForReading(.seconds(3))])
    }

    @Test(arguments: [
        ("America/Toronto", "Today is Sunday, November 1, 2026."),
        ("Europe/Paris", "Today is Monday, November 2, 2026.")
    ])
    func turnSaysWhatDayItIsWhereTheOwnerIs(zone: String, date: String) throws {
        let (_, effects) = askedEngine(at: Date(timeIntervalSince1970: 1_793_592_000), timeZone: TimeZone(identifier: zone))
        #expect(try #require(sentTurn(effects)).content == [
            .text("Your owner's profile is empty. They haven't asked you to remember anything about them."),
            .text("The dock has no agent runs."),
            .text(date),
            .text("Screen 1 of 1, 1280x800 pixels, with the cursor:"),
            .jpeg(Data([1])),
            .text("what's the top news story today")
        ])
    }

    @Test func turnWithoutAKnownTimeZoneSaysNoDate() throws {
        let (_, effects) = askedEngine()
        #expect(try #require(sentTurn(effects)).content == [
            .text("Your owner's profile is empty. They haven't asked you to remember anything about them."),
            .text("The dock has no agent runs."),
            .text("Screen 1 of 1, 1280x800 pixels, with the cursor:"),
            .jpeg(Data([1])),
            .text("what's the top news story today")
        ])
    }
}

/// Asks about today's news through the engine on the owner's real sign-in, then plays the reply back through the
/// engine, which speaks the cue during the search. Prints the spoken lines so the owner can judge whether the answer
/// is current.
@MainActor
private func liveNewsTurn(send: (TurnRequest, @escaping (ProviderEvent) -> Void) -> Void) async -> (events: [ProviderEvent], spoken: [String]) {
    var engine = BuddyEngine(providerConnected: true, timeZone: .current)
    for event in controlDoubleTap { _ = engine.handle(event) }
    _ = engine.handle(.textBoxSubmitted("What's the top news story today?"))
    guard case .sendTurn(let turn) = engine.handle(.screensCaptured([])).first else {
        Issue.record("The question wasn't sent to the provider.")
        return ([], [])
    }
    let events: [ProviderEvent] = await withCheckedContinuation { continuation in
        var events: [ProviderEvent] = []
        send(turn) { event in
            events.append(event)
            switch event {
            case .completed, .failed: continuation.resume(returning: events)
            case .textDelta, .usage, .searching: break
            }
        }
    }
    var queue = events.map { BuddyEngine.Event.provider($0) }
    var spoken: [String] = []
    while !queue.isEmpty {
        for effect in engine.handle(queue.removeFirst()) {
            guard case .speak(let line, _, _) = effect else { continue }
            spoken.append(line)
            queue += [.lineStarted, .lineFinished]
        }
    }
    print("Asked with: \(turn.today ?? "no date")\nSpoke: \(spoken)")
    return (events, spoken)
}

@MainActor
@Suite(.timeLimit(.minutes(3)))
struct LiveWebSearchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_LIVE_CLAUDE"] == "1", "set BUDDY_LIVE_CLAUDE=1 to spend one real turn with a web search"))
    func liveClaudeSearchesTheWebForTodaysNews() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-live-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let brain = ClaudeBrain {
            ClaudeLaunch.talk(environment: ProcessInfo.processInfo.environment, workingDirectory: folder.path, isExecutable: FileManager.default.isExecutableFile)
        }
        let (events, spoken) = await liveNewsTurn(send: brain.send)
        brain.stop()
        #expect(events.contains(.searching))
        #expect(events.last == .completed)
        #expect(spoken.count >= 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_LIVE_CODEX"] == "1", "set BUDDY_LIVE_CODEX=1 to spend one real turn with a web search"))
    func liveCodexSearchesTheWebForTodaysNews() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-live-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let brain = CodexBrain(imageFolder: folder.path) {
            CodexLaunch.talk(environment: ProcessInfo.processInfo.environment, workingDirectory: folder.path, isExecutable: FileManager.default.isExecutableFile)
        }
        let (events, spoken) = await liveNewsTurn(send: brain.send)
        brain.stop()
        #expect(events.contains(.searching))
        #expect(events.last == .completed)
        #expect(spoken.count >= 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [])
    }
}
