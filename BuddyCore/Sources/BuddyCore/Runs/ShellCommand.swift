/// A shell command line in the subset Buddy can check: simple commands joined by `;`, `&&`, `||`, `|` or newlines,
/// each with its words and the files it redirects to or from.
///
/// Parsing removes quotes and expands `~`, `$HOME` and `${HOME}`, the only expansions whose result Buddy knows. Any
/// other expansion or substitution, a subshell, group, here-document, background job or leading variable assignment
/// makes the line uncheckable. The parser reads Unicode scalars, as the shell reads bytes, so no lookalike character
/// can stand in for an operator. It follows bash and zsh, and reads zsh's `>!` and leading `=` too.
struct ShellCommand {
    struct Word {
        /// The word as the program receives it, unless it is a pattern.
        let text: String
        /// Whether the shell may expand the word into other words, through an unquoted glob, brace or zsh's `=`.
        let isPattern: Bool
    }

    struct Redirect {
        enum Kind { case read, write }
        let kind: Kind
        let target: Word
    }

    struct Simple {
        var words: [Word] = []
        /// Redirects to or from files. Duplications like `2>&1` name no file and are left out.
        var redirects: [Redirect] = []
    }

    let commands: [Simple]

    init(parsing text: String, home: String) throws(UncheckableShell) {
        guard !text.unicodeScalars.contains("«") else { throw UncheckableShell(construct: "`«`") }
        var parser = ShellParser(text, home: home)
        commands = try parser.parse()
    }
}

/// A construct Buddy's shell parser doesn't follow, named the way a denial names it.
struct UncheckableShell: Error {
    let construct: String
}

private struct ShellParser {
    private struct PartialWord {
        var text = String.UnicodeScalarView()
        var isPattern = false
        var hasOpenBracket = false
        /// Whether the word is unquoted digits, which a `>` or `<` right after it takes as its file descriptor.
        var isDescriptor = true
    }

    private let scalars: [Unicode.Scalar]
    private let home: String
    private var index = 0
    private var word: PartialWord?
    private var command = ShellCommand.Simple()
    private var commands: [ShellCommand.Simple] = []
    /// A redirect waiting for its target. One that may duplicate a descriptor names no file when its target is a
    /// number or `-`.
    private var pendingRedirect: (kind: ShellCommand.Redirect.Kind, duplicates: Bool)?

    init(_ text: String, home: String) {
        scalars = Array(text.unicodeScalars)
        self.home = home
    }

    mutating func parse() throws(UncheckableShell) -> [ShellCommand.Simple] {
        while let current = take() {
            switch current {
            case " ", "\t":
                endWord()
            case "\n", ";":
                try endCommand()
            case "&":
                if take("&") {
                    try endCommand()
                } else if take(">") {
                    _ = take(">")
                    _ = take("|") || take("!")
                    try startRedirect(.write, duplicates: false, takesDescriptor: false)
                } else {
                    throw UncheckableShell(construct: "`&` to run in the background")
                }
            case "|":
                if take("&") { throw UncheckableShell(construct: "`|&`") }
                _ = take("|")
                try endCommand()
            case ">":
                if peek("(") { throw UncheckableShell(construct: "process substitution") }
                _ = take(">")
                let duplicates = take("&")
                _ = take("|") || take("!")
                try startRedirect(.write, duplicates: duplicates)
            case "<":
                if peek("<<") { throw UncheckableShell(construct: "here-strings") }
                if peek("<") { throw UncheckableShell(construct: "here-documents") }
                if peek("(") { throw UncheckableShell(construct: "process substitution") }
                if peek(">") { throw UncheckableShell(construct: "`<>`") }
                try startRedirect(.read, duplicates: take("&"))
            case "(", ")":
                throw UncheckableShell(construct: "parentheses")
            case "`":
                throw UncheckableShell(construct: "backticks")
            case "'":
                try singleQuoted()
            case "\"":
                try doubleQuoted()
            case "\\":
                if take("\n") { break }
                append([take() ?? "\\"], quoted: true)
            case "$":
                try dollar()
            case "#" where word == nil:
                while let next = scalar(at: index), next != "\n" { index += 1 }
            case "~" where word == nil:
                guard atWordEnd || peek("/") else {
                    throw UncheckableShell(construct: "`~` other than for the home folder")
                }
                append(home.unicodeScalars, quoted: true)
            case "{" where word == nil && atWordEnd, "}" where word == nil && atWordEnd:
                throw UncheckableShell(construct: "`{ }` groups")
            case "*", "?", "{", "}":
                append([current], quoted: false)
                word?.isPattern = true
            case "=" where word == nil:
                append([current], quoted: false)
                word?.isPattern = true
            case "[":
                append([current], quoted: false)
                word?.hasOpenBracket = true
            case "]":
                append([current], quoted: false)
                if word?.hasOpenBracket == true { word?.isPattern = true }
            default:
                append([current], quoted: false)
            }
        }
        try endCommand()
        return commands
    }

    private mutating func singleQuoted() throws(UncheckableShell) {
        append([], quoted: true)
        while let current = take() {
            if current == "'" { return }
            append([current], quoted: true)
        }
        throw UncheckableShell(construct: "unclosed quotes")
    }

    private mutating func doubleQuoted() throws(UncheckableShell) {
        append([], quoted: true)
        while let current = take() {
            switch current {
            case "\"":
                return
            case "\\":
                if take("\n") { continue }
                if let next = scalar(at: index), "\"\\$`".unicodeScalars.contains(next) {
                    index += 1
                    append([next], quoted: true)
                } else {
                    append(["\\"], quoted: true)
                }
            case "$":
                try dollar()
            case "`":
                throw UncheckableShell(construct: "backticks")
            default:
                append([current], quoted: true)
            }
        }
        throw UncheckableShell(construct: "unclosed quotes")
    }

    private mutating func dollar() throws(UncheckableShell) {
        if peek("(") { throw UncheckableShell(construct: "`$(...)`") }
        let followsName = scalar(at: index + 4).map { $0 == "_" || $0.properties.isAlphabetic || ("0"..."9").contains($0) }
        if take("{HOME}") || (followsName != true && take("HOME")) {
            append(home.unicodeScalars, quoted: true)
            return
        }
        throw UncheckableShell(construct: "`$` other than in `$HOME`")
    }

    private mutating func startRedirect(
        _ kind: ShellCommand.Redirect.Kind,
        duplicates: Bool,
        takesDescriptor: Bool = true
    ) throws(UncheckableShell) {
        if takesDescriptor, word?.isDescriptor == true {
            word = nil
        } else {
            endWord()
        }
        guard pendingRedirect == nil else { throw UncheckableShell(construct: "a redirect with no file") }
        pendingRedirect = (kind, duplicates)
    }

    private mutating func endWord() {
        guard let partial = word else { return }
        word = nil
        let finished = ShellCommand.Word(text: String(partial.text), isPattern: partial.isPattern)
        guard let redirect = pendingRedirect else {
            command.words.append(finished)
            return
        }
        pendingRedirect = nil
        if redirect.duplicates, partial.isDescriptor || finished.text == "-" { return }
        command.redirects.append(ShellCommand.Redirect(kind: redirect.kind, target: finished))
    }

    private mutating func endCommand() throws(UncheckableShell) {
        endWord()
        guard pendingRedirect == nil else { throw UncheckableShell(construct: "a redirect with no file") }
        if let first = command.words.first, first.text.prefixMatch(of: /[A-Za-z_][A-Za-z0-9_]*\+?=/) != nil {
            throw UncheckableShell(construct: "variable assignments")
        }
        if !command.words.isEmpty || !command.redirects.isEmpty { commands.append(command) }
        command = ShellCommand.Simple()
    }

    private mutating func append(_ text: some Sequence<Unicode.Scalar>, quoted: Bool) {
        var partial = word ?? PartialWord()
        for scalar in text {
            partial.text.append(scalar)
            partial.isDescriptor = partial.isDescriptor && ("0"..."9").contains(scalar)
        }
        if quoted { partial.isDescriptor = false }
        word = partial
    }

    private var atWordEnd: Bool {
        scalar(at: index).map { " \t\n;&|<>()".unicodeScalars.contains($0) } ?? true
    }

    private func scalar(at position: Int) -> Unicode.Scalar? {
        scalars.indices.contains(position) ? scalars[position] : nil
    }

    private mutating func take() -> Unicode.Scalar? {
        defer { index += 1 }
        return scalar(at: index)
    }

    private func peek(_ literal: String) -> Bool {
        literal.unicodeScalars.enumerated().allSatisfy { scalar(at: index + $0.offset) == $0.element }
    }

    private mutating func take(_ literal: String) -> Bool {
        guard peek(literal) else { return false }
        index += literal.unicodeScalars.count
        return true
    }
}
