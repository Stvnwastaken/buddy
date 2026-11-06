/// The check that an AppleScript only reads. Every word must be on a curated list of read-only terms, `set` may only
/// change the script's own variables, and those variables stay out of tell blocks, because there an app's command
/// of the same name wins over the variable.
enum AppleScriptReading {
    static func verdict(of script: String) -> Verdict {
        let tokens = tokens(in: script)
        var check = ScriptCheck(tokens: tokens)
        let verdict = check.verdict()
        guard verdict != .allow else { return .allow }
        for case .word(let text) in tokens where irreversible.contains(text.lowercased()) {
            return .askOwner("AppleScript `\(text)` isn't on Buddy's read-only list.")
        }
        return verdict
    }

    /// Commands that send, post, buy, delete or move something. The owner is told about these first, since they
    /// matter more than whatever else made the script need approval.
    private static let irreversible: Set<String> = [
        "send", "reply", "forward", "post", "buy", "purchase", "delete", "erase", "empty", "move"
    ]

    fileprivate enum Token: Equatable {
        case word(String)
        case number
        case symbol(Unicode.Scalar)
        case newline
    }

    fileprivate static let vocabulary: Set<String> = [
        "tell", "application", "app", "to", "end", "get", "return", "of", "in", "every", "whose", "where", "is", "are",
        "not", "and", "or", "it", "its", "the", "me", "my", "name", "names", "process", "processes", "background",
        "only", "visible", "frontmost", "true", "false", "count", "number", "item", "items", "first", "second", "last",
        "front", "back", "window", "windows", "document", "documents", "tab", "tabs", "url", "title", "id", "bundle",
        "identifier", "file", "files", "folder", "folders", "disk", "disks", "path", "posix", "alias", "as", "text",
        "string", "list", "record", "integer", "real", "linefeed", "space", "quote", "contents", "character",
        "characters", "word", "words", "paragraph", "paragraphs", "delimiters", "applescript", "class", "properties",
        "version", "date", "current", "if", "then", "else", "repeat", "with", "from", "by", "while", "until", "exit",
        "try", "on", "error", "contains", "does", "equal", "equals", "greater", "less", "than", "starts", "begins",
        "ends", "exists", "length", "reverse", "rest", "some", "middle", "index", "displayed", "system", "events",
        "selection", "size", "kind", "desktop", "home", "entire", "info", "for", "s"
    ]

    /// Commands AppleScript and its standard additions know outside any tell block. A script may not name a variable
    /// after one, since the command would win wherever the variable is used.
    fileprivate static let commands: Set<String> = [
        "activate", "beep", "choose", "close", "copy", "delay", "delete", "display", "do", "duplicate", "launch",
        "load", "log", "make", "mount", "move", "open", "print", "quit", "reopen", "run", "save", "say", "set",
        "store", "write"
    ]

    fileprivate static let symbols: Set<Unicode.Scalar> = [
        "(", ")", "{", "}", ",", ":", "&", "=", "≠", "<", ">", "≤", "≥", "+", "-", "*", "/", "÷", "^", "'"
    ]

    private static func tokens(in script: String) -> [Token] {
        let scalars = Array(script.unicodeScalars)
        func scalar(_ position: Int) -> Unicode.Scalar? {
            scalars.indices.contains(position) ? scalars[position] : nil
        }
        func isNamePart(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
        }
        var tokens: [Token] = []
        var index = 0
        while let current = scalar(index) {
            let next = scalar(index + 1)
            if current == "\n" || current == "\r" {
                tokens.append(.newline)
                index += 1
            } else if current == "¬" {
                index += 1
                while let blank = scalar(index), blank == " " || blank == "\t" { index += 1 }
                if scalar(index) == "\r" { index += 1 }
                if scalar(index) == "\n" { index += 1 }
            } else if current.properties.isWhitespace {
                index += 1
            } else if current == "\"" {
                index += 1
                while let inside = scalar(index), inside != "\"" { index += inside == "\\" ? 2 : 1 }
                index += 1
            } else if current == "#" || (current == "-" && next == "-") {
                while let inside = scalar(index), inside != "\n", inside != "\r" { index += 1 }
            } else if current == "(" && next == "*" {
                var depth = 0
                repeat {
                    if scalar(index) == "(" && scalar(index + 1) == "*" {
                        depth += 1
                        index += 2
                    } else if scalar(index) == "*" && scalar(index + 1) == ")" {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                } while depth > 0 && index < scalars.count
            } else if ("0"..."9").contains(current) {
                while let digit = scalar(index), ("0"..."9").contains(digit) || digit == "." { index += 1 }
                tokens.append(.number)
            } else if isNamePart(current) {
                let start = index
                while let letter = scalar(index), isNamePart(letter) { index += 1 }
                tokens.append(.word(String(String.UnicodeScalarView(scalars[start..<index]))))
            } else {
                tokens.append(.symbol(current))
                index += 1
            }
        }
        return tokens
    }
}

private struct ScriptCheck {
    typealias Token = AppleScriptReading.Token

    let tokens: [Token]
    private var index = 0
    private var variables: Set<String> = []
    private var tellBlocks = 0
    private var tellsOnThisLine = false

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    mutating func verdict() -> Verdict {
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            switch token {
            case .newline:
                tellsOnThisLine = false
            case .number:
                continue
            case .symbol(let symbol):
                guard AppleScriptReading.symbols.contains(symbol) else { return notReadOnly(String(symbol)) }
            case .word(let text):
                let verdict = check(text)
                guard verdict == .allow else { return verdict }
            }
        }
        return .allow
    }

    private mutating func check(_ text: String) -> Verdict {
        switch text.lowercased() {
        case "tell":
            let line = tokens[index...].prefix { $0 != .newline }
            if line.contains(where: { word($0) == "to" }) {
                tellsOnThisLine = true
            } else {
                tellBlocks += 1
            }
        case "end" where word(at: index) == "tell":
            guard tellBlocks > 0 else { return .askOwner("Buddy can't check this AppleScript's tell blocks.") }
            tellBlocks -= 1
            index += 1
        case "set":
            return checkSet()
        case "repeat" where word(at: index) == "with", "on" where word(at: index) == "error":
            index += 1
            if let name = word(at: index), isVariableName(name) {
                variables.insert(name)
                index += 1
            }
        case let word where AppleScriptReading.vocabulary.contains(word):
            break
        case let word where variables.contains(word):
            guard tellBlocks == 0, !tellsOnThisLine else {
                return .askOwner("Buddy can't check AppleScript that uses the variable `\(text)` inside a tell block.")
            }
        default:
            return notReadOnly(text)
        }
        return .allow
    }

    private mutating func checkSet() -> Verdict {
        guard tellBlocks == 0, !tellsOnThisLine else {
            return .askOwner("AppleScript `set` isn't allowed inside tell blocks.")
        }
        var delimiters = index
        if word(at: delimiters) == "applescript", token(at: delimiters + 1) == .symbol("'"), word(at: delimiters + 2) == "s" {
            delimiters += 3
        } else if word(at: delimiters) == "my" {
            delimiters += 1
        }
        if ["text", "item", "delimiters", "to"].enumerated().allSatisfy({ word(at: delimiters + $0.offset) == $0.element }) {
            return .allow
        }
        guard let name = word(at: index), word(at: index + 1) == "to", isVariableName(name) else {
            return .askOwner("AppleScript `set` may only change the script's own variables.")
        }
        variables.insert(name)
        index += 1
        return .allow
    }

    private func isVariableName(_ word: String) -> Bool {
        !AppleScriptReading.vocabulary.contains(word) && !AppleScriptReading.commands.contains(word)
    }

    private func notReadOnly(_ term: String) -> Verdict {
        .askOwner("AppleScript `\(term)` isn't on Buddy's read-only list.")
    }

    private func token(at position: Int) -> Token? {
        tokens.indices.contains(position) ? tokens[position] : nil
    }

    private func word(at position: Int) -> String? {
        token(at: position).flatMap(word)
    }

    private func word(_ token: Token) -> String? {
        guard case .word(let text) = token else { return nil }
        return text.lowercased()
    }
}
