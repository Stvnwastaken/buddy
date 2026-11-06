import Foundation

/// What a Codex thread is for: its instructions, and the models it prefers over Codex's default, best first.
public struct CodexThread: Equatable, Sendable {
    public let instructions: String
    public let preferredModels: [String]

    public init(instructions: String, preferredModels: [String] = []) {
        self.instructions = instructions
        self.preferredModels = preferredModels
    }

    public static let talk = CodexThread(instructions: TalkInstructions.system)
}

/// The JSON-RPC exchange with one `codex app-server` process: the requests to write for each turn, and the provider
/// events in what the process prints back.
///
/// Before the first turn the process must be signed in to ChatGPT, and one thread is started for the conversation
/// with its `CodexThread` instructions, the first preferred model Codex offers or else Codex's default, and every MCP
/// server in the owner's config turned off. The thread's first turn carries the conversation's recent turns, and later
/// turns rely on the thread's own context. Each turn's screenshots go in as files in `imageFolder`, deleted when the
/// turn ends. A cancelled turn is interrupted and the rest of its text dropped. The thread runs one turn at a time, so
/// the next turn waits for the interrupted one to complete.
public struct CodexStream: Sendable {
    public enum Output: Equatable, Sendable {
        case write(Data)
        case event(ProviderEvent)
        /// The process can't serve another turn, so the next turn needs a new one.
        case endProcess
        /// The file must be on disk before the next `write`, which names it.
        case saveFile(path: String, contents: Data)
        case deleteFiles([String])
    }

    private enum Setup: Sendable {
        case connecting
        case preparing(Preparation)
        case startingThread
        case ready(thread: String, primed: Bool)
        case unusable
    }

    private struct Preparation: Sendable {
        var signedIn: Bool?
        var mcpServers: [String]?
        var model: String?
    }

    private enum Request: Sendable {
        case initialize, account, rateLimits, config, models, threadStart, turnStart, interrupt, unsubscribe
    }

    private struct ThreadConfiguration: Sendable {
        let mcpServers: [String]
        let model: String
    }

    private struct Turn: Sendable {
        let requestID: Int
        let thread: String
        let screenshots: [String]
        var id: String?
        var cancelled = false
        var lastMessageID: String?
        var releaseThreadWhenFinished = false
    }

    private let imageFolder: String
    private let thread: CodexThread
    private var setup = Setup.connecting
    private var threadConfiguration: ThreadConfiguration?
    private var pending: [Int: Request] = [:]
    private var nextRequest = 1
    private var turn: Turn?
    private var waiting: TurnRequest?
    private var turnsStarted = 0
    private var lines = LineBuffer()

    public init(imageFolder: String, thread: CodexThread = .talk) {
        self.imageFolder = imageFolder
        self.thread = thread
    }

    /// The process has just started.
    public mutating func start() -> [Output] {
        [request(.initialize, "initialize", ["clientInfo": ["name": "buddy", "version": "1.0"]])]
    }

    /// Cancels any turn in flight, which the new turn waits for.
    public mutating func send(_ turn: TurnRequest) -> [Output] {
        let outputs = cancel()
        waiting = turn
        return outputs + startWaitingTurn()
    }

    public mutating func cancel() -> [Output] {
        waiting = nil
        guard turn?.cancelled == false else { return [] }
        turn?.cancelled = true
        return interrupt()
    }

    /// Starts a fresh thread on the same process and lets go of the old one once its turn has ended.
    public mutating func endConversation() -> [Output] {
        var outputs = cancel()
        guard case .ready(let thread, _) = setup, let configuration = threadConfiguration else { return outputs }
        outputs.append(startThread(configuration))
        if turn?.thread == thread {
            turn?.releaseThreadWhenFinished = true
        } else {
            outputs.append(unsubscribe(thread))
        }
        return outputs
    }

    /// Takes whatever the process printed, in chunks split anywhere.
    public mutating func received(_ chunk: Data) -> [Output] {
        lines.lines(after: chunk).flatMap { handle($0) }
    }

    /// The process exited. A turn still waiting for its answer fails with the last line the process wrote to stderr.
    public mutating func ended(stderr: String) -> [Output] {
        let failing = waiting != nil || turn?.cancelled == false
        let screenshots = turn?.screenshots ?? []
        self = CodexStream(imageFolder: imageFolder, thread: thread)
        return (failing ? [.event(.failed(.error(lastLine(of: stderr) ?? "it quit unexpectedly")))] : [])
            + (screenshots.isEmpty ? [] : [.deleteFiles(screenshots)])
    }

    private mutating func handle(_ line: Data) -> [Output] {
        guard let message = try? JSONDecoder().decode(RPCEnvelope.self, from: line) else { return [] }
        switch (message.id, message.method) {
        case (let id?, _?):
            return [.write(jsonLine([
                "id": id.json,
                "error": ["code": -32601, "message": "Buddy answers no requests during talk."]
            ]))]
        case (nil, let method?):
            return notification(method, line)
        case (.number(let id)?, nil):
            guard let request = pending.removeValue(forKey: id) else { return [] }
            return response(to: request, id: id, line, error: message.error)
        default:
            return []
        }
    }

    private mutating func response(to request: Request, id: Int, _ line: Data, error: RPCError?) -> [Output] {
        switch request {
        case .initialize:
            if let error { return failSetup(error.message) }
            setup = .preparing(Preparation())
            return [
                .write(jsonLine(["method": "initialized"])),
                self.request(.account, "account/read", [:]),
                self.request(.rateLimits, "account/rateLimits/read", nil),
                self.request(.config, "config/read", [:]),
                self.request(.models, "model/list", [:])
            ]
        case .account:
            if let error { return failSetup(error.message) }
            let account = result(AccountResult.self, in: line)?.account
            return prepared { $0.signedIn = account?.type == "chatgpt" }
        case .rateLimits:
            return result(RateLimitsResult.self, in: line)?.rateLimits.usage.map { [.event(.usage($0))] } ?? []
        case .config:
            if let error { return failSetup(error.message) }
            guard let config = result(ConfigResult.self, in: line)?.config else {
                return failSetup("it returned an unreadable configuration")
            }
            let servers = config.mcpServers?.keys.sorted() ?? []
            return prepared { $0.mcpServers = servers }
        case .models:
            if let error { return failSetup(error.message) }
            let models = result(ModelsResult.self, in: line)?.data ?? []
            let preferred = thread.preferredModels.first { name in models.contains { $0.model == name } }
            guard let model = preferred ?? (models.first { $0.isDefault == true } ?? models.first)?.model else {
                return failSetup("it offered no models")
            }
            return prepared { $0.model = model }
        case .threadStart:
            if let error { return failSetup(error.message) }
            guard let thread = result(ThreadStartResult.self, in: line)?.thread.id else { return failSetup("it started no thread") }
            setup = .ready(thread: thread, primed: false)
            return startWaitingTurn()
        case .turnStart:
            guard turn?.requestID == id else { return [] }
            if let error { return finishTurn(failure: .error(firstLine(of: error.message))) }
            guard let accepted = result(TurnStartResult.self, in: line)?.turn.id else {
                setup = .unusable
                let failure = ProviderFailure.error("it started no turn")
                return finishTurn(failure: failure) + failWaitingTurn(failure) + [.endProcess]
            }
            turn?.id = accepted
            return turn?.cancelled == true ? interrupt() : []
        case .interrupt, .unsubscribe:
            return []
        }
    }

    private mutating func notification(_ method: String, _ line: Data) -> [Output] {
        switch method {
        case "item/agentMessage/delta":
            guard let delta = params(MessageDelta.self, in: line),
                  let current = turn, current.id == delta.turnId, !current.cancelled else { return [] }
            let newMessage = current.lastMessageID.map { $0 != delta.itemId } ?? false
            turn?.lastMessageID = delta.itemId
            return (newMessage ? [.event(.textDelta("\n"))] : []) + [.event(.textDelta(delta.delta))]
        case "item/started":
            guard let started = params(ItemStarted.self, in: line), started.item.type == "webSearch",
                  let current = turn, current.id == started.turnId, !current.cancelled else { return [] }
            return [.event(.searching)]
        case "turn/completed":
            guard let completed = params(TurnCompleted.self, in: line)?.turn,
                  turn?.id == completed.id else { return [] }
            switch completed.status {
            case "completed": return finishTurn(failure: nil)
            case "interrupted": return finishTurn(failure: .error("it was interrupted"))
            default:
                let error = completed.error
                if error?.codexErrorInfo == "unauthorized" { return finishTurn(failure: .signedOut) }
                if error?.codexErrorInfo == "usageLimitExceeded" { return finishTurn(failure: .limitReached) }
                return finishTurn(failure: .error(error.map { firstLine(of: $0.message) } ?? "it returned an error"))
            }
        case "account/rateLimits/updated":
            return params(RateLimitsResult.self, in: line)?.rateLimits.usage.map { [.event(.usage($0))] } ?? []
        default:
            return []
        }
    }

    private mutating func prepared(_ update: (inout Preparation) -> Void) -> [Output] {
        guard case .preparing(var known) = setup else { return [] }
        update(&known)
        setup = .preparing(known)
        if known.signedIn == false {
            setup = .unusable
            return failWaitingTurn(.signedOut) + [.endProcess]
        }
        guard known.signedIn == true, let servers = known.mcpServers, let model = known.model else { return [] }
        let configuration = ThreadConfiguration(mcpServers: servers, model: model)
        threadConfiguration = configuration
        return [startThread(configuration)]
    }

    private mutating func startThread(_ configuration: ThreadConfiguration) -> Output {
        setup = .startingThread
        return request(.threadStart, "thread/start", [
            "approvalPolicy": "never",
            "baseInstructions": thread.instructions,
            "config": Dictionary(uniqueKeysWithValues: configuration.mcpServers.map { ("mcp_servers.\($0).enabled", false) }),
            "ephemeral": true,
            "model": configuration.model,
            "sandbox": "read-only"
        ])
    }

    private mutating func startWaitingTurn() -> [Output] {
        guard case .ready(let thread, let primed) = setup, turn == nil, let waiting else { return [] }
        self.waiting = nil
        setup = .ready(thread: thread, primed: true)
        let request = primed ? waiting.withoutPriming : waiting
        turnsStarted += 1
        var screenshots: [(path: String, jpeg: Data)] = []
        let input: [[String: Any]] = request.content.map { part in
            switch part {
            case .text(let text):
                return ["type": "text", "text": text]
            case .jpeg(let jpeg):
                let path = "\(imageFolder)/turn-\(turnsStarted)-screen-\(screenshots.count + 1).jpg"
                screenshots.append((path, jpeg))
                return ["type": "localImage", "path": path]
            }
        }
        let id = nextRequest
        let start = self.request(.turnStart, "turn/start", ["threadId": thread, "input": input])
        turn = Turn(requestID: id, thread: thread, screenshots: screenshots.map(\.path))
        return screenshots.map { .saveFile(path: $0.path, contents: $0.jpeg) } + [start]
    }

    private mutating func finishTurn(failure: ProviderFailure?) -> [Output] {
        guard let finished = turn else { return [] }
        turn = nil
        var outputs: [Output] = []
        if !finished.cancelled {
            outputs.append(.event(failure.map(ProviderEvent.failed) ?? .completed))
        }
        if !finished.screenshots.isEmpty {
            outputs.append(.deleteFiles(finished.screenshots))
        }
        if finished.releaseThreadWhenFinished {
            outputs.append(unsubscribe(finished.thread))
        }
        if !finished.cancelled && failure == .signedOut {
            setup = .unusable
            return outputs + [.endProcess]
        }
        return outputs + startWaitingTurn()
    }

    private mutating func interrupt() -> [Output] {
        guard let turn, let id = turn.id else { return [] }
        return [request(.interrupt, "turn/interrupt", ["threadId": turn.thread, "turnId": id])]
    }

    private mutating func unsubscribe(_ thread: String) -> Output {
        request(.unsubscribe, "thread/unsubscribe", ["threadId": thread])
    }

    private mutating func failSetup(_ message: String) -> [Output] {
        setup = .unusable
        return failWaitingTurn(.error(firstLine(of: message))) + [.endProcess]
    }

    private mutating func failWaitingTurn(_ failure: ProviderFailure) -> [Output] {
        guard waiting != nil else { return [] }
        waiting = nil
        return [.event(.failed(failure))]
    }

    private mutating func request(_ kind: Request, _ method: String, _ params: [String: Any]?) -> Output {
        let id = nextRequest
        nextRequest += 1
        pending[id] = kind
        var message: [String: Any] = ["id": id, "method": method]
        message["params"] = params
        return .write(jsonLine(message))
    }
}

/// Codex's usage windows. Only the 5-hour and 7-day windows count, matched by their length.
private struct RateLimitsResult: Decodable {
    struct Snapshot: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let windowDurationMins: Int?
            let resetsAt: TimeInterval?
        }
        let primary: Window?
        let secondary: Window?

        var usage: ProviderUsage? {
            let windows = [primary, secondary].compactMap { $0 }
            func window(lasting minutes: Int) -> UsageWindow? {
                guard let window = windows.first(where: { $0.windowDurationMins == minutes }),
                      let resetsAt = window.resetsAt else { return nil }
                return UsageWindow(utilization: window.usedPercent / 100, resetsAt: Date(timeIntervalSince1970: resetsAt))
            }
            let fiveHour = window(lasting: 300), sevenDay = window(lasting: 10_080)
            guard fiveHour != nil || sevenDay != nil else { return nil }
            return ProviderUsage(fiveHour: fiveHour, sevenDay: sevenDay)
        }
    }
    let rateLimits: Snapshot
}

private struct ItemStarted: Decodable {
    struct Item: Decodable { let type: String }
    let turnId: String
    let item: Item
}
