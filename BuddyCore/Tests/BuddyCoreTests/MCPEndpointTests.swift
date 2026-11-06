import Foundation
import Testing
import BuddyCore

/// Bodies Claude Code 2.1.316 posted to Buddy's MCP server, in the order it sent them.
private enum Recorded {
    static let discover = #"{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.316","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}},"extensions":{"io.modelcontextprotocol/tasks":{}}}}}}"#
    static let initialize = #"{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}},"extensions":{"io.modelcontextprotocol/tasks":{}}},"clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.316","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"}},"jsonrpc":"2.0","id":0}"#
    static let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    static let toolsList = #"{"method":"tools/list","jsonrpc":"2.0","id":1}"#
    static let updateRunNote = #"{"method":"tools/call","params":{"name":"update_run_note","arguments":{"note":"hello"},"_meta":{"claudecode/toolUseId":"toolu_fixture1","progressToken":2}},"jsonrpc":"2.0","id":2}"#
}

private func post(_ body: String, token: String? = "run-token", path: String = "/mcp") -> HTTPRequest {
    HTTPRequest(
        method: "POST",
        path: path,
        headers: ["Content-Type": "application/json"].merging(token.map { ["Authorization": "Bearer \($0)"] } ?? [:]) { $1 },
        body: Data(body.utf8)
    )
}

private func handle(_ request: HTTPRequest) -> MCPEndpoint.Outcome {
    MCPEndpoint.handle(request) { $0 == "run-token" ? RunID(3) : nil }
}

private func json(_ status: Int, _ body: String) -> MCPEndpoint.Outcome {
    .respond(HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8)))
}

struct MCPEndpointTests {
    @Test func recordedHandshakeFallsBackFromDiscoveryToInitialize() {
        #expect(handle(post(Recorded.discover)) == json(
            404, #"{"error":{"code":-32601,"message":"Method not found"},"id":"server-discover-probe-1","jsonrpc":"2.0"}"#
        ))
        #expect(handle(post(Recorded.initialize)) == json(
            200, #"{"id":0,"jsonrpc":"2.0","result":{"capabilities":{"tools":{}},"protocolVersion":"2025-11-25","serverInfo":{"name":"buddy","version":"1"}}}"#
        ))
        #expect(handle(post(Recorded.initialized)) == .respond(HTTPResponse(status: 202)))
        #expect(handle(HTTPRequest(method: "GET", path: "/mcp", headers: ["Authorization": "Bearer run-token"]))
            == .respond(HTTPResponse(status: 405, headers: ["Allow": "POST"])))
    }

    @Test(arguments: [("2025-03-26", "2025-03-26"), ("2025-06-18", "2025-06-18"), ("2024-11-05", "2025-11-25"), ("2026-07-28", "2025-11-25")])
    func initializeAgreesOnAVersionBuddySpeaks(requested: String, agreed: String) {
        let request = #"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"\#(requested)"}}"#
        #expect(handle(post(request)) == json(
            200, #"{"id":"init","jsonrpc":"2.0","result":{"capabilities":{"tools":{}},"protocolVersion":"\#(agreed)","serverInfo":{"name":"buddy","version":"1"}}}"#
        ))
    }

    @Test func toolsListOffersBuddysToolsWithTheirArguments() throws {
        guard case .respond(let response) = handle(post(Recorded.toolsList)) else {
            Issue.record("expected a response")
            return
        }
        #expect(response.status == 200)
        let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let tools = try #require((body["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let schemas = tools.map { tool -> String in
            let schema = tool["inputSchema"] as? [String: Any] ?? [:]
            let properties = (schema["properties"] as? [String: [String: Any]] ?? [:]).sorted { $0.key < $1.key }.map { property in
                let items = (property.value["items"] as? [String: Any])?["type"].map { " of \($0)" } ?? ""
                return "\(property.key): \(property.value["type"] ?? "")\(items)"
            }
            return "\(tool["name"] ?? "") \(schema["type"] ?? "") [\(properties.joined(separator: ", "))] required \(schema["required"] as? [String] ?? [])"
        }
        #expect(schemas == [
            "capture_screen object [] required []",
            "update_run_note object [note: string] required [\"note\"]",
            "show_beats object [lines: string] required [\"lines\"]",
            "ask_owner object [choices: array of string, question: string] required [\"question\"]",
            "begin_takeover object [reason: string] required [\"reason\"]",
            "click object [button: string, count: integer, screen: integer, x: integer, y: integer] required [\"x\", \"y\"]",
            "move object [screen: integer, x: integer, y: integer] required [\"x\", \"y\"]",
            "scroll object [down: integer, right: integer, screen: integer, x: integer, y: integer] required [\"x\", \"y\"]",
            "type object [text: string] required [\"text\"]",
            "key object [keys: string] required [\"keys\"]",
            "end_takeover object [] required []"
        ])
        #expect(tools.allSatisfy { ($0["description"] as? String)?.isEmpty == false })
    }

    @Test func recordedToolCallBecomesACallForTheTokensRun() {
        #expect(handle(post(Recorded.updateRunNote)) == .call(RunID(3), MCPCall(id: .number(2), tool: .updateRunNote("hello"))))
        let lines = #"{"jsonrpc":"2.0","id":"7","method":"tools/call","params":{"name":"show_beats","arguments":{"lines":"[POINT:10,20:Dock] There."}}}"#
        #expect(handle(post(lines)) == .call(RunID(3), MCPCall(id: .string("7"), tool: .showBeats("[POINT:10,20:Dock] There."))))
        let capture = #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"capture_screen"}}"#
        #expect(handle(post(capture)) == .call(RunID(3), MCPCall(id: .number(8), tool: .captureScreen)))
        let choices = #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"ask_owner","arguments":{"question":"Send it?","choices":["Send","Wait"]}}}"#
        #expect(handle(post(choices)) == .call(RunID(3), MCPCall(id: .number(9), tool: .askOwner("Send it?", choices: ["Send", "Wait"]))))
        let free = #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"ask_owner","arguments":{"question":"What should it say?"}}}"#
        #expect(handle(post(free)) == .call(RunID(3), MCPCall(id: .number(10), tool: .askOwner("What should it say?", choices: []))))
    }

    @Test(arguments: [
        (#"{"name":"begin_takeover","arguments":{"reason":"Photo Booth has no AppleScript."}}"#, BuddyTool.beginTakeover(reason: "Photo Booth has no AppleScript.")),
        (#"{"name":"click","arguments":{"x":640,"y":400}}"#, .screen(.click(ScreenSpot(x: 640, y: 400, screen: nil), button: .left, count: 1))),
        (#"{"name":"click","arguments":{"x":5,"y":6,"screen":2,"button":"right","count":2}}"#, .screen(.click(ScreenSpot(x: 5, y: 6, screen: 2), button: .right, count: 2))),
        (#"{"name":"click","arguments":{"x":5.0,"y":6,"button":"left","count":3}}"#, .screen(.click(ScreenSpot(x: 5, y: 6, screen: nil), button: .left, count: 3))),
        (#"{"name":"move","arguments":{"x":-4,"y":6,"screen":1}}"#, .screen(.move(ScreenSpot(x: -4, y: 6, screen: 1)))),
        (#"{"name":"scroll","arguments":{"x":5,"y":6,"down":-3}}"#, .screen(.scroll(ScreenSpot(x: 5, y: 6, screen: nil), down: -3, right: 0))),
        (#"{"name":"scroll","arguments":{"x":5,"y":6,"right":2,"down":0}}"#, .screen(.scroll(ScreenSpot(x: 5, y: 6, screen: nil), down: 0, right: 2))),
        (#"{"name":"type","arguments":{"text":"Beach 1\nBeach 2"}}"#, .screen(.type("Beach 1\nBeach 2"))),
        (#"{"name":"key","arguments":{"keys":"cmd+shift+s"}}"#, .screen(.key(KeyPress(modifiers: [.command, .shift], keyCode: 0x01)))),
        (#"{"name":"end_takeover"}"#, .endTakeover)
    ])
    func takeoverToolCallsBecomeTheirTools(params: String, tool: BuddyTool) {
        let request = #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":\#(params)}"#
        #expect(handle(post(request)) == .call(RunID(3), MCPCall(id: .number(11), tool: tool)))
    }

    @Test(arguments: [
        (#"{"name":"delete_files","arguments":{}}"#, "Buddy has no tool named delete_files."),
        (#"{"name":"update_run_note","arguments":{"text":"hello"}}"#, "Invalid arguments for update_run_note."),
        (#"{"name":"show_beats","arguments":{"lines":3}}"#, "Invalid arguments for show_beats."),
        (#"{"name":"ask_owner","arguments":{"choices":["Yes"]}}"#, "Invalid arguments for ask_owner."),
        (#"{"name":"ask_owner","arguments":{"question":"Send it?","choices":"Yes"}}"#, "Invalid arguments for ask_owner."),
        (#"{"name":"ask_owner","arguments":{"question":"Send it?","choices":["Yes",2]}}"#, "Invalid arguments for ask_owner."),
        (#"{"name":"begin_takeover","arguments":{}}"#, "Invalid arguments for begin_takeover."),
        (#"{"name":"click","arguments":{"x":5,"y":6,"button":"middle"}}"#, "Invalid arguments for click."),
        (#"{"name":"click","arguments":{"x":5,"y":6,"count":4}}"#, "Invalid arguments for click."),
        (#"{"name":"click","arguments":{"x":5,"y":6,"count":0}}"#, "Invalid arguments for click."),
        (#"{"name":"click","arguments":{"x":10.5,"y":6}}"#, "Invalid arguments for click."),
        (#"{"name":"click","arguments":{"x":"10","y":6}}"#, "Invalid arguments for click."),
        (#"{"name":"click","arguments":{"x":true,"y":6}}"#, "Invalid arguments for click."),
        (#"{"name":"click","arguments":{"x":5}}"#, "Invalid arguments for click."),
        (#"{"name":"move","arguments":{"x":5,"y":6,"screen":"2"}}"#, "Invalid arguments for move."),
        (#"{"name":"scroll","arguments":{"x":5,"y":6}}"#, "Invalid arguments for scroll."),
        (#"{"name":"scroll","arguments":{"x":5,"y":6,"down":0,"right":0}}"#, "Invalid arguments for scroll."),
        (#"{"name":"type","arguments":{"text":3}}"#, "Invalid arguments for type."),
        (#"{"name":"key","arguments":{"keys":"cmd+banana"}}"#, "Invalid arguments for key."),
        (#"{"name":"key","arguments":{"keys":"a+b"}}"#, "Invalid arguments for key.")
    ])
    func toolCallWithAnUnknownToolOrBadArgumentsIsAnInvalidParamsError(params: String, message: String) {
        let request = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":\#(params)}"#
        #expect(handle(post(request)) == json(200, #"{"error":{"code":-32602,"message":"\#(message)"},"id":4,"jsonrpc":"2.0"}"#))
    }

    @Test func pingAnswersWithAnEmptyResult() {
        #expect(handle(post(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#)) == json(200, #"{"id":5,"jsonrpc":"2.0","result":{}}"#))
    }

    @Test func requestsWithoutTheRunsTokenOrToAnotherPathAreRefused() {
        let unauthorized = MCPEndpoint.Outcome.respond(HTTPResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"]))
        #expect(handle(post(Recorded.toolsList, token: nil)) == unauthorized)
        #expect(handle(post(Recorded.toolsList, token: "another-token")) == unauthorized)
        #expect(handle(HTTPRequest(method: "DELETE", path: "/mcp")) == unauthorized)
        #expect(handle(HTTPRequest(method: "DELETE", path: "/mcp", headers: ["Authorization": "bearer run-token"]))
            == .respond(HTTPResponse(status: 405, headers: ["Allow": "POST"])))
        #expect(handle(post(Recorded.toolsList, path: "/.well-known/oauth-protected-resource")) == .respond(HTTPResponse(status: 404)))
    }

    @Test func malformedBodiesAreParseOrInvalidRequestErrors() {
        #expect(handle(post("{not json")) == json(400, #"{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}"#))
        #expect(handle(post(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#))
            == json(400, #"{"error":{"code":-32600,"message":"Invalid Request"},"id":null,"jsonrpc":"2.0"}"#))
        #expect(handle(post(#"{"jsonrpc":"2.0","id":[1],"method":"ping"}"#))
            == json(400, #"{"error":{"code":-32600,"message":"Invalid Request"},"id":null,"jsonrpc":"2.0"}"#))
    }

    @Test func toolAnswerBecomesTheCallsResult() {
        let note = MCPCall(id: .number(2), tool: .updateRunNote("hello"))
        #expect(MCPEndpoint.response(to: note, ToolAnswer(content: [.text("Saved.")])) == HTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"id":2,"jsonrpc":"2.0","result":{"content":[{"text":"Saved.","type":"text"}],"isError":false}}"#.utf8)
        ))
        let capture = MCPCall(id: .string("c"), tool: .captureScreen)
        let answer = ToolAnswer(content: [.text("Screen 1 of 1, 1280x827 pixels, with the cursor:"), .jpeg(Data([1, 2, 3]))])
        #expect(MCPEndpoint.response(to: capture, answer) == HTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: Data((#"{"id":"c","jsonrpc":"2.0","result":{"content":[{"text":"Screen 1 of 1, 1280x827 pixels, with the cursor:","type":"text"},"#
                + #"{"data":"AQID","mimeType":"image/jpeg","type":"image"}],"isError":false}}"#).utf8)
        ))
        #expect(MCPEndpoint.response(to: capture, ToolAnswer(content: [.text("Buddy couldn't capture the screen.")], isError: true)).body
            == Data(#"{"id":"c","jsonrpc":"2.0","result":{"content":[{"text":"Buddy couldn't capture the screen.","type":"text"}],"isError":true}}"#.utf8))
    }
}
