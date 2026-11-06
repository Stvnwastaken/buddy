import BuddyCore
import Foundation
import os
import Security

/// Runs each agent run as a `claude -p` or `codex app-server` process in its own folder, and serves Buddy's tools to
/// them from one loopback MCP server.
final class AgentRunHost: AgentHost {
    private struct LiveRun {
        let token: String
        let report: (RunEvent) -> Void
        var process: RunProcess?
    }

    private struct WaitingCall {
        let run: RunID
        let call: MCPCall
        let respond: (HTTPResponse) -> Void
    }

    private struct Listening {
        let server: LoopbackServer
        let port: Task<Int, any Error>
    }

    private static let defaultRunsFolder = URL.applicationSupportDirectory.appending(path: "Buddy/Runs", directoryHint: .isDirectory)
    private static let codexHome = URL.applicationSupportDirectory.appending(path: "Buddy/Codex run home", directoryHint: .isDirectory)
    private static let folderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
    private static let runEnded = ToolAnswer(content: [.text("This run has ended.")], isError: true)

    private let runsFolder: URL
    private let launch: (ProviderCLI, ApprovalMode, URL, Int, String) throws -> ProcessLaunch?
    private var listening: Listening?
    private var folders: [RunID: URL] = [:]
    private var live: [RunID: LiveRun] = [:]
    private var calls: [ToolCallID: WaitingCall] = [:]
    private var callsReceived = 0

    init(
        runsFolder: URL = defaultRunsFolder,
        launch: @escaping (ProviderCLI, ApprovalMode, URL, Int, String) throws -> ProcessLaunch? = {
            try makeLaunch(
                cli: $0, approvalMode: $1, folder: $2, port: $3, token: $4,
                environment: ProcessInfo.processInfo.environment, codexHome: codexHome.path
            )
        }
    ) {
        self.runsFolder = runsFolder
        self.launch = launch
    }

    /// The CLI process for one run. A Codex run uses Buddy's own Codex home, `codexHome`, linked to the owner's sign-in.
    nonisolated static func makeLaunch(
        cli: ProviderCLI, approvalMode: ApprovalMode, folder: URL, port: Int, token: String,
        environment: [String: String], codexHome: String
    ) throws -> ProcessLaunch? {
        let mcpURL = URL(string: "http://127.0.0.1:\(port)/mcp")!
        switch cli {
        case .claudeCode:
            return ClaudeLaunch.run(
                environment: environment, folder: folder.path, mcpURL: mcpURL, token: token, approvalMode: approvalMode,
                isExecutable: FileManager.default.isExecutableFile
            )
        case .codex:
            guard let ownerHome = CodexLaunch.ownerHome(environment: environment) else { return nil }
            try CodexLaunch.linkSignIn(of: ownerHome, into: codexHome)
            return CodexLaunch.run(
                environment: environment, folder: folder.path, codexHome: codexHome, mcpURL: mcpURL, token: token,
                isExecutable: FileManager.default.isExecutableFile
            )
        }
    }

    func start(
        _ run: RunID, _ brief: RunBrief, on cli: ProviderCLI, approving mode: ApprovalMode,
        onEvent: @escaping (RunEvent) -> Void
    ) {
        let folder: URL
        do {
            folder = try Self.makeFolder(under: runsFolder, for: run, brief)
        } catch {
            return DispatchQueue.main.async { onEvent(.failed(.error("its run folder couldn't be made. \(error.localizedDescription)"))) }
        }
        folders[run] = folder
        launch(run, brief, on: cli, approving: mode, folder: folder, onEvent: onEvent)
    }

    func resume(
        _ run: RunID, _ brief: RunBrief, on cli: ProviderCLI, approving mode: ApprovalMode,
        onEvent: @escaping (RunEvent) -> Void
    ) {
        guard let folder = folders[run], live[run] == nil else { return }
        launch(run, brief, on: cli, approving: mode, folder: folder, onEvent: onEvent)
    }

    private func launch(
        _ run: RunID, _ brief: RunBrief, on cli: ProviderCLI, approving mode: ApprovalMode, folder: URL,
        onEvent: @escaping (RunEvent) -> Void
    ) {
        let token = Self.newToken()
        let report: (RunEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                guard self?.live[run]?.token == token else { return }
                onEvent(event)
            }
        }
        live[run] = LiveRun(token: token, report: report)
        Task {
            guard live[run]?.token == token else { return }
            let port: Int
            do {
                port = try await serverPort()
            } catch {
                guard live[run]?.token == token else { return }
                return report(.failed(.error("Buddy's tools couldn't start. \(error.localizedDescription)")))
            }
            guard live[run]?.token == token else { return }
            let made: ProcessLaunch?
            do {
                made = try launch(cli, mode, folder, port, token)
            } catch {
                return report(.failed(.error("it couldn't start. \(error.localizedDescription)")))
            }
            guard let launch = made else { return report(.failed(.notInstalled)) }
            let stream: any RunStream = cli == .codex ? CodexRunStream(approvalMode: mode) : ClaudeRunStream()
            let process = RunProcess(launch: launch, stream: stream, brief: brief, folder: folder.path, onEvent: report)
            live[run]?.process = process
            if let failure = process.start() { report(.failed(failure)) }
        }
    }

    func answerApproval(_ run: RunID, request: String, _ approval: Approval) {
        live[run]?.process?.answer(request, approval)
    }

    func answerTool(_ call: ToolCallID, _ answer: ToolAnswer) {
        guard let waiting = calls.removeValue(forKey: call) else { return }
        waiting.respond(MCPEndpoint.response(to: waiting.call, answer))
    }

    func isWaiting(_ call: ToolCallID, for run: RunID) -> Bool {
        calls[call]?.run == run
    }

    func saveNote(_ run: RunID, _ text: String) {
        save(text, as: "note.md", of: run)
    }

    func saveReport(_ run: RunID, _ text: String) {
        save(text, as: "report.md", of: run)
    }

    func stop(_ run: RunID) {
        guard let stopped = live.removeValue(forKey: run) else { return }
        for (id, waiting) in calls where waiting.run == run {
            calls[id] = nil
            waiting.respond(MCPEndpoint.response(to: waiting.call, Self.runEnded))
        }
        stopped.process?.stop()
    }

    func stopAll() {
        for run in Array(live.keys) { stop(run) }
        listening?.port.cancel()
        listening?.server.stop()
        listening = nil
    }

    private func serverPort() async throws -> Int {
        let listening = self.listening ?? startServer()
        do {
            return try await listening.port.value
        } catch {
            if self.listening?.server === listening.server { self.listening = nil }
            throw error
        }
    }

    private func startServer() -> Listening {
        let server = LoopbackServer { [weak self] request, respond in self?.serve(request, respond) }
        let listening = Listening(server: server, port: Task {
            try Task.checkCancellation()
            return try await server.start()
        })
        self.listening = listening
        return listening
    }

    private func serve(_ request: HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) {
        switch MCPEndpoint.handle(request, runFor: { token in live.first { $0.value.token == token }?.key }) {
        case .respond(let response):
            respond(response)
        case .call(let run, let call):
            guard let caller = live[run] else { return respond(MCPEndpoint.response(to: call, Self.runEnded)) }
            callsReceived += 1
            let id = ToolCallID(callsReceived)
            calls[id] = WaitingCall(run: run, call: call, respond: respond)
            caller.report(.toolCalled(id, call.tool))
        }
    }

    private func save(_ text: String, as name: String, of run: RunID) {
        guard let folder = folders[run] else { return }
        do {
            try Data(text.utf8).write(to: folder.appending(path: name), options: .atomic)
        } catch {
            Logger.turnTiming.error("\(run, privacy: .public) couldn't save \(name, privacy: .public): \(error.localizedDescription)")
        }
    }

    private static func makeFolder(under runsFolder: URL, for run: RunID, _ brief: RunBrief) throws -> URL {
        let folder = runsFolder.appending(
            path: "\(folderStamp.string(from: .now))-\(run.number)-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: runsFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for space in ["output", "scratch"] {
            try FileManager.default.createDirectory(at: folder.appending(path: space), withIntermediateDirectories: false)
        }
        try Data(brief.document.utf8).write(to: folder.appending(path: "brief.md"), options: .atomic)
        for (index, capture) in brief.captures.enumerated() {
            try capture.jpeg.write(to: folder.appending(path: "screen-\(index + 1).jpg"), options: .atomic)
        }
        try Data().write(to: folder.appending(path: "note.md"), options: .atomic)
        return folder
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "The system's secure random source failed.")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
