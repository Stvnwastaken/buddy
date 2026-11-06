import Foundation
import Testing
import BuddyCore

private func fakeClaude(_ script: String, _ arguments: String...) -> ProcessLaunch {
    ProcessLaunch(
        executable: "/bin/sh",
        arguments: ["-c", script, "fake-claude"] + arguments,
        environment: [:],
        workingDirectory: FileManager.default.temporaryDirectory.path
    )
}

private let replayAnsweringOnePrompt = #"""
IFS= read -r brief
sed '/^$/q' "$1"
IFS= read -r answer
sed '1,/^$/d' "$1"
IFS= read -r rest || { printf '%s\n%s\n' "$brief" "$answer" > "$2.part" && mv "$2.part" "$2"; }
"""#

private func scratchFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "buddy-run-\(UUID().uuidString)")
}

@MainActor
private final class Events {
    var received: [RunEvent] = []
    private var waiter: (predicate: (RunEvent) -> Bool, continuation: CheckedContinuation<Void, Never>)?

    func append(_ event: RunEvent) {
        received.append(event)
        if let waiter, waiter.predicate(event) {
            self.waiter = nil
            waiter.continuation.resume()
        }
    }

    func next(where predicate: @escaping (RunEvent) -> Bool) async {
        await withCheckedContinuation { continuation in waiter = (predicate, continuation) }
    }
}

private func isEnd(_ event: RunEvent) -> Bool {
    switch event {
    case .finished, .failed: true
    default: false
    }
}

private func isApproval(_ event: RunEvent) -> Bool {
    if case .approvalRequested = event { true } else { false }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ClaudeRunTests {
    @Test func recordedRunReplaysThroughAProcessThatReadsTheBriefAndTheAnswer() async throws {
        let recording = try fixtureURL("run-denied")
        let saved = scratchFile()
        let events = Events()
        let run = RunProcess(
            launch: fakeClaude(replayAnsweringOnePrompt, recording.path, saved.path),
            stream: ClaudeRunStream(),
            brief: RunBrief(request: "Make a folder named made-by-probe in the run folder.", captures: []),
            folder: runFolder,
            onEvent: events.append
        )
        #expect(run.start() == nil)
        #expect(events.received == [])
        await events.next(where: isApproval)
        run.answer("00000000-0000-4000-8000-000000000004", .deny("Buddy doesn't allow this command."))
        await events.next(where: isEnd)
        #expect(events.received == [
            .started(folder: runFolder),
            .toolUsed,
            .approvalRequested(
                id: "00000000-0000-4000-8000-000000000004",
                .command(#"mkdir "/Users/owner/Library/Application Support/Buddy/Runs/2026-11-01-070412-1/made-by-probe""#)
            ),
            .finished(report: "Denied.")
        ])
        let closedAt = ContinuousClock.now
        while !FileManager.default.fileExists(atPath: saved.path) && ContinuousClock.now - closedAt < .seconds(5) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: saved, encoding: .utf8) == #"""
        {"message":{"content":[{"text":"Your run folder is /Users/owner/Library/Application Support/Buddy/Runs/2026-11-01-070412-1.\n\nThe owner asked: Make a folder named made-by-probe in the run folder.","type":"text"}],"role":"user"},"type":"user"}
        {"response":{"request_id":"00000000-0000-4000-8000-000000000004","response":{"behavior":"deny","message":"Buddy doesn't allow this command."},"subtype":"success"},"type":"control_response"}

        """#)
        try? FileManager.default.removeItem(at: saved)
    }

    @Test func processThatQuitsFailsTheRunWithItsLastErrorLine() async {
        let events = Events()
        let run = RunProcess(
            launch: fakeClaude(#"read brief; echo "error: unknown option '--permission-prompt-tool'" >&2; exit 1"#),
            stream: ClaudeRunStream(),
            brief: RunBrief(request: "List my open apps.", captures: []),
            folder: runFolder,
            onEvent: events.append
        )
        #expect(run.start() == nil)
        await events.next(where: isEnd)
        #expect(events.received == [.failed(.error("error: unknown option '--permission-prompt-tool'"))])
    }

    @Test func missingExecutableFailsToStart() {
        let run = RunProcess(
            launch: ProcessLaunch(executable: "/nonexistent/claude", arguments: [], environment: [:], workingDirectory: "/tmp"),
            stream: ClaudeRunStream(),
            brief: RunBrief(request: "List my open apps.", captures: []),
            folder: runFolder,
            onEvent: { _ in }
        )
        guard case .error(let detail) = run.start() else {
            Issue.record("expected the run to fail to start")
            return
        }
        #expect(detail.hasPrefix("it couldn't start. "))
    }

    @Test func stopKillsAProcessThatIgnoresTerminationAndSendsNoMoreEvents() async throws {
        let pidFile = scratchFile()
        let events = Events()
        let run = RunProcess(
            launch: fakeClaude(#"trap '' TERM; /bin/sleep 30 & child=$!; printf '%s\n%s\n' $$ "$child" > "$1"; echo '{"type":"system","subtype":"init"}'; wait"#, pidFile.path),
            stream: ClaudeRunStream(),
            brief: RunBrief(request: "List my open apps.", captures: []),
            folder: runFolder,
            onEvent: events.append
        )
        #expect(run.start() == nil)
        await events.next { $0 == .started(folder: runFolder) }
        let pids = try String(contentsOf: pidFile, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
        #expect(pids.count == 2)
        let stoppedAt = ContinuousClock.now
        run.stop()
        while pids.contains(where: { kill($0, 0) == 0 }) && ContinuousClock.now - stoppedAt < .seconds(5) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH })
        #expect(ContinuousClock.now - stoppedAt < .seconds(1))
        try await Task.sleep(for: .milliseconds(200))
        #expect(events.received == [.started(folder: runFolder)])
        try? FileManager.default.removeItem(at: pidFile)
    }
}
