import Foundation

/// A JSON-RPC request id, which the response repeats.
public enum JSONRPCID: Hashable, Sendable {
    case number(Int)
    case string(String)
}

/// A run's call to one of Buddy's tools, waiting for its answer.
public struct MCPCall: Equatable, Sendable {
    public let id: JSONRPCID
    public let tool: BuddyTool

    public init(id: JSONRPCID, tool: BuddyTool) {
        self.id = id
        self.tool = tool
    }
}

/// Buddy's MCP server over Streamable HTTP, without sessions or server-sent events. Each run reaches it with its
/// own bearer token, so the token names the run.
public enum MCPEndpoint {
    public enum Outcome: Equatable, Sendable {
        case respond(HTTPResponse)
        /// The run called a tool. Answer it with `response(to:_:)`.
        case call(RunID, MCPCall)
    }

    /// `runFor` gives the run a bearer token belongs to, or nil for a token no run holds.
    public static func handle(_ request: HTTPRequest, runFor run: (String) -> RunID?) -> Outcome {
        guard request.path == "/mcp" else { return .respond(HTTPResponse(status: 404)) }
        guard let authorization = request.headers["authorization"],
              authorization.prefix(7).lowercased() == "bearer ",
              let runID = run(String(authorization.dropFirst(7)))
        else { return .respond(HTTPResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"])) }
        guard request.method == "POST" else { return .respond(HTTPResponse(status: 405, headers: ["Allow": "POST"])) }
        guard let object = try? JSONSerialization.jsonObject(with: request.body, options: .fragmentsAllowed) else {
            return .respond(error(400, nil, -32700, "Parse error"))
        }
        guard let message = object as? [String: Any], let method = message["method"] as? String else {
            return .respond(error(400, nil, -32600, "Invalid Request"))
        }
        guard let rawID = message["id"] else { return .respond(HTTPResponse(status: 202)) }
        guard let id = JSONRPCID(rawID) else { return .respond(error(400, nil, -32600, "Invalid Request")) }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return .respond(result(id, [
                "protocolVersion": supportedVersions.contains(requested) ? requested : "2025-11-25",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "buddy", "version": "1"]
            ]))
        case "ping":
            return .respond(result(id, [:]))
        case "tools/list":
            return .respond(result(id, ["tools": tools.map(\.definition)]))
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard let tool = tools.first(where: { $0.name == name }) else {
                return .respond(error(200, id, -32602, "Buddy has no tool named \(name)."))
            }
            guard let call = tool.call(params["arguments"] as? [String: Any] ?? [:]) else {
                return .respond(error(200, id, -32602, "Invalid arguments for \(name)."))
            }
            return .call(runID, MCPCall(id: id, tool: call))
        default:
            return .respond(error(404, id, -32601, "Method not found"))
        }
    }

    public static func response(to call: MCPCall, _ answer: ToolAnswer) -> HTTPResponse {
        let content: [[String: Any]] = answer.content.map { part in
            switch part {
            case .text(let text): ["type": "text", "text": text]
            case .jpeg(let jpeg): ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]
            }
        }
        return result(call.id, ["content": content, "isError": answer.isError])
    }

    private static let supportedVersions: Set = ["2025-03-26", "2025-06-18", "2025-11-25"]

    private struct Tool: Sendable {
        struct Argument: Sendable {
            enum Kind: Sendable {
                /// A string the call must give.
                case text
                case optionalText
                /// A whole number the call must give.
                case integer
                case optionalInteger
                /// A list of strings the call may leave out.
                case optionalList

                var isRequired: Bool { self == .text || self == .integer }
            }

            let name: String
            let kind: Kind
            let description: String
        }

        /// A call's arguments after each was checked against its kind.
        struct Checked {
            fileprivate var texts: [String: String] = [:]
            fileprivate var integers: [String: Int] = [:]
            fileprivate var lists: [String: [String]] = [:]

            func text(_ name: String) -> String { texts[name] ?? "" }
            func optionalText(_ name: String) -> String? { texts[name] }
            func integer(_ name: String) -> Int { integers[name] ?? 0 }
            func optionalInteger(_ name: String) -> Int? { integers[name] }
            func list(_ name: String) -> [String] { lists[name] ?? [] }
        }

        let name: String
        let description: String
        let arguments: [Argument]
        /// Nil when the arguments have the right kinds but still don't make a call.
        let make: @Sendable (Checked) -> BuddyTool?

        var definition: [String: Any] {
            let properties = Dictionary(uniqueKeysWithValues: arguments.map { argument -> (String, Any) in
                switch argument.kind {
                case .text, .optionalText:
                    (argument.name, ["type": "string", "description": argument.description])
                case .integer, .optionalInteger:
                    (argument.name, ["type": "integer", "description": argument.description])
                case .optionalList:
                    (argument.name, ["type": "array", "items": ["type": "string"], "description": argument.description])
                }
            })
            var schema: [String: Any] = ["type": "object", "properties": properties]
            let required = arguments.filter(\.kind.isRequired).map(\.name)
            if !required.isEmpty { schema["required"] = required }
            return ["name": name, "description": description, "inputSchema": schema]
        }

        func call(_ given: [String: Any]) -> BuddyTool? {
            var checked = Checked()
            for argument in arguments {
                switch (argument.kind, given[argument.name]) {
                case (.optionalText, nil), (.optionalInteger, nil), (.optionalList, nil): continue
                case (.text, let text as String), (.optionalText, let text as String): checked.texts[argument.name] = text
                case (.integer, let number as NSNumber), (.optionalInteger, let number as NSNumber):
                    guard let integer = Self.integer(number) else { return nil }
                    checked.integers[argument.name] = integer
                case (.optionalList, let list as [String]): checked.lists[argument.name] = list
                default: return nil
                }
            }
            return make(checked)
        }

        /// JSON numbers arrive as `NSNumber`, and so do JSON booleans, which aren't numbers here.
        private static func integer(_ number: NSNumber) -> Int? {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return Int(exactly: number.doubleValue)
        }
    }

    private static let tools = [
        Tool(
            name: "capture_screen",
            description: "Take a fresh screenshot of every display. Use it to check what is on screen now, for example after an app changed, and before pointing with show_beats.",
            arguments: [],
            make: { _ in .captureScreen }
        ),
        Tool(
            name: "update_run_note",
            description: "Replace your run note, the live progress note your owner sees on the run's card. Call it when you start, after each step and before you finish.",
            arguments: [.init(
                name: "note",
                kind: .text,
                description: "The whole note in Markdown: a checklist plan of three to six steps, the current step, and any question for your owner."
            )],
            make: { .updateRunNote($0.text("note")) }
        ),
        Tool(
            name: "show_beats",
            description: "Have Buddy say short lines aloud beside the cursor, and point while a line plays. Use it rarely, when your owner should look at something now.",
            arguments: [.init(
                name: "lines",
                kind: .text,
                description: "One short spoken sentence per line. To point, start a line with [POINT:x,y:label], or [POINT:x,y:label:screenN] for another screen, using pixel coordinates in your latest screenshot."
            )],
            make: { .showBeats($0.text("lines")) }
        ),
        Tool(
            name: "ask_owner",
            description: "Ask your owner a question and wait for the answer. Use it for a decision or a fact only your owner has. Buddy already asks your owner to approve each command that needs it, so don't use this to confirm a command. Your owner clicks a choice on your card, or speaks or types an answer.",
            arguments: [
                .init(name: "question", kind: .text, description: "One short, plain question."),
                .init(
                    name: "choices",
                    kind: .optionalList,
                    description: "A few short answers your owner can click. Leave it out when your owner should answer in their own words."
                )
            ],
            make: { .askOwner($0.text("question"), choices: $0.list("choices")) }
        ),
        Tool(
            name: "begin_takeover",
            description: "Ask your owner for control of the mouse and keyboard, for an app you can't drive with AppleScript or the shell. Buddy shows your reason on a consent card and waits for their answer. Your owner's own input is blocked while you have the screen, so keep it short and call end_takeover when you're done.",
            arguments: [.init(
                name: "reason",
                kind: .text,
                description: "One plain sentence your owner can judge: the app and what you'll do in it."
            )],
            make: { .beginTakeover(reason: $0.text("reason")) }
        ),
        Tool(
            name: "click",
            description: "Click at a spot in your latest screenshot. It works only while you have the screen from begin_takeover.",
            arguments: spot + [
                .init(name: "button", kind: .optionalText, description: "left or right. Left when left out."),
                .init(name: "count", kind: .optionalInteger, description: "1 to 3 clicks in a row, so 2 is a double-click. 1 when left out.")
            ],
            make: { arguments in
                let button: MouseButton
                switch arguments.optionalText("button") {
                case nil, "left": button = .left
                case "right": button = .right
                default: return nil
                }
                let count = arguments.optionalInteger("count") ?? 1
                guard (1...3).contains(count) else { return nil }
                return .screen(.click(screenSpot(arguments), button: button, count: count))
            }
        ),
        Tool(
            name: "move",
            description: "Move the pointer to a spot in your latest screenshot, for example to open a menu that shows on hover. It works only while you have the screen from begin_takeover.",
            arguments: spot,
            make: { .screen(.move(screenSpot($0))) }
        ),
        Tool(
            name: "scroll",
            description: "Scroll at a spot in your latest screenshot, by lines. It works only while you have the screen from begin_takeover.",
            arguments: spot + [
                .init(name: "down", kind: .optionalInteger, description: "Lines to scroll down. Negative scrolls up."),
                .init(name: "right", kind: .optionalInteger, description: "Lines to scroll right. Negative scrolls left.")
            ],
            make: { arguments in
                let down = arguments.optionalInteger("down") ?? 0
                let right = arguments.optionalInteger("right") ?? 0
                guard down != 0 || right != 0 else { return nil }
                return .screen(.scroll(screenSpot(arguments), down: down, right: right))
            }
        ),
        Tool(
            name: "type",
            description: "Type text into the focused field, as if on the keyboard. It works only while you have the screen from begin_takeover.",
            arguments: [.init(name: "text", kind: .text, description: "The text to type. A new line presses Return.")],
            make: { .screen(.type($0.text("text"))) }
        ),
        Tool(
            name: "key",
            description: "Press one key with any modifiers, like return, cmd+s or shift+tab. It works only while you have the screen from begin_takeover.",
            arguments: [.init(
                name: "keys",
                kind: .text,
                description: "Any of cmd, shift, option, ctrl and fn, then one key, joined with +. Keys are a to z, 0 to 9, return, enter, tab, space, delete, forwarddelete, escape, left, right, up, down, home, end, pageup, pagedown, f1 to f12, and - = [ ] ; ' , . / \\ `."
            )],
            make: { KeyPress(parsing: $0.text("keys")).map { .screen(.key($0)) } }
        ),
        Tool(
            name: "end_takeover",
            description: "Give the mouse and keyboard back to your owner. Call it as soon as you're done with the screen.",
            arguments: [],
            make: { _ in .endTakeover }
        )
    ]

    /// Where a screen action happens, in the run's latest screenshot.
    private static let spot: [Tool.Argument] = [
        .init(name: "x", kind: .integer, description: "Pixels from the left of the screenshot."),
        .init(name: "y", kind: .integer, description: "Pixels from the top of the screenshot."),
        .init(name: "screen", kind: .optionalInteger, description: "The screen number, as in show_beats. Leave it out for the screen with the cursor.")
    ]

    private static func screenSpot(_ arguments: Tool.Checked) -> ScreenSpot {
        ScreenSpot(x: arguments.integer("x"), y: arguments.integer("y"), screen: arguments.optionalInteger("screen"))
    }

    private static func result(_ id: JSONRPCID, _ result: [String: Any]) -> HTTPResponse {
        json(200, ["jsonrpc": "2.0", "id": id.json, "result": result])
    }

    private static func error(_ status: Int, _ id: JSONRPCID?, _ code: Int, _ message: String) -> HTTPResponse {
        json(status, ["jsonrpc": "2.0", "id": id?.json ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        )
    }
}

private extension JSONRPCID {
    init?(_ value: Any) {
        if let string = value as? String {
            self = .string(string)
        } else if let number = value as? Int {
            self = .number(number)
        } else {
            return nil
        }
    }

    var json: Any {
        switch self {
        case .number(let number): number
        case .string(let string): string
        }
    }
}
