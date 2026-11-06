import Foundation
import Testing
import BuddyCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LoopbackServerTests {
    @Test func requestOverLoopbackGetsTheAnswerTheHandlerGivesLater() async throws {
        let server = LoopbackServer { request, respond in
            let echo = "\(request.method) \(request.path) \(request.headers["authorization"] ?? "") \(String(decoding: request.body, as: UTF8.self))"
            Task { respond(HTTPResponse(status: 200, headers: ["Content-Type": "text/plain"], body: Data(echo.utf8))) }
        }
        let port = try await server.start()
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.setValue("Bearer run-token", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#.utf8)
        let (body, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        server.stop()
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/plain")
        #expect(String(decoding: body, as: UTF8.self) == #"POST /mcp Bearer run-token {"jsonrpc":"2.0","id":5,"method":"ping"}"#)
    }

    @Test func chunkedRequestIsRefusedWithoutReachingTheHandler() async throws {
        var handled: [HTTPRequest] = []
        let server = LoopbackServer { request, respond in
            handled.append(request)
            respond(HTTPResponse(status: 200))
        }
        let port = try await server.start()
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: Data(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#.utf8))
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        server.stop()
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        #expect(handled == [])
    }
}
