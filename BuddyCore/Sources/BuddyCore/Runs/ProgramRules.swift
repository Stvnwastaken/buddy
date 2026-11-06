enum ProgramRule: Sendable {
    case reads
    /// Only reads unless given a forbidden option or operands that don't fit. Its arguments must be literal, since a
    /// pattern could expand into a forbidden option, like a file the run named `-delete`.
    case readsGuarded(Options, Operands)
    case readsWith(subcommands: Set<String>)
    case changes(PathUse, flags: Set<Character>)
    case changesFolder
    case runsAppleScript

    struct Options: Sendable {
        /// One-letter options that take a value, attached or as the next argument.
        var valued: Set<Character> = []
        /// Options that make the program write or run something, like `-o`, `--output` or find's `-delete`. A long
        /// option also matches its abbreviations, which getopt accepts.
        var forbidden: Set<String> = []
    }

    enum Operands: Sendable {
        case any
        /// At most one, since a second operand is where the program writes.
        case atMostOne
        /// None, since an operand is a new setting.
        case none
        /// Only `+format`, since any other operand is a new date.
        case formats
        /// Only names, since `name=value` is a new setting.
        case names
    }
}

extension ApprovalPolicy {
    static let programs: [String: ProgramRule] = {
        let readers = [
            "ls", "cat", "head", "tail", "wc", "pwd", "echo", "whoami", "id", "uname", "sw_vers", "which",
            "stat", "du", "df", "ps", "mdfind", "cut", "tr", "grep", "egrep", "fgrep", "basename", "dirname",
            "realpath", "test", "[", "true", "false", "diff", "cmp", "comm", "nl", "column", "system_profiler"
        ]
        let guarded: [String: ProgramRule] = [
            "printf": .readsGuarded(.init(forbidden: ["-v"]), .any),
            "sort": .readsGuarded(.init(
                valued: ["k", "o", "S", "T", "t"],
                forbidden: ["-o", "--output", "-T", "--temporary-directory", "--compress-program"]
            ), .any),
            "uniq": .readsGuarded(.init(valued: ["f", "s"]), .atMostOne),
            "date": .readsGuarded(.init(valued: ["d", "f", "r", "s", "v", "z"], forbidden: ["-s", "--set"]), .formats),
            "file": .readsGuarded(.init(valued: ["e", "F", "f", "m", "M", "P"], forbidden: ["-C", "--compile"]), .any),
            "hostname": .readsGuarded(.init(forbidden: ["-F", "--file"]), .none),
            "mdls": .readsGuarded(.init(valued: ["m", "n"], forbidden: ["-plist", "-p"]), .any),
            "find": .readsGuarded(.init(forbidden: [
                "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"
            ]), .any),
            "sysctl": .readsGuarded(.init(
                valued: ["B"],
                forbidden: ["-w", "-f", "-p", "--write", "--load", "--system"]
            ), .names),
            "defaults": .readsWith(subcommands: ["read", "read-type", "domains", "find"]),
            "plutil": .readsWith(subcommands: ["-p", "-lint", "-help"]),
            "mkdir": .changes(.makeFolder, flags: ["p", "v"]),
            "touch": .changes(.change("change files"), flags: ["c"]),
            "rm": .changes(.change("remove files"), flags: ["d", "f", "R", "r", "v"]),
            "rmdir": .changes(.change("remove folders"), flags: ["v"]),
            "cd": .changesFolder,
            "osascript": .runsAppleScript
        ]
        return guarded.merging(readers.map { ($0, .reads) }) { rule, _ in rule }
    }()

    func decide(program: ShellCommand.Word, arguments: [ShellCommand.Word]) -> Verdict {
        guard let name = Self.programName(program.text), let rule = Self.programs[name] else {
            return Self.notListed(program.text)
        }
        if name == "printf", program.text != "/usr/bin/printf" {
            return .deny("Use `/usr/bin/printf` so the shell cannot change variables.")
        }
        if case .reads = rule { return .allow }
        if let pattern = arguments.first(where: \.isPattern) { return Self.uncheckable(pattern) }
        let arguments = arguments.map(\.text)
        switch rule {
        case .reads:
            return .allow
        case .readsGuarded(let options, let operands):
            let (found, forbidden) = options.operands(in: arguments)
            if let forbidden { return Self.notListed("\(name) \(forbidden)") }
            return operands.verdict(of: found, program: name)
        case .readsWith(let subcommands):
            guard let first = arguments.first, subcommands.contains(first) else {
                return Self.notListed(([name] + arguments.prefix(1)).joined(separator: " "))
            }
            return .allow
        case .changes(let use, let flags):
            var operands: [String] = []
            var rest = arguments[...]
            while let argument = rest.popFirst() {
                if argument == "--" {
                    operands += rest
                    break
                }
                guard argument.hasPrefix("-"), argument != "-" else {
                    operands.append(argument)
                    continue
                }
                guard !argument.hasPrefix("--"), argument.dropFirst().allSatisfy(flags.contains) else {
                    return Self.notListed("\(name) \(argument)")
                }
            }
            return operands.verdict(ofEach: { decide(use, of: $0, by: "`\(name)`") })
        case .changesFolder:
            return .deny("Buddy keeps commands in the run folder; use paths instead of `cd`.")
        case .runsAppleScript:
            return decide(osascript: arguments)
        }
    }

    private static func programName(_ word: String) -> String? {
        let folder = ["/bin/", "/usr/bin/", "/usr/sbin/", "/sbin/"].first { word.hasPrefix($0) }
        let name = folder.map { String(word.dropFirst($0.count)) } ?? word
        return name.contains("/") ? nil : name
    }

    private static func notListed(_ command: String) -> Verdict {
        .askOwner("`\(command)` isn't on Buddy's list of allowed commands.")
    }

    private func decide(osascript arguments: [String]) -> Verdict {
        let onlyScripts = Verdict.askOwner("`osascript` may only run AppleScript given with -e.")
        var scripts: [String] = []
        var rest = arguments[...]
        while let option = rest.popFirst() {
            switch (option, rest.popFirst()) {
            case ("-e", let script?):
                scripts.append(script)
            case ("-s", let flags?) where flags.allSatisfy("eosh".contains):
                continue
            default:
                return onlyScripts
            }
        }
        return scripts.isEmpty ? onlyScripts : AppleScriptReading.verdict(of: scripts.joined(separator: "\n"))
    }
}

extension ProgramRule.Options {
    func operands(in arguments: [String]) -> (operands: [String], forbidden: String?) {
        var operands: [String] = []
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--" {
                operands += rest
                break
            }
            guard argument.hasPrefix("-"), argument != "-" else {
                operands.append(argument)
                continue
            }
            if forbidden.contains(argument) { return (operands, argument) }
            if argument.hasPrefix("--") {
                let name = String(argument.prefix { $0 != "=" })
                if forbidden.contains(where: { $0.hasPrefix("--") && $0.hasPrefix(name) }) { return (operands, name) }
                continue
            }
            for (offset, letter) in argument.dropFirst().enumerated() {
                if forbidden.contains("-\(letter)") { return (operands, "-\(letter)") }
                if valued.contains(letter) {
                    if offset == argument.count - 2 { _ = rest.popFirst() }
                    break
                }
            }
        }
        return (operands, nil)
    }
}

extension ProgramRule.Operands {
    func verdict(of operands: [String], program: String) -> Verdict {
        switch self {
        case .any:
            .allow
        case .atMostOne:
            operands.count <= 1 ? .allow : .askOwner("`\(program)` may only take one file, since a second one is where it writes.")
        case .none:
            operands.isEmpty ? .allow : .askOwner("`\(program)` may only show its setting, not change it.")
        case .formats:
            operands.allSatisfy { $0.hasPrefix("+") }
                ? .allow
                : .askOwner("`\(program)` may only show the date, so each operand must start with `+`.")
        case .names:
            operands.contains { $0.contains("=") } ? .askOwner("`\(program)` may only read settings, not change them.") : .allow
        }
    }
}
