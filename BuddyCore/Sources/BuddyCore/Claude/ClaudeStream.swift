import Foundation

/// The stream-json exchange with one `claude -p` process: the lines to write for each turn, and the provider
/// events in what the process prints back.
///
/// The process answers messages in order and ends each answer with one `result` line. A cancelled reply is
/// interrupted and the rest of its text dropped, though the usage it reports still counts. The next turn's
/// message waits for that reply's `result`, so an interrupt only ever reaches the reply it was meant for.
public struct ClaudeStream: Sendable {
    public enum Output: Equatable, Sendable {
        case write(Data)
        case event(ProviderEvent)
        /// The process can't serve another turn, so the next turn needs a new one.
        case endProcess
    }

    private struct Reply: Sendable {
        var cancelled = false
        /// Why the CLI's assistant message says the turn can't be answered, reported with the `result` that ends it.
        var refusal: ProviderFailure?
    }

    private var reply: Reply?
    private var nextMessage: Data?
    private var lines = LineBuffer()
    private var interrupts = 0

    public init() {}

    public mutating func send(_ turn: TurnRequest) -> [Output] {
        var outputs = cancel()
        let message = Self.userMessage(turn.content)
        if reply == nil {
            reply = Reply()
            outputs.append(.write(message))
        } else {
            nextMessage = message
        }
        return outputs
    }

    public mutating func cancel() -> [Output] {
        nextMessage = nil
        guard reply?.cancelled == false else { return [] }
        reply?.cancelled = true
        interrupts += 1
        return [.write(jsonLine([
            "type": "control_request",
            "request_id": "interrupt-\(interrupts)",
            "request": ["subtype": "interrupt"]
        ]))]
    }

    /// Takes whatever the process printed, in chunks split anywhere.
    public mutating func received(_ chunk: Data) -> [Output] {
        lines.lines(after: chunk).flatMap { handle($0) }
    }

    /// The process exited. A turn still waiting for its answer fails with the last line the process wrote to stderr.
    public mutating func ended(stderr: String) -> [Output] {
        let waiting = nextMessage != nil || reply?.cancelled == false
        self = ClaudeStream()
        guard waiting else { return [] }
        let detail = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "it quit unexpectedly"
        return [.event(.failed(.error(detail)))]
    }

    private mutating func handle(_ line: Data) -> [Output] {
        guard let current = reply, let message = try? JSONDecoder().decode(StreamLine.self, from: line) else { return [] }
        switch message.type {
        case "stream_event" where !current.cancelled && message.parentToolUseID == nil:
            if message.event?.startsWebSearch == true { return [.event(.searching)] }
            return message.event?.textDelta.map { [.event(.textDelta($0))] } ?? []
        case "rate_limit_event":
            return message.rateLimitInfo?.usage.map { [.event(.usage($0))] } ?? []
        case "assistant" where message.error == "authentication_failed":
            reply?.refusal = .signedOut
            return []
        case "assistant" where message.error == "rate_limit" || message.error == "billing_error":
            reply?.refusal = .limitReached
            return []
        case "result":
            var outputs = current.cancelled ? [] : Self.outcome(of: message, refusal: current.refusal)
            reply = nil
            if let nextMessage {
                self.nextMessage = nil
                reply = Reply()
                outputs.append(.write(nextMessage))
            }
            return outputs
        default:
            return []
        }
    }

    private static func outcome(of result: StreamLine, refusal: ProviderFailure?) -> [Output] {
        if refusal == .signedOut { return [.event(.failed(.signedOut)), .endProcess] }
        guard result.isError == true else { return [.event(.completed)] }
        if refusal == .limitReached { return [.event(.failed(.limitReached))] }
        let detail = (result.result ?? result.subtype ?? "").split(whereSeparator: \.isNewline).first
        return [.event(.failed(.error(detail.map(String.init) ?? "it returned an error")))]
    }

    static func userMessage(_ content: [TurnContent]) -> Data {
        let content: [[String: Any]] = content.map { part in
            switch part {
            case .text(let text):
                ["type": "text", "text": text]
            case .jpeg(let jpeg):
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
            }
        }
        return jsonLine(["type": "user", "message": ["role": "user", "content": content]])
    }
}

/// One line the CLI prints. Each field decodes on its own, so an unexpected shape in one field never hides a `result`.
private struct StreamLine: Decodable {
    struct Event: Decodable {
        enum CodingKeys: String, CodingKey {
            case type, delta
            case contentBlock = "content_block"
        }

        let type: String?
        let delta: Delta?
        let contentBlock: ContentBlock?

        var startsWebSearch: Bool {
            type == "content_block_start" && contentBlock?.type == "tool_use" && contentBlock?.name == "WebSearch"
        }

        var textDelta: String? {
            guard type == "content_block_delta", delta?.type == "text_delta" else { return nil }
            return delta?.text
        }
    }

    struct Delta: Decodable {
        let type: String?
        let text: String?
    }

    struct ContentBlock: Decodable {
        let type: String?
        let name: String?
    }

    struct RateLimitInfo: Decodable {
        struct Window: Decodable {
            let utilization: Double
            let resetsAt: TimeInterval
            let status: String?

            /// A window Claude has rejected turns in is full, whatever utilization it reports.
            var usage: UsageWindow {
                let spent = status == "rejected" ? max(utilization, 1) : utilization
                return UsageWindow(utilization: spent, resetsAt: Date(timeIntervalSince1970: resetsAt))
            }
        }

        let unifiedWindows: [String: Window]?

        var usage: ProviderUsage? {
            guard let fiveHour = unifiedWindows?["five_hour"], let sevenDay = unifiedWindows?["seven_day"] else { return nil }
            return ProviderUsage(fiveHour: fiveHour.usage, sevenDay: sevenDay.usage)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, subtype, event, error, result
        case parentToolUseID = "parent_tool_use_id"
        case rateLimitInfo = "rate_limit_info"
        case isError = "is_error"
    }

    let type: String
    let subtype: String?
    let event: Event?
    let parentToolUseID: String?
    let rateLimitInfo: RateLimitInfo?
    let error: String?
    let isError: Bool?
    let result: String?

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        type = try fields.decode(String.self, forKey: .type)
        subtype = try? fields.decode(String.self, forKey: .subtype)
        event = try? fields.decode(Event.self, forKey: .event)
        parentToolUseID = try? fields.decode(String.self, forKey: .parentToolUseID)
        rateLimitInfo = try? fields.decode(RateLimitInfo.self, forKey: .rateLimitInfo)
        error = try? fields.decode(String.self, forKey: .error)
        isError = try? fields.decode(Bool.self, forKey: .isError)
        result = try? fields.decode(String.self, forKey: .result)
    }
}
