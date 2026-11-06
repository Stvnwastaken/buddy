import Foundation
import Testing
import BuddyCore

/// The `tools/list` request Claude Code 2.1.316 sent, with its headers.
private let recordedToolsList = "POST /mcp HTTP/1.1\r\n"
    + "Accept: application/json, text/event-stream\r\n"
    + "Authorization: Bearer run-token\r\n"
    + "Content-Type: application/json\r\n"
    + "User-Agent: claude-code/2.1.316 (sdk-cli)\r\n"
    + "mcp-protocol-version: 2025-11-25\r\n"
    + "Connection: keep-alive\r\n"
    + "Host: 127.0.0.1:47391\r\n"
    + "Content-Length: 46\r\n"
    + "\r\n"
    + #"{"method":"tools/list","jsonrpc":"2.0","id":1}"#

private func read(_ text: String, inChunksOf size: Int, with reader: HTTPRequestReader = HTTPRequestReader()) -> [HTTPRequestReader.Progress] {
    var reader = reader
    let bytes = Data(text.utf8)
    return stride(from: 0, to: bytes.count, by: size).map { start in
        reader.read(bytes.subdata(in: start..<min(start + size, bytes.count)))
    }
}

struct HTTPMessageTests {
    @Test(arguments: [1, 2, 7, 64, 100_000])
    func recordedRequestIsReadWithLowercasedHeadersHoweverItIsSplit(chunkSize: Int) {
        let progress = read(recordedToolsList, inChunksOf: chunkSize)
        #expect(progress.dropLast().allSatisfy { $0 == .incomplete })
        #expect(progress.last == .complete(HTTPRequest(
            method: "POST",
            path: "/mcp",
            headers: [
                "accept": "application/json, text/event-stream",
                "authorization": "Bearer run-token",
                "content-type": "application/json",
                "user-agent": "claude-code/2.1.316 (sdk-cli)",
                "mcp-protocol-version": "2025-11-25",
                "connection": "keep-alive",
                "host": "127.0.0.1:47391",
                "content-length": "46"
            ],
            body: Data(#"{"method":"tools/list","jsonrpc":"2.0","id":1}"#.utf8)
        )))
    }

    @Test func requestWithoutContentLengthHasNoBody() {
        #expect(read("GET /mcp HTTP/1.1\r\nAccept: text/event-stream\r\n\r\n", inChunksOf: 100) == [.complete(HTTPRequest(
            method: "GET", path: "/mcp", headers: ["Accept": "text/event-stream"]
        ))])
    }

    @Test func repeatedHeadersJoinSoConflictingLengthsAreRejected() {
        #expect(read("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 3\r\n\r\n{}", inChunksOf: 100) == [.rejected])
    }

    @Test(arguments: [
        "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nContent-Length: two\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nno colon here\r\n\r\n",
        "POST /mcp\r\n\r\n",
        "hello there\r\n\r\n"
    ])
    func malformedOrChunkedRequestIsRejected(text: String) {
        #expect(read(text, inChunksOf: 100_000) == [.rejected])
    }

    @Test func oversizedHeadOrBodyIsRejectedBeforeItArrives() {
        let small = HTTPRequestReader(maxHeadBytes: 64, maxBodyBytes: 10)
        #expect(read("POST /mcp HTTP/1.1\r\nX-Padding: " + String(repeating: "a", count: 60), inChunksOf: 100, with: small) == [.rejected])
        #expect(read("POST /mcp HTTP/1.1\r\nContent-Length: 11\r\n\r\n", inChunksOf: 100, with: small) == [.rejected])
        #expect(read("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789", inChunksOf: 100, with: small) == [.complete(HTTPRequest(
            method: "POST", path: "/mcp", headers: ["content-length": "10"], body: Data("0123456789".utf8)
        ))])
    }

    @Test func responseSerializesWithItsLengthAndClosesTheConnection() {
        let response = HTTPResponse(status: 405, headers: ["Allow": "POST", "Connection": "keep-alive"], body: Data("no".utf8))
        #expect(String(decoding: response.serialized, as: UTF8.self)
            == "HTTP/1.1 405 Method Not Allowed\r\nAllow: POST\r\nConnection: close\r\nContent-Length: 2\r\n\r\nno")
        #expect(String(decoding: HTTPResponse(status: 202).serialized, as: UTF8.self)
            == "HTTP/1.1 202 Accepted\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
    }
}
