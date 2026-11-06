import Foundation

func firstLine(of message: String) -> String {
    message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
}

/// The last line a process wrote to stderr, without terminal color codes.
func lastLine(of stderr: String) -> String? {
    stderr.split(whereSeparator: \.isNewline).last
        .map { $0.replacing(/\u{1B}\[[0-9;]*m/, with: "").trimmingCharacters(in: .whitespaces) }
        .flatMap { $0.isEmpty ? nil : $0 }
}

/// A JSON-RPC request id, which Codex may send as a number or a string.
enum RequestID: Decodable {
    case number(Int)
    case text(String)

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Int.self) {
            self = .number(number)
        } else {
            self = .text(try value.decode(String.self))
        }
    }

    var json: Any {
        switch self {
        case .number(let number): number
        case .text(let text): text
        }
    }
}

struct RPCError: Decodable {
    let message: String
}

/// One line Codex prints. Each field decodes on its own, so an unexpected shape in one field never hides the rest.
struct RPCEnvelope: Decodable {
    enum CodingKeys: String, CodingKey { case id, method, error }

    let id: RequestID?
    let method: String?
    let error: RPCError?

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try? fields.decode(RequestID.self, forKey: .id)
        method = try? fields.decode(String.self, forKey: .method)
        error = try? fields.decode(RPCError.self, forKey: .error)
    }
}

struct RPCResponse<Result: Decodable>: Decodable {
    let result: Result
}

struct RPCNotification<Params: Decodable>: Decodable {
    let params: Params
}

/// The result of the response on `line`, or nil when it has no result of that shape.
func result<T: Decodable>(_ type: T.Type, in line: Data) -> T? {
    try? JSONDecoder().decode(RPCResponse<T>.self, from: line).result
}

/// The params of the notification or request on `line`, or nil when it has none of that shape.
func params<T: Decodable>(_ type: T.Type, in line: Data) -> T? {
    try? JSONDecoder().decode(RPCNotification<T>.self, from: line).params
}

struct AccountResult: Decodable {
    struct Account: Decodable { let type: String }
    let account: Account?
}

struct ConfigResult: Decodable {
    struct Config: Decodable {
        enum CodingKeys: String, CodingKey { case mcpServers = "mcp_servers" }
        let mcpServers: [String: Ignored]?
    }
    let config: Config
}

struct Ignored: Decodable {
    init(from decoder: any Decoder) throws {}
}

struct ModelsResult: Decodable {
    struct Model: Decodable {
        let model: String
        let isDefault: Bool?
    }
    let data: [Model]
}

struct ThreadStartResult: Decodable {
    struct Thread: Decodable { let id: String }
    let thread: Thread
}

struct TurnStartResult: Decodable {
    struct Turn: Decodable { let id: String }
    let turn: Turn
}

struct MessageDelta: Decodable {
    let turnId: String
    let itemId: String
    let delta: String
}

struct TurnCompleted: Decodable {
    struct Turn: Decodable {
        struct Failure: Decodable {
            enum CodingKeys: String, CodingKey { case message, codexErrorInfo }
            let message: String
            let codexErrorInfo: String?

            init(from decoder: any Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                message = try fields.decode(String.self, forKey: .message)
                codexErrorInfo = try? fields.decode(String.self, forKey: .codexErrorInfo)
            }
        }
        let id: String
        let status: String
        let error: Failure?
    }
    let turn: Turn
}
