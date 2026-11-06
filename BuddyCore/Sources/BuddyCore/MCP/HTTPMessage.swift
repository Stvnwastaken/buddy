import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    /// Header names are lowercased, and a repeated header's values are joined with commas.
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { "\($0), \($1)" }
        self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The response as HTTP/1.1 bytes, headers sorted by name. The connection closes after it.
    public var serialized: Data {
        let fields = headers.merging(["Content-Length": "\(body.count)", "Connection": "close"]) { _, fixed in fixed }
        let head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "")\r\n"
            + fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
            + "\r\n"
        return Data(head.utf8) + body
    }

    private static let reasons = [
        200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed"
    ]
}

/// Reads one HTTP/1.1 request from bytes that arrive in chunks split anywhere.
///
/// A body needs a `Content-Length`. Chunked bodies, and heads or bodies over the size limits, are rejected.
public struct HTTPRequestReader: Sendable {
    public enum Progress: Equatable, Sendable {
        case incomplete
        case complete(HTTPRequest)
        case rejected
    }

    private let maxHeadBytes: Int
    private let maxBodyBytes: Int
    private var bytes = Data()

    public init(maxHeadBytes: Int = 16 * 1024, maxBodyBytes: Int = 4 * 1024 * 1024) {
        self.maxHeadBytes = maxHeadBytes
        self.maxBodyBytes = maxBodyBytes
    }

    public mutating func read(_ chunk: Data) -> Progress {
        bytes.append(chunk)
        guard let headEnd = bytes.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return bytes.count > maxHeadBytes ? .rejected : .incomplete
        }
        guard headEnd.lowerBound - bytes.startIndex <= maxHeadBytes,
              let head = Self.head(String(decoding: bytes[..<headEnd.lowerBound], as: UTF8.self)),
              head.bodyLength <= maxBodyBytes
        else { return .rejected }
        let body = bytes[headEnd.upperBound...]
        guard body.count >= head.bodyLength else { return .incomplete }
        return .complete(HTTPRequest(
            method: head.method,
            path: head.path,
            headers: head.headers,
            body: Data(body.prefix(head.bodyLength))
        ))
    }

    private static func head(_ text: String) -> (method: String, path: String, headers: [String: String], bodyLength: Int)? {
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        guard headers["transfer-encoding"] == nil else { return nil }
        guard let length = headers["content-length"] else { return (requestLine[0], requestLine[1], headers, 0) }
        guard let bodyLength = Int(length), bodyLength >= 0 else { return nil }
        return (requestLine[0], requestLine[1], headers, bodyLength)
    }
}
