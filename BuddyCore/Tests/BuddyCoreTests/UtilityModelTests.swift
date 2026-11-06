import Foundation
import Testing
import BuddyCore

@MainActor
private func answer(from utility: UtilityModel, to question: String) async -> Result<String, ProviderFailure> {
    await withCheckedContinuation { continuation in
        utility.ask(question) { continuation.resume(returning: $0) }
    }
}

/// Answers every message with two text deltas naming the process and how many messages it has read.
private let numberedAnswers = #"""
n=0
while IFS= read -r line; do
  n=$((n+1))
  printf '%s\n' "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"process $$ \"}}}"
  printf '%s\n' "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"message $n\"}}}"
  printf '%s\n' '{"type":"result","is_error":false}'
done
"""#

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct UtilityModelTests {
    @Test func eachQuestionIsAnsweredByAFreshWarmProcess() async throws {
        var launches = 0
        let utility = UtilityModel(ClaudeBrain {
            launches += 1
            return ProcessLaunch(executable: "/bin/sh", arguments: ["-c", numberedAnswers], environment: [:], workingDirectory: "/tmp")
        })
        defer { utility.stop() }
        utility.start()
        #expect(launches == 1)
        let first = try #require(try? await answer(from: utility, to: "Summarize one.").get())
        #expect(launches == 2)
        let second = try #require(try? await answer(from: utility, to: "Summarize two.").get())
        #expect(launches == 3)
        #expect(first.hasSuffix(" message 1"))
        #expect(second.hasSuffix(" message 1"))
        #expect(first != second)
    }

    @Test func aQuestionReachesTheModelAsItsTextAloneWithoutTheOwnersProfile() async throws {
        let wire = FileManager.default.temporaryDirectory.appending(path: "buddy-utility-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: wire) }
        let script = #"while IFS= read -r line; do printf '%s\n' "$line" >> "$1"; printf '%s\n' '{"type":"result","is_error":false}'; done"#
        let utility = UtilityModel(ClaudeBrain {
            ProcessLaunch(executable: "/bin/sh", arguments: ["-c", script, "sh", wire.path], environment: [:], workingDirectory: "/tmp")
        })
        defer { utility.stop() }
        #expect(await answer(from: utility, to: "Summarize one.") == .success(""))
        let line = try String(contentsOf: wire, encoding: .utf8).trimmingCharacters(in: .newlines)
        let message = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])["message"] as? [String: Any]
        #expect((message?["content"] as? [[String: String]]) == [["type": "text", "text": "Summarize one."]])
    }

    @Test func aSelectionChangeWaitsForTheQuestionBeingAnswered() async throws {
        var launches = 0
        let utility = UtilityModel(ClaudeBrain {
            launches += 1
            return ProcessLaunch(executable: "/bin/sh", arguments: ["-c", "sleep 0.3; " + numberedAnswers], environment: [:], workingDirectory: "/tmp")
        })
        defer { utility.stop() }
        utility.start()
        let answered = Task { await answer(from: utility, to: "Summarize.") }
        try await Task.sleep(for: .milliseconds(50))
        utility.refresh()
        #expect(launches == 1)
        #expect(try await answered.value.get().hasSuffix(" message 1"))
        #expect(launches == 2)
        utility.refresh()
        #expect(launches == 3)
    }

    @Test func stoppingFailsTheQuestionBeingAnswered() async throws {
        let utility = UtilityModel(ClaudeBrain {
            ProcessLaunch(executable: "/bin/sh", arguments: ["-c", "sleep 5; " + numberedAnswers], environment: [:], workingDirectory: "/tmp")
        })
        var answers: [Result<String, ProviderFailure>] = []
        utility.ask("Summarize.") { answers.append($0) }
        utility.stop()
        #expect(answers == [.failure(.error("the question was dropped"))])
        try await Task.sleep(for: .milliseconds(100))
        #expect(answers == [.failure(.error("the question was dropped"))])
    }

    @Test func aMissingClaudeFailsTheQuestion() async {
        let utility = UtilityModel(ClaudeBrain { nil })
        #expect(await answer(from: utility, to: "Summarize.") == .failure(.notInstalled))
    }

    @Test func utilityRunsOnTheSmallModelWithItsOwnInstructionsAndNoTools() {
        let direct = ClaudeLaunch.utility(
            environment: ["HOME": "/Users/owner", "PATH": "/usr/bin", "ANTHROPIC_BASE_URL": "https://wrong.example"],
            workingDirectory: "/tmp/utility",
            isExecutable: { $0 == "/Users/owner/.local/bin/claude" }
        )
        #expect(direct == ProcessLaunch(
            executable: "/Users/owner/.local/bin/claude",
            arguments: [
                "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--include-partial-messages",
                "--verbose",
                "--model", "haiku",
                "--system-prompt", UtilityInstructions.system,
                "--tools", "",
                "--setting-sources", "",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--no-session-persistence"
            ],
            environment: ["HOME": "/Users/owner", "PATH": "/Users/owner/.local/bin:/usr/bin"],
            workingDirectory: "/tmp/utility"
        ))

        let proxied = ClaudeLaunch.utility(
            environment: ["HOME": "/Users/owner", "PATH": "/usr/bin", "CLAUDE_CODE_OAUTH_TOKEN": "local-login"],
            workingDirectory: "/tmp/utility",
            proxy: ClaudeProxy(baseURL: "https://hub.example:8317", token: "hub-access", model: "buddy-account/claude-haiku-5-5"),
            isExecutable: { $0 == "/Users/owner/.local/bin/claude" }
        )
        #expect(proxied?.environment == [
            "HOME": "/Users/owner", "PATH": "/Users/owner/.local/bin:/usr/bin",
            "ANTHROPIC_BASE_URL": "https://hub.example:8317", "ANTHROPIC_AUTH_TOKEN": "hub-access"
        ])
        #expect(proxied?.arguments.contains("buddy-account/claude-haiku-5-5") == true)
        #expect(proxied?.arguments.contains("haiku") == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_LIVE_CLAUDE"] == "1", "set BUDDY_LIVE_CLAUDE=1 to spend three tiny real turns"))
    func liveClaudeCarriesAFactIntoTheNextConversation() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-live-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ProcessInfo.processInfo.environment
        let brain = ClaudeBrain { ClaudeLaunch.talk(environment: environment, workingDirectory: folder.path, isExecutable: FileManager.default.isExecutableFile) }
        let utility = UtilityModel(ClaudeBrain { ClaudeLaunch.utility(environment: environment, workingDirectory: folder.path, isExecutable: FileManager.default.isExecutableFile) })
        defer { brain.stop(); utility.stop() }
        utility.start()
        var engine = BuddyEngine(providerConnected: true)
        var sent: [TurnRequest] = []
        var replies: [String] = []
        var summaries: [String] = []

        func perform(_ effects: [BuddyEngine.Effect]) async {
            for effect in effects {
                switch effect {
                case .sendTurn(let turn):
                    sent.append(turn)
                    let events: [ProviderEvent] = await withCheckedContinuation { continuation in
                        var events: [ProviderEvent] = []
                        brain.send(turn) { event in
                            events.append(event)
                            switch event {
                            case .completed, .failed: continuation.resume(returning: events)
                            case .textDelta, .usage, .searching: break
                            }
                        }
                    }
                    replies.append(events.compactMap { if case .textDelta(let text) = $0 { text } else { nil } }.joined())
                    for event in events { await perform(engine.handle(.provider(event))) }
                case .speak:
                    await perform(engine.handle(.lineStarted))
                    await perform(engine.handle(.lineFinished))
                case .resetProvider:
                    brain.stop()
                case .writeSummary(let request):
                    let answer = await withCheckedContinuation { continuation in utility.ask(request.prompt) { continuation.resume(returning: $0) } }
                    let text = try? answer.get()
                    summaries.append(text ?? "")
                    await perform(engine.handle(text.map { .summaryWritten(id: request.id, $0) } ?? .summaryFailed(id: request.id)))
                default:
                    break
                }
            }
        }

        func ask(_ question: String) async {
            await perform(engine.handle(.pushToTalkPressed))
            await perform(engine.handle(.pushToTalkReleased))
            await perform(engine.handle(.transcriptFinished(question)))
            await perform(engine.handle(.screensCaptured([])))
        }

        await ask("My paper kite is named Copper Finch. Reply with only the word noted.")
        await ask("New conversation.")
        await ask("What is my paper kite named? Answer with only its name.")
        #expect(summaries.count == 1)
        #expect(summaries.first?.contains("Copper Finch") == true)
        #expect(engine.state.history.conversations.count == 2)
        #expect(engine.state.history.conversations[0].summary?.turns == 1)
        #expect(sent.last?.earlierSummaries == summaries)
        #expect(replies.count == 2)
        #expect(replies.last?.contains("Copper Finch") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [])
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_LIVE_CLAUDE"] == "1", "set BUDDY_LIVE_CLAUDE=1 to spend five tiny real turns"))
    func liveClaudeReopensItsOwnContextAndDeletesAnotherConversation() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "buddy-live-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ProcessInfo.processInfo.environment
        let brain = ClaudeBrain { ClaudeLaunch.talk(environment: environment, workingDirectory: folder.path, isExecutable: FileManager.default.isExecutableFile) }
        let utility = UtilityModel(ClaudeBrain { ClaudeLaunch.utility(environment: environment, workingDirectory: folder.path, isExecutable: FileManager.default.isExecutableFile) })
        defer { brain.stop(); utility.stop() }
        utility.start()
        var engine = BuddyEngine(providerConnected: true)
        var sent: [TurnRequest] = []
        var replies: [String] = []
        let historyURL = folder.appending(path: "history.json")

        func perform(_ effects: [BuddyEngine.Effect]) async {
            for effect in effects {
                switch effect {
                case .sendTurn(let turn):
                    sent.append(turn)
                    let events: [ProviderEvent] = await withCheckedContinuation { continuation in
                        var events: [ProviderEvent] = []
                        brain.send(turn) { event in
                            events.append(event)
                            switch event {
                            case .completed, .failed: continuation.resume(returning: events)
                            case .textDelta, .usage, .searching: break
                            }
                        }
                    }
                    replies.append(events.compactMap { if case .textDelta(let text) = $0 { text } else { nil } }.joined())
                    for event in events { await perform(engine.handle(.provider(event))) }
                case .saveHistory(let history):
                    do { try JSONEncoder().encode(history).write(to: historyURL, options: .atomic) }
                    catch { Issue.record("Saving owned history failed: \(error)") }
                case .speak:
                    await perform(engine.handle(.lineStarted))
                    await perform(engine.handle(.lineFinished))
                case .resetProvider:
                    brain.stop()
                case .writeSummary(let request):
                    let answer = await withCheckedContinuation { continuation in utility.ask(request.prompt) { continuation.resume(returning: $0) } }
                    let text = try? answer.get()
                    await perform(engine.handle(text.map { .summaryWritten(id: request.id, $0) } ?? .summaryFailed(id: request.id)))
                default:
                    break
                }
            }
        }

        func ask(_ question: String) async {
            await perform(engine.handle(.pushToTalkPressed))
            await perform(engine.handle(.pushToTalkReleased))
            await perform(engine.handle(.transcriptFinished(question)))
            await perform(engine.handle(.screensCaptured([])))
        }

        await ask("My paper kite is named Copper Finch. Reply with only the word noted.")
        await perform(engine.handle(.newConversationRequested))
        await ask("My paper kite is named Azure Heron now. Reply with only the word noted.")
        await perform(engine.handle(.conversationsRequested))
        await perform(engine.handle(.conversationOpened(0)))
        await ask("In THIS conversation, what did I name my paper kite? Answer only with the name established here, ignoring other conversations.")
        #expect(replies.count == 3)
        #expect(replies.last?.contains("Copper Finch") == true)
        #expect(replies.last?.contains("Azure Heron") == false)
        #expect(sent.last?.summary?.contains("Copper Finch") == true)
        #expect(engine.state.history.conversations.last?.id == 0)
        #expect(engine.state.history.conversations.last?.turns.count == 2)
        #expect(engine.state.history.conversations.first { $0.id == 1 }?.summary?.text.contains("Azure Heron") == true)
        print("LIVE_REOPEN answer=\(replies.last ?? "")")
        await perform(engine.handle(.conversationDeleted(1)))
        let bytes = try Data(contentsOf: historyURL)
        let restored = try JSONDecoder().decode(ConversationHistory.self, from: bytes)
        #expect(restored.conversations.map(\.id) == [0])
        #expect(String(decoding: bytes, as: UTF8.self).contains("Azure Heron") == false)
        engine = BuddyEngine(providerConnected: true, history: restored)
        await perform(engine.handle(.textBoxFocused))
        await perform(engine.handle(.textBoxSubmitted("What do you remember?")))
        let effects = engine.handle(.screensCaptured([]))
        let next = try #require(effects.compactMap { if case .sendTurn(let request) = $0 { request } else { nil } }.first)
        #expect(next.earlierSummaries == [])
        #expect(next.summary?.contains("Copper Finch") == true)
        #expect(next.earlierSummaries.contains { $0.contains("Azure Heron") } == false)
        #expect(next.summary?.contains("Azure Heron") == false)
        #expect(next.recentTurns.map(\.transcript) == ["In THIS conversation, what did I name my paper kite? Answer only with the name established here, ignoring other conversations."])
        #expect(next.recentTurns.allSatisfy { !$0.reply.contains("Azure Heron") })
        print("LIVE_DELETE reloadedIDs=\(restored.conversations.map(\.id)) deletedTurnsAndSummaryAbsent=true nextContext=\(next.earlierSummaries)")
    }

}
