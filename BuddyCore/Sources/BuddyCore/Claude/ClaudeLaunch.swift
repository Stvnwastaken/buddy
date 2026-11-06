import Foundation

public struct ClaudeProxy: Equatable, Sendable {
    public let baseURL: String
    public let token: String
    public let model: String

    public init(baseURL: String, token: String, model: String) {
        self.baseURL = baseURL
        self.token = token
        self.model = model
    }
}

/// How to start the owner's `claude` for talk, the utility model and agent runs.
public enum ClaudeLaunch {
    /// The owner's Claude Code set up for talk, or nil when no `claude` is installed.
    ///
    /// It signs in with the CLI's login unless an explicit proxy supplies its endpoint, token and model. Its only tool
    /// is web search, which runs without asking. The app keeps its own history, so the CLI saves no session, and its
    /// screenshots never reach the disk.
    public static func talk(
        environment: [String: String],
        workingDirectory: String,
        proxy: ClaudeProxy? = nil,
        isExecutable: (String) -> Bool
    ) -> ProcessLaunch? {
        printSession(
            model: proxy?.model ?? "sonnet", instructions: TalkInstructions.system, tools: ["WebSearch"],
            environment: environment, workingDirectory: workingDirectory, proxy: proxy, isExecutable: isExecutable
        )
    }

    /// The owner's Claude Code set up for the utility model, like talk but on a small fast model with its own
    /// instructions and no tools. A proxy's model should be the selected account's small model.
    public static func utility(
        environment: [String: String],
        workingDirectory: String,
        proxy: ClaudeProxy? = nil,
        isExecutable: (String) -> Bool
    ) -> ProcessLaunch? {
        printSession(
            model: proxy?.model ?? "haiku", instructions: UtilityInstructions.system, tools: [],
            environment: environment, workingDirectory: workingDirectory, proxy: proxy, isExecutable: isExecutable
        )
    }

    private static func printSession(
        model: String,
        instructions: String,
        tools: [String],
        environment: [String: String],
        workingDirectory: String,
        proxy: ClaudeProxy?,
        isExecutable: (String) -> Bool
    ) -> ProcessLaunch? {
        guard let claude = installedClaude(environment: environment, isExecutable: isExecutable) else { return nil }
        var childEnvironment = claude.environment
        if let proxy {
            childEnvironment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
            childEnvironment["ANTHROPIC_BASE_URL"] = proxy.baseURL
            childEnvironment["ANTHROPIC_AUTH_TOKEN"] = proxy.token
        }
        return ProcessLaunch(
            executable: claude.executable,
            arguments: [
                "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--include-partial-messages",
                "--verbose",
                "--model", model,
                "--system-prompt", instructions,
                "--tools", tools.joined(separator: ",")
            ] + (tools.isEmpty ? [] : ["--allowedTools", tools.joined(separator: ",")]) + [
                "--setting-sources", "",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--no-session-persistence"
            ],
            environment: childEnvironment,
            workingDirectory: workingDirectory
        )
    }

    /// The owner's Claude Code set up for one agent run in its folder, or nil when no `claude` is installed.
    ///
    /// It has shell and file tools, and Buddy's MCP server at `mcpURL` is the only one it sees. The bearer token
    /// reaches it through `BUDDY_MCP_TOKEN`, which the CLI expands in the MCP config, so the token stays out of the
    /// process list. Every permission prompt comes to Buddy as a `can_use_tool` request on stdout.
    ///
    /// A tool call may wait for the owner's answer as long as the run may last. Without the server's `timeout`, the
    /// CLI gives up on an HTTP tool call that sends nothing back for a minute.
    ///
    /// Claude Code runs commands in a snapshot of the shell's startup files, so the owner's aliases and functions
    /// would run in place of the programs the approval policy judged, like an `ls` or `cd` alias. The run's zsh reads
    /// its startup files from the empty `/var/empty` instead, and bash has no startup file to read.
    public static func run(
        environment: [String: String],
        folder: String,
        mcpURL: URL,
        token: String,
        approvalMode: ApprovalMode,
        isExecutable: (String) -> Bool
    ) -> ProcessLaunch? {
        guard let claude = installedClaude(environment: environment, isExecutable: isExecutable) else { return nil }
        let server: [String: Any] = [
            "type": "http",
            "url": mcpURL.absoluteString,
            "headers": ["Authorization": "Bearer ${BUDDY_MCP_TOKEN}"],
            "timeout": RunLimits.standard.seconds * 1000
        ]
        let mcpConfig = try! JSONSerialization.data(
            withJSONObject: ["mcpServers": ["buddy": server]],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return ProcessLaunch(
            executable: claude.executable,
            arguments: [
                "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--model", "opus",
                "--system-prompt", RunInstructions.system(for: approvalMode),
                "--tools", "Bash,Read,Write,Edit,Glob,Grep",
                "--mcp-config", String(decoding: mcpConfig, as: UTF8.self),
                "--strict-mcp-config",
                "--permission-prompt-tool", "stdio",
                "--permission-mode", "default",
                "--settings", #"{"permissions":{"ask":["Bash","Read","Write","Edit","Glob","Grep","mcp__buddy__*"]}}"#,
                "--setting-sources", "",
                "--disable-slash-commands",
                "--no-session-persistence"
            ],
            environment: ProcessLaunch.runShell(claude.environment, path: claude.environment["PATH"] ?? "")
                .merging(["BUDDY_MCP_TOKEN": token, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]) { _, run in run },
            workingDirectory: folder
        )
    }

    /// Finds the owner's `claude` and the environment it runs in.
    ///
    /// It signs in with the CLI's own login. The owner's `ANTHROPIC_*` variables are removed, and so are the
    /// `CLAUDE*` variables a Claude Code shell sets, except the two that locate that login and the owner's opt-out
    /// of nonessential traffic. Each launch skips user settings, where the owner's proxy lives. `--bare` would only
    /// accept an API key, so it is never used.
    private static func installedClaude(
        environment: [String: String],
        isExecutable: (String) -> Bool
    ) -> (executable: String, environment: [String: String])? {
        let home = environment["HOME"].map { ["\($0)/.local/bin", "\($0)/.claude/local"] } ?? []
        guard let claude = ProcessLaunch.locate("claude", installFolders: home, environment: environment, isExecutable: isExecutable)
        else { return nil }
        let keptClaudeVariables: Set = ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]
        var childEnvironment = environment.filter { name, _ in
            keptClaudeVariables.contains(name) || !(name.hasPrefix("ANTHROPIC_") || name.hasPrefix("CLAUDE"))
        }
        childEnvironment["PATH"] = claude.path
        return (claude.executable, childEnvironment)
    }
}
