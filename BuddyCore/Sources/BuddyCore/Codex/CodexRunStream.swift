import Foundation

/// The JSON-RPC exchange with the `codex app-server` process of one agent run: the requests to write, the run events
/// in what the process prints back, and the answers to its approval requests.
///
/// The process must be signed in to ChatGPT. The run is one ephemeral thread in the run folder with Buddy's run
/// instructions. It has full disk access, because AppleScript can't reach other apps inside Codex's sandbox, and the
/// folder is an untrusted project, so Codex asks before every command and file change. The brief goes in only once
/// the started thread confirms that Codex will ask Buddy. A denied request is declined, and its reason is steered
/// into the turn, since a declined request tells the run nothing more. The run ends when its one turn completes, and
/// its last message is the report.
public struct CodexRunStream: RunStream {
    private enum Phase {
        case connecting
        case signingIn
        case startingThread
        case working(thread: String, cwd: String)
        case finished
    }

    private enum Request {
        case initialize, account, threadStart, turnStart, steer
    }

    private struct WaitingApproval {
        let id: RequestID
        let turn: String
        let action: String
    }

    /// Item kinds that are tool uses, each one step of the run.
    private static let tools: Set = ["commandExecution", "fileChange", "mcpToolCall", "imageView", "webSearch", "dynamicToolCall"]

    private var brief = RunBrief(request: "", captures: [])
    private var folder = ""
    private var phase = Phase.connecting
    private var pending: [Int: Request] = [:]
    private var nextRequest = 1
    private var approvals: [String: WaitingApproval] = [:]
    /// The files each patch in progress changes, by its item id. Codex's approval request names only the item.
    private var patches: [String: [ApprovalRequest]] = [:]
    private var lastMessage: String?
    private var lines = LineBuffer()
    private let approvalMode: ApprovalMode

    /// A run whose requests are approved in `approvalMode`, which picks its instructions.
    public init(approvalMode: ApprovalMode = .auto) {
        self.approvalMode = approvalMode
    }

    public mutating func start(_ brief: RunBrief, folder: String) -> [RunStreamOutput] {
        self.brief = brief
        self.folder = folder
        return [request(.initialize, "initialize", ["clientInfo": ["name": "buddy", "version": "1.0"]])]
    }

    public mutating func received(_ chunk: Data) -> [RunStreamOutput] {
        lines.lines(after: chunk).flatMap { handle($0) }
    }

    public mutating func answer(_ requestID: String, _ approval: Approval) -> [RunStreamOutput] {
        guard let waiting = approvals.removeValue(forKey: requestID), case .working(let thread, _) = phase else { return [] }
        switch approval {
        case .allow:
            return [decision(waiting.id, "accept")]
        case .deny(let reason):
            let steer = request(.steer, "turn/steer", [
                "threadId": thread,
                "expectedTurnId": waiting.turn,
                "input": [["type": "text", "text": "Buddy declined `\(waiting.action)`. \(reason)"]]
            ])
            return [steer, decision(waiting.id, "decline")]
        }
    }

    public mutating func ended(stderr: String) -> [RunStreamOutput] {
        if case .finished = phase { return [] }
        phase = .finished
        return [.event(.failed(.error(lastLine(of: stderr) ?? "it quit unexpectedly")))]
    }

    private mutating func handle(_ line: Data) -> [RunStreamOutput] {
        guard let message = try? JSONDecoder().decode(RPCEnvelope.self, from: line) else { return [] }
        if case .finished = phase { return [] }
        switch (message.id, message.method) {
        case (let id?, let method?):
            return serverRequest(method, id: id, line)
        case (nil, let method?):
            return notification(method, line)
        case (.number(let id)?, nil):
            guard let request = pending.removeValue(forKey: id) else { return [] }
            return response(to: request, line, error: message.error)
        default:
            return []
        }
    }

    private mutating func response(to request: Request, _ line: Data, error: RPCError?) -> [RunStreamOutput] {
        if let error, request != .steer { return fail(.error(firstLine(of: error.message))) }
        switch request {
        case .initialize:
            phase = .signingIn
            return [.write(jsonLine(["method": "initialized"])), self.request(.account, "account/read", [:])]
        case .account:
            guard result(AccountResult.self, in: line)?.account?.type == "chatgpt" else { return fail(.signedOut) }
            phase = .startingThread
            return [self.request(.threadStart, "thread/start", [
                "approvalsReviewer": "user",
                "baseInstructions": RunInstructions.system(for: approvalMode),
                "config": ["projects": [folder: ["trust_level": "untrusted"]]],
                "cwd": folder,
                "ephemeral": true,
                "sandbox": "danger-full-access"
            ])]
        case .threadStart:
            guard let started = result(RunThreadStart.self, in: line) else { return fail(.error("it started no thread")) }
            guard started.approvalPolicy == "untrusted", started.approvalsReviewer == "user" else {
                return fail(.error("it wouldn't ask Buddy before each command"))
            }
            phase = .working(thread: started.thread.id, cwd: started.cwd ?? folder)
            return [.event(.started(folder: folder)), self.request(.turnStart, "turn/start", [
                "threadId": started.thread.id,
                "input": briefInput()
            ])]
        case .turnStart, .steer:
            return []
        }
    }

    private mutating func notification(_ method: String, _ line: Data) -> [RunStreamOutput] {
        guard case .working(let thread, _) = phase else { return [] }
        switch method {
        case "item/started":
            guard let started = params(ItemEvent.self, in: line), started.threadId == thread else { return [] }
            if started.item.type == "fileChange" {
                patches[started.item.id] = started.item.changes?.flatMap(\.requests) ?? []
            }
            return Self.tools.contains(started.item.type) ? [.event(.toolUsed)] : []
        case "item/completed":
            guard let completed = params(ItemEvent.self, in: line), completed.threadId == thread else { return [] }
            patches[completed.item.id] = nil
            if completed.item.type == "agentMessage", let text = completed.item.text { lastMessage = text }
            return []
        case "turn/completed":
            guard let completed = params(RunTurnCompleted.self, in: line), completed.threadId == thread else { return [] }
            switch completed.turn.status {
            case "completed":
                phase = .finished
                approvals = [:]
                return [.event(.finished(report: lastMessage ?? "")), .closeInput]
            case "interrupted":
                return fail(.error("it was interrupted"))
            default:
                let error = completed.turn.error
                if error?.codexErrorInfo == "unauthorized" { return fail(.signedOut) }
                if error?.codexErrorInfo == "usageLimitExceeded" {
                    phase = .finished
                    approvals = [:]
                    return [.event(.limitReached(partialReport: lastMessage ?? "")), .closeInput]
                }
                return fail(.error(error.map { firstLine(of: $0.message) } ?? "it returned an error"))
            }
        default:
            return []
        }
    }

    private mutating func serverRequest(_ method: String, id: RequestID, _ line: Data) -> [RunStreamOutput] {
        let asked: (turn: String, request: ApprovalRequest)?
        switch (method, phase) {
        case ("item/commandExecution/requestApproval", .working(let thread, let cwd)):
            asked = params(CommandApproval.self, in: line).flatMap { approval in
                approval.threadId == thread ? (approval.turnId, approval.request(runningIn: cwd)) : nil
            }
        case ("item/fileChange/requestApproval", .working(let thread, _)):
            asked = params(FileChangeApproval.self, in: line).flatMap { approval in
                guard approval.threadId == thread else { return nil }
                let changes = patches[approval.itemId] ?? []
                return (approval.turnId, changes.isEmpty ? .other(tool: "apply_patch") : .changes(changes))
            }
        default:
            asked = nil
        }
        guard let asked else {
            return [.write(jsonLine(["id": id.json, "error": ["code": -32601, "message": "Buddy doesn't handle this request."]]))]
        }
        let key = id.key
        approvals[key] = WaitingApproval(id: id, turn: asked.turn, action: asked.request.action)
        return [.event(.approvalRequested(id: key, asked.request))]
    }

    /// The brief's screens after their labels, then the request. Codex reads each screen from the run folder.
    private func briefInput() -> [[String: Any]] {
        var screens = 0
        let content = brief.captures.labeled.map { part -> [String: Any] in
            switch part {
            case .text(let text):
                return ["type": "text", "text": text]
            case .jpeg:
                screens += 1
                return ["type": "localImage", "path": "\(folder)/screen-\(screens).jpg"]
            }
        }
        return content + [["type": "text", "text": "Your run folder is \(folder).\n\n\(brief.prompt)"]]
    }

    private mutating func fail(_ failure: ProviderFailure) -> [RunStreamOutput] {
        phase = .finished
        approvals = [:]
        return [.event(.failed(failure)), .closeInput]
    }

    private func decision(_ id: RequestID, _ decision: String) -> RunStreamOutput {
        .write(jsonLine(["id": id.json, "result": ["decision": decision]]))
    }

    private mutating func request(_ kind: Request, _ method: String, _ params: [String: Any]) -> RunStreamOutput {
        let id = nextRequest
        nextRequest += 1
        pending[id] = kind
        return .write(jsonLine(["id": id, "method": method, "params": params]))
    }
}

private extension RequestID {
    /// The id the engine knows the request by.
    var key: String {
        switch self {
        case .number(let number): String(number)
        case .text(let text): text
        }
    }
}

private struct RunThreadStart: Decodable {
    enum CodingKeys: String, CodingKey { case thread, cwd, approvalPolicy, approvalsReviewer }
    struct Thread: Decodable { let id: String }

    let thread: Thread
    let cwd: String?
    /// Nil for a policy that isn't a plain name, such as a granular one.
    let approvalPolicy: String?
    let approvalsReviewer: String?

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        thread = try fields.decode(Thread.self, forKey: .thread)
        cwd = try? fields.decode(String.self, forKey: .cwd)
        approvalPolicy = try? fields.decode(String.self, forKey: .approvalPolicy)
        approvalsReviewer = try? fields.decode(String.self, forKey: .approvalsReviewer)
    }
}

private struct ItemEvent: Decodable {
    struct Item: Decodable {
        struct Change: Decodable {
            struct Kind: Decodable {
                let type: String
                let move_path: String?
            }
            let path: String
            let kind: Kind

            /// A moved file is removed from its old path and written at its new one.
            var requests: [ApprovalRequest] {
                switch kind.type {
                case "add": [.write(path: path)]
                case "delete": [.delete(path: path)]
                default: kind.move_path.map { [.delete(path: path), .write(path: $0)] } ?? [.edit(path: path)]
                }
            }
        }
        let type: String
        let id: String
        let changes: [Change]?
        let text: String?
    }
    let item: Item
    let threadId: String
}

private struct CommandApproval: Decodable {
    let threadId: String
    let turnId: String
    let kind: String?
    let command: String?
    let cwd: String?

    /// Codex shows each command as `/bin/zsh -lc <script>`, and the policy judges the script. A command run from
    /// another folder is judged as a `cd` there first, which the policy denies, since it reads relative paths as
    /// inside the run folder.
    func request(runningIn folder: String) -> ApprovalRequest {
        guard kind ?? "command" == "command", let command else { return .other(tool: "terminal input") }
        let script = Self.script(of: command)
        guard let cwd, cwd != folder else { return .command(script) }
        return .command("cd '\(cwd.replacing("'", with: #"'\''"#))' && \(script)")
    }

    private static func script(of command: String) -> String {
        guard let parsed = try? ShellCommand(parsing: command, home: ""), parsed.commands.count == 1,
              let shell = parsed.commands.first, shell.redirects.isEmpty, shell.words.count == 3,
              !shell.words.contains(where: \.isPattern),
              ["/bin/zsh", "/bin/bash", "/bin/sh"].contains(shell.words[0].text),
              ["-lc", "-c"].contains(shell.words[1].text)
        else { return command }
        return shell.words[2].text
    }
}

private struct FileChangeApproval: Decodable {
    let threadId: String
    let turnId: String
    let itemId: String
}

private struct RunTurnCompleted: Decodable {
    let threadId: String
    let turn: TurnCompleted.Turn
}
