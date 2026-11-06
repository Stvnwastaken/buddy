import Foundation

/// Reads a streamed reply line by line. Lines are plain beats and profile edits, read by `BeatParser`, until a line
/// that is only ```draw. The lines after it are a draw program, up to the next line that is only ```, and anything
/// after that is ignored. A program left open runs when the reply ends.
struct ReplyReader: Equatable, Sendable {
    struct Read: Equatable, Sendable {
        var lines = ParsedLines()
        /// A whole program, ready to run after the beats of `lines`.
        var program: String?
    }

    private var unfinished = ""
    private var parser = BeatParser()
    /// The program's lines so far, once its opening fence has been read.
    private var program: [Substring]?
    private var done = false

    mutating func feed(_ delta: String) -> Read {
        unfinished += delta
        var lines = unfinished.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        unfinished = String(lines.removeLast())
        return read(lines)
    }

    /// Finishes the line written so far, as when the provider pauses to search. A program's lines end only where
    /// the provider breaks them, so inside one this reads nothing.
    mutating func endLine() -> ParsedLines {
        guard program == nil, !unfinished.isEmpty else { return ParsedLines() }
        return feed("\n").lines
    }

    /// What the end of the reply finished: its last line, or a program left open.
    mutating func finish() -> Read {
        var read = read([Substring(unfinished)])
        if !done, let program { read.program = program.joined(separator: "\n") }
        unfinished = ""
        done = true
        return read
    }

    private mutating func read(_ lines: [Substring]) -> Read {
        var read = Read()
        for line in lines where !done {
            let fence = line.trimmingCharacters(in: .whitespaces)
            if let lines = program {
                if fence == "```" {
                    done = true
                    read.program = lines.joined(separator: "\n")
                } else {
                    program?.append(line)
                }
            } else if fence.lowercased() == "```draw" {
                program = []
            } else {
                read.lines = read.lines + parser.feed(line + "\n")
            }
        }
        return read
    }
}
