import Foundation
import Testing
import BuddyCore

/// One real agent run on the owner's Codex, driven the way the app drives it: the engine with its approval policy,
/// the run process and stream, and Buddy's MCP server. It denies whatever the policy leaves to the owner.
@MainActor
private final class LiveRun {
    private(set) var engine: BuddyEngine
    let folder: URL
    let codexHome: URL
    private let recording: String?
    private var server: LoopbackServer?
    private var process: RunProcess?
    private let token = UUID().uuidString
    private var calls: [ToolCallID: (call: MCPCall, respond: (HTTPResponse) -> Void)] = [:]
    private var callsReceived = 0
    private var answered: Set<String> = []
    private var ended: CheckedContinuation<Void, Never>?
    private(set) var deniedForOwner: [String] = []

    init(recording: String?) throws {
        let temporary = RunPath.resolve(FileManager.default.temporaryDirectory.path)!
        folder = URL(fileURLWithPath: temporary).appending(path: "buddy-live-run-\(UUID().uuidString)")
        codexHome = URL(fileURLWithPath: temporary).appending(path: "buddy-live-codex-home-\(UUID().uuidString)")
        self.recording = recording
        engine = BuddyEngine(
            providerConnected: true,
            runCLI: .codex,
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    func run(_ request: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        try CodexLaunch.linkSignIn(of: try #require(CodexLaunch.ownerHome(environment: environment)), into: codexHome.path)
        let server = LoopbackServer { [weak self] request, respond in self?.serve(request, respond) }
        self.server = server
        let port = try await server.start()
        await withCheckedContinuation { continuation in
            ended = continuation
            send([.pushToTalkPressed, .pushToTalkReleased, .transcriptFinished(request), .screensCaptured([])], port: port)
        }
        server.stop()
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: codexHome)
    }

    private func send(_ events: [BuddyEngine.Event], port: Int = 0) {
        var queue = events
        while !queue.isEmpty {
            let effects = engine.handle(queue.removeFirst())
            for effect in effects {
                queue += perform(effect, port: port)
            }
            queue += answerOwner()
        }
    }

    private func perform(_ effect: BuddyEngine.Effect, port: Int) -> [BuddyEngine.Event] {
        switch effect {
        case .speak: return [.lineStarted, .lineFinished]
        case .startRun(let id, let brief, let cli, _):
            #expect(cli == .codex)
            try! FileManager.default.createDirectory(at: folder.appending(path: "output"), withIntermediateDirectories: true)
            try! FileManager.default.createDirectory(at: folder.appending(path: "scratch"), withIntermediateDirectories: true)
            try! Data(brief.document.utf8).write(to: folder.appending(path: "brief.md"))
            var launch = CodexLaunch.run(
                environment: ProcessInfo.processInfo.environment, folder: folder.path, codexHome: codexHome.path,
                mcpURL: URL(string: "http://127.0.0.1:\(port)/mcp")!, token: token,
                isExecutable: FileManager.default.isExecutableFile
            )!
            if let recording {
                launch = ProcessLaunch(
                    executable: "/bin/sh",
                    arguments: ["-c", #""$@" | tee "$BUDDY_RECORDING""#, "record", launch.executable] + launch.arguments,
                    environment: launch.environment.merging(["BUDDY_RECORDING": recording]) { $1 },
                    workingDirectory: launch.workingDirectory
                )
            }
            let process = RunProcess(launch: launch, stream: CodexRunStream(), brief: brief, folder: folder.path) { [weak self] event in
                DispatchQueue.main.async { self?.send([.run(id, event)]) }
            }
            self.process = process
            if let failure = process.start() { return [.run(id, .failed(failure))] }
            return []
        case .answerApproval(_, let request, let approval):
            process?.answer(request, approval)
        case .answerTool(let id, let answer):
            if let waiting = calls.removeValue(forKey: id) { waiting.respond(MCPEndpoint.response(to: waiting.call, answer)) }
        case .captureScreensForTool(let id, let call):
            return [.run(id, .captureFailed(call, "This check has no screen to capture."))]
        case .saveRunNote(_, let text):
            try? Data(text.utf8).write(to: folder.appending(path: "note.md"))
        case .saveRunReport(_, let text):
            try? Data(text.utf8).write(to: folder.appending(path: "report.md"))
        case .stopRun:
            process?.stop()
            ended?.resume()
            ended = nil
        default:
            break
        }
        return []
    }

    /// Denies each approval the policy leaves to the owner, and answers a question with its first choice.
    private func answerOwner() -> [BuddyEngine.Event] {
        guard let run = engine.state.runs.first else { return [] }
        return run.asks.compactMap { ask in
            switch ask {
            case .approval(let id, let action, _):
                guard answered.insert("approval \(id)").inserted else { return nil }
                deniedForOwner.append(action)
                return .runApprovalAnswered(run.id, request: id, approved: false)
            case .question(let call, _, let choices):
                guard answered.insert("question \(call.number)").inserted else { return nil }
                return .runQuestionAnswered(run.id, call, choices.first ?? "Use your best judgment.")
            case .takeover(let call, _):
                guard answered.insert("takeover \(call.number)").inserted else { return nil }
                return .runTakeoverAnswered(run.id, call, approved: false)
            }
        }
    }

    private func serve(_ request: HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) {
        switch MCPEndpoint.handle(request, runFor: { [token] in $0 == token ? RunID(1) : nil }) {
        case .respond(let response):
            respond(response)
        case .call(let run, let call):
            callsReceived += 1
            let id = ToolCallID(callsReceived)
            calls[id] = (call, respond)
            send([.run(run, .toolCalled(id, call.tool))])
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(10)))
struct LiveCodexRunTests {
    nonisolated private static let enabled = ProcessInfo.processInfo.environment["BUDDY_LIVE_CODEX_RUN"] == "1"

    @Test(.enabled(if: enabled, "set BUDDY_LIVE_CODEX_RUN=1 to spend one small real run"))
    func liveCodexRunAsksBuddyBeforeEachCommandAndFileChange() async throws {
        let live = try LiveRun(recording: ProcessInfo.processInfo.environment["BUDDY_RECORD_CODEX_RUN"])
        defer { live.remove() }
        try await live.run(
            "agent, in your run folder: set your run note to a one-step plan, run mkdir output/made-by-probe, "
                + "create output/made-by-probe/hello.txt containing hi with apply_patch, then run cd output, "
                + "which Buddy declines, so don't retry it. Then report."
        )
        let run = try #require(live.engine.state.runs.first)
        #expect(run.status == .done)
        #expect(try String(contentsOf: live.folder.appending(path: "output/made-by-probe/hello.txt"), encoding: .utf8) == "hi\n")
        #expect(run.denials.contains { $0.action.hasPrefix("cd ") })
        #expect(!run.note.isEmpty)
        #expect(live.deniedForOwner == [])
    }

    /// The first agent ticket's check: a new Desktop folder with a text file listing the open apps.
    @Test(.enabled(if: enabled, "set BUDDY_LIVE_CODEX_RUN=1 to spend one small real run"))
    func liveCodexRunMakesTheDesktopFolderAndAppList() async throws {
        let name = "Buddy-issue29-\(UUID().uuidString.prefix(8))"
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/\(name)")
        let live = try LiveRun(recording: ProcessInfo.processInfo.environment["BUDDY_RECORD_CODEX_RUN"])
        defer { live.remove() }
        try await live.run("agent, make a folder named \(name) on my Desktop with a text file listing my open apps")
        let run = try #require(live.engine.state.runs.first)
        print("LIVE outcome=\(run.status) owner-denied=\(live.deniedForOwner) denials=\(run.denials.map { "\($0.action): \($0.reason)" })")
        print("LIVE report=\(run.report ?? "")")
        print("LIVE note=\(run.note)")
        let files = try FileManager.default.contentsOfDirectory(atPath: desktop.path).filter { $0.hasSuffix(".txt") }
        let list = try String(contentsOf: desktop.appending(path: try #require(files.first)), encoding: .utf8)
        print("LIVE files=\(files) lines=\(list.split(separator: "\n").count)")
        #expect(run.status == .done)
        #expect(!list.isEmpty)
        #expect(live.deniedForOwner == [])
    }
}
