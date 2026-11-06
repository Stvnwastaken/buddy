import Foundation

/// Splits what a process prints into whole lines, holding back a partial last line until the rest of it arrives.
struct LineBuffer: Sendable {
    private var unread = Data()

    mutating func lines(after chunk: Data) -> [Data] {
        unread.append(chunk)
        var lines: [Data] = []
        while let newline = unread.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Data(unread[..<newline]))
            unread = unread[unread.index(after: newline)...]
        }
        return lines
    }
}

/// One JSON object as a line to write, with sorted keys so the bytes are the same every time.
func jsonLine(_ object: [String: Any]) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    data.append(UInt8(ascii: "\n"))
    return data
}
