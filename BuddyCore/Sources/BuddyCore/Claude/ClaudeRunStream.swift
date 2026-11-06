import Foundation

/// The stream-json exchange with the `claude -p` process of one agent run: the brief to write, the run events in
/// what the process prints back, and the answers to its permission prompts.
///
/// The process asks before each tool use with a `can_use_tool` control request and waits for the answer. It ends
/// the run with one `result` line, and exits once its input closes.
public struct ClaudeRunStream: RunStream {
    public typealias Output = RunStreamOutput

    private var unannouncedFolder: String?
    private var pendingInputs: [String: Data] = [:]
    private var signedOut = false
    private var limited = false
    private var partialReport = ""
    private var finished = false
    private var lines = LineBuffer()

    public init() {}

    /// The run's first message: the screenshots of its brief after their labels, then the request.
    public mutating func start(_ brief: RunBrief, folder: String) -> [Output] {
        unannouncedFolder = folder
        let text = "Your run folder is \(folder).\n\n\(brief.prompt)"
        return [.write(ClaudeStream.userMessage(brief.captures.labeled + [.text(text)]))]
    }

    /// Takes whatever the process printed, in chunks split anywhere.
    public mutating func received(_ chunk: Data) -> [Output] {
        lines.lines(after: chunk).flatMap { handle($0) }
    }

    /// Answers the permission prompt with this id. An unknown or already answered id writes nothing.
    public mutating func answer(_ requestID: String, _ approval: Approval) -> [Output] {
        guard let input = pendingInputs.removeValue(forKey: requestID) else { return [] }
        let decision: [String: Any] = switch approval {
        case .allow: ["behavior": "allow", "updatedInput": (try? JSONSerialization.jsonObject(with: input)) ?? [:]]
        case .deny(let reason): ["behavior": "deny", "message": reason]
        }
        return [.write(jsonLine([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": decision]
        ]))]
    }

    /// The process exited. A known refusal survives an exit without a result; otherwise stderr explains the failure.
    public mutating func ended(stderr: String) -> [Output] {
        guard !finished else { return [] }
        finished = true
        if signedOut { return [.event(.failed(.signedOut))] }
        if limited { return [.event(.limitReached(partialReport: partialReport))] }
        let detail = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "it quit unexpectedly"
        return [.event(.failed(.error(detail)))]
    }

    private mutating func handle(_ line: Data) -> [Output] {
        guard !finished,
              let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = message["type"] as? String
        else { return [] }
        var outputs: [Output] = []
        if let folder = unannouncedFolder {
            unannouncedFolder = nil
            outputs.append(.event(.started(folder: folder)))
        }
        switch type {
        case "assistant":
            if message["error"] as? String == "authentication_failed" { signedOut = true }
            if ["rate_limit", "billing_error"].contains(message["error"] as? String ?? "") { limited = true }
            guard !(message["parent_tool_use_id"] is String) else { break }
            let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            if message["error"] == nil {
                let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.isEmpty { partialReport = text }
            }
            outputs += content.filter { $0["type"] as? String == "tool_use" }.map { _ in .event(.toolUsed) }
        case "control_request":
            guard let id = message["request_id"] as? String else { break }
            let request = message["request"] as? [String: Any] ?? [:]
            guard request["subtype"] as? String == "can_use_tool", let tool = request["tool_name"] as? String else {
                outputs.append(.write(jsonLine([
                    "type": "control_response",
                    "response": ["subtype": "error", "request_id": id, "error": "Buddy doesn't handle this request."]
                ])))
                break
            }
            let input = request["input"] as? [String: Any] ?? [:]
            pendingInputs[id] = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])
            outputs.append(.event(.approvalRequested(id: id, Self.approvalRequest(tool, input))))
        case "result":
            finished = true
            pendingInputs = [:]
            outputs += [.event(outcome(of: message)), .closeInput]
        default:
            break
        }
        return outputs
    }

    private func outcome(of result: [String: Any]) -> RunEvent {
        if signedOut { return .failed(.signedOut) }
        guard result["is_error"] as? Bool == true else { return .finished(report: result["result"] as? String ?? "") }
        if limited { return .limitReached(partialReport: partialReport) }
        let detail = (result["result"] as? String ?? result["subtype"] as? String ?? "").split(whereSeparator: \.isNewline).first
        return .failed(.error(detail.map(String.init) ?? "it returned an error"))
    }

    private static func approvalRequest(_ tool: String, _ input: [String: Any]) -> ApprovalRequest {
        let filePath = input["file_path"] as? String
        let request: ApprovalRequest? = switch tool {
        case let buddyTool where buddyTool.hasPrefix("mcp__buddy__"): .buddyTool(buddyTool)
        case "Read": filePath.map { .read(path: $0) }
        case "Glob", "Grep": .read(path: input["path"] as? String ?? ".")
        case "Write": filePath.map { .write(path: $0) }
        case "Edit", "MultiEdit": filePath.map { .edit(path: $0) }
        case "NotebookEdit": (input["notebook_path"] as? String).map { .edit(path: $0) }
        case "Bash": (input["command"] as? String).map { .command($0) }
        default: nil
        }
        return request ?? .other(tool: tool)
    }
}
