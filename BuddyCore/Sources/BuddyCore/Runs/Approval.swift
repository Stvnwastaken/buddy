/// A tool use a run's provider asks Buddy to approve, in provider-neutral terms.
public enum ApprovalRequest: Equatable, Sendable {
    /// One of Buddy's own MCP tools, by its MCP name.
    case buddyTool(String)
    /// Reading or searching a file or folder. A relative path is inside the run folder.
    case read(path: String)
    /// Creating or replacing a file with new contents.
    case write(path: String)
    /// Changing part of an existing file.
    case edit(path: String)
    /// Removing a file.
    case delete(path: String)
    /// File changes made together, like the files of one Codex patch.
    case changes([ApprovalRequest])
    /// A shell command, run from the run folder.
    case command(String)
    /// Any other tool, by its provider's name.
    case other(tool: String)

    var action: String {
        switch self {
        case .buddyTool(let name): name
        case .read(let path): "read \(path)"
        case .write(let path): "write \(path)"
        case .edit(let path): "edit \(path)"
        case .delete(let path): "delete \(path)"
        case .changes(let changes): changes.map(\.action).joined(separator: ", ")
        case .command(let command): command
        case .other(let tool): tool
        }
    }
}

/// How much of a run's work the owner approves by hand. The owner picks it for runs started from then on.
public enum ApprovalMode: String, CaseIterable, Equatable, Sendable {
    /// The policy allows what is safe, denies what the run must do another way, and asks the owner about the rest.
    case auto
    /// Every command and file change waits for the owner. Reads and Buddy's own tools go through, and what the policy
    /// denies stays denied.
    case approveOnly
    /// Everything is allowed without asking, including what the policy would deny.
    case yolo
}

public enum Approval: Equatable, Sendable {
    case allow
    /// The reason goes to the run and into its run note.
    case deny(String)
}

/// What the approval policy makes of a request.
enum Verdict: Equatable, Sendable {
    case allow
    /// Something the run must do another way. The reason tells it how.
    case deny(String)
    /// Something only the owner may allow, such as sending, posting, buying, deleting, changing the owner's files or
    /// running a command outside the allowed set. The reason tells the owner why Buddy asks.
    case askOwner(String)
}

struct ApprovalPolicy: Sendable {
    let folder: String
    let home: String
    let fileExists: @Sendable (String) -> Bool
    let resolvePath: @Sendable (String) -> String?

    func decide(_ request: ApprovalRequest, in mode: ApprovalMode) -> Verdict {
        switch (mode, request) {
        case (.yolo, _):
            return .allow
        case (.approveOnly, .buddyTool), (.approveOnly, .read), (.auto, _):
            return decide(request)
        case (.approveOnly, _):
            let verdict = decide(request)
            return verdict == .allow ? .askOwner("You approve every command and file change.") : verdict
        }
    }

    func decide(_ request: ApprovalRequest) -> Verdict {
        switch request {
        case .buddyTool, .read:
            .allow
        case .write(let path):
            decide(.write, of: expandingTilde(path), by: "Runs")
        case .edit(let path):
            decide(.change("edit files"), of: expandingTilde(path), by: "Runs")
        case .delete(let path):
            decide(.change("delete files"), of: expandingTilde(path), by: "Runs")
        case .changes(let changes):
            changes.verdict(ofEach: decide)
        case .command(let text):
            decide(command: text)
        case .other(let tool):
            .deny("Buddy doesn't allow the \(tool) tool.")
        }
    }

    private func decide(command text: String) -> Verdict {
        do throws(UncheckableShell) {
            return try ShellCommand(parsing: text, home: home).commands.verdict(ofEach: decide)
        } catch {
            return .askOwner("Buddy can't check commands that use \(error.construct).")
        }
    }

    private func decide(_ command: ShellCommand.Simple) -> Verdict {
        if let program = command.words.first {
            let verdict = decide(program: program, arguments: Array(command.words.dropFirst()))
            guard verdict == .allow else { return verdict }
        }
        return command.redirects.verdict(ofEach: decide)
    }

    private func decide(_ redirect: ShellCommand.Redirect) -> Verdict {
        guard redirect.kind == .write else { return .allow }
        guard !redirect.target.isPattern else { return Self.uncheckable(redirect.target) }
        return decide(.write, of: redirect.target.text, by: "`>`")
    }

    static func uncheckable(_ pattern: ShellCommand.Word) -> Verdict {
        .askOwner("Buddy can't check a pattern like `\(pattern.text)`.")
    }
}

enum PathUse: Sendable {
    case write
    case makeFolder
    case change(String)
}

extension ApprovalPolicy {
    private enum Place { case runFolder, insideRunFolder, ownerPlace, elsewhere }

    func decide(_ use: PathUse, of path: String, by subject: String) -> Verdict {
        let absolute = absolutePath(path)
        let place = absolute.map(place(of:)) ?? .elsewhere
        switch use {
        case .write:
            if place == .insideRunFolder || absolute == "/dev/null" { return .allow }
            guard place == .ownerPlace, let absolute else {
                return .askOwner("\(subject) may only write inside the run folder or add new files to the Desktop.")
            }
            return fileExists(absolute)
                ? .askOwner("`\(absolute)` already exists, and runs may only add new files outside their folder.")
                : .allow
        case .makeFolder:
            return place == .insideRunFolder || place == .ownerPlace
                ? .allow
                : .askOwner("\(subject) may only make folders inside the run folder or in the Desktop.")
        case .change(let what):
            return place == .insideRunFolder ? .allow : .askOwner("\(subject) may only \(what) inside the run folder.")
        }
    }

    private func absolutePath(_ path: String) -> String? {
        guard path.hasPrefix("/") else {
            return path.split(separator: "/").contains("..") ? nil : resolvePath(folder + "/" + path).map(standardized)
        }
        return resolvePath(path).map(standardized)
    }

    private func standardized(_ path: String) -> String {
        var kept: [Substring] = []
        for component in path.split(separator: "/") where component != "." {
            if component == ".." {
                _ = kept.popLast()
            } else {
                kept.append(component)
            }
        }
        return "/" + kept.joined(separator: "/")
    }

    private func place(of path: String) -> Place {
        if path == folder { return .runFolder }
        if path.hasPrefix(folder + "/") { return .insideRunFolder }
        guard path.hasPrefix(home + "/") else { return .elsewhere }
        let below = path.dropFirst(home.count + 1).split(separator: "/")
        guard let first = below.first, first == "Desktop",
              !below.contains(where: { $0.hasPrefix(".") })
        else { return .elsewhere }
        return .ownerPlace
    }

    private func expandingTilde(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? home + path.dropFirst() : path
    }
}

extension Sequence {
    /// The first denial, else the first reason to ask the owner, else allow. A denial wins so the owner is never
    /// asked about a command Buddy would refuse anyway.
    func verdict(ofEach check: (Element) -> Verdict) -> Verdict {
        var ask: Verdict?
        for element in self {
            switch check(element) {
            case .allow: continue
            case .deny(let reason): return .deny(reason)
            case .askOwner(let reason): ask = ask ?? .askOwner(reason)
            }
        }
        return ask ?? .allow
    }
}
