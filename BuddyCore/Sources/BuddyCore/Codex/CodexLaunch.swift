import Foundation

public enum CodexLaunch {
    /// The owner's Codex app server set up for talk, or nil when no `codex` is installed.
    ///
    /// It signs in with the owner's ChatGPT login in their Codex home. Talk always uses the built-in OpenAI provider,
    /// so the proxy provider in the owner's config is never used. The owner's `OPENAI_*` variables are removed, and so
    /// are the `CODEX_*` variables a Codex shell sets, except `CODEX_HOME`, which locates that login. Hooks, plugins,
    /// apps, skills and every tool the overrides can switch off stay off except live web search, and the server keeps
    /// no history. The thread switches off the owner's MCP servers, because these overrides can't name them.
    public static func talk(
        environment: [String: String],
        workingDirectory: String,
        isExecutable: (String) -> Bool
    ) -> ProcessLaunch? {
        appServer(webSearch: true, environment: environment, workingDirectory: workingDirectory, isExecutable: isExecutable)
    }

    /// The owner's Codex app server set up for the utility model: the talk server with web search off too.
    public static func utility(
        environment: [String: String],
        workingDirectory: String,
        isExecutable: (String) -> Bool
    ) -> ProcessLaunch? {
        appServer(webSearch: false, environment: environment, workingDirectory: workingDirectory, isExecutable: isExecutable)
    }

    private static func appServer(
        webSearch: Bool,
        environment: [String: String],
        workingDirectory: String,
        isExecutable: (String) -> Bool
    ) -> ProcessLaunch? {
        let overrides = [
            #"model_provider="openai""#,
            #"model_reasoning_effort="low""#,
            "notify=[]",
            "features.hooks=false",
            "features.plugins=false",
            "features.apps=false",
            "features.computer_use=false",
            "features.browser_use=false",
            "features.shell_tool=false",
            "features.unified_exec=false",
            "features.view_image=false",
            "features.sleep_tool=false",
            "features.image_generation=false",
            "features.goals=false",
            "features.tool_suggest=false",
            webSearch ? #"web_search="live""# : #"web_search="disabled""#,
            "skills.include_instructions=false",
            "include_permissions_instructions=false",
            "include_environment_context=false",
            "include_apps_instructions=false",
            "include_collaboration_mode_instructions=false",
            #"history.persistence="none""#
        ]
        guard let codex = ProcessLaunch.locate(
            "codex",
            installFolders: environment["HOME"].map { ["\($0)/.local/bin"] } ?? [],
            environment: environment,
            isExecutable: isExecutable
        ) else { return nil }
        var childEnvironment = environment.filter { name, _ in
            name == "CODEX_HOME" || !(name.hasPrefix("OPENAI_") || name.hasPrefix("CODEX_"))
        }
        childEnvironment["PATH"] = codex.path
        return ProcessLaunch(
            executable: codex.executable,
            arguments: ["app-server"] + overrides.flatMap { ["-c", $0] },
            environment: childEnvironment,
            workingDirectory: workingDirectory
        )
    }

    /// The owner's Codex app server set up for one agent run in its folder, or nil when no `codex` is installed.
    ///
    /// It runs in `codexHome`, Buddy's own Codex home, which holds only links to the owner's `auth.json` and
    /// `auth.lock`. So it signs in and refreshes with the owner's ChatGPT login, but none of their config, rules,
    /// MCP servers, hooks or instructions apply. Their rules would let a command run without Buddy's approval.
    /// Buddy's MCP server at `mcpURL` is the only one it sees, reached with the bearer token in `BUDDY_MCP_TOKEN`,
    /// which commands don't inherit. A tool call may wait for the owner as long as the run may last.
    ///
    /// Commands run one at a time in the same plain shell as Claude's runs.
    public static func run(
        environment: [String: String],
        folder: String,
        codexHome: String,
        mcpURL: URL,
        token: String,
        isExecutable: (String) -> Bool
    ) -> ProcessLaunch? {
        let overrides = [
            #"model_provider="openai""#,
            #"cli_auth_credentials_store="file""#,
            "notify=[]",
            "features.hooks=false",
            "features.plugins=false",
            "features.apps=false",
            "features.computer_use=false",
            "features.browser_use=false",
            "features.image_generation=false",
            "features.goals=false",
            "features.tool_suggest=false",
            "features.multi_agent=false",
            "features.shell_snapshot=false",
            "features.unified_exec=false",
            "features.sleep_tool=false",
            #"web_search="disabled""#,
            "skills.include_instructions=false",
            "include_apps_instructions=false",
            "include_collaboration_mode_instructions=false",
            #"history.persistence="none""#,
            #"shell_environment_policy.filters.BUDDY_MCP_TOKEN="exclude""#,
            "mcp_servers.buddy.url=\"\(mcpURL.absoluteString)\"",
            #"mcp_servers.buddy.bearer_token_env_var="BUDDY_MCP_TOKEN""#,
            #"mcp_servers.buddy.default_tools_approval_mode="approve""#,
            "mcp_servers.buddy.required=true",
            "mcp_servers.buddy.tool_timeout_sec=\(RunLimits.standard.seconds)"
        ]
        guard let codex = ProcessLaunch.locate(
            "codex",
            installFolders: environment["HOME"].map { ["\($0)/.local/bin"] } ?? [],
            environment: environment,
            isExecutable: isExecutable
        ) else { return nil }
        let childEnvironment = ProcessLaunch.runShell(
            environment.filter { name, _ in !(name.hasPrefix("OPENAI_") || name.hasPrefix("CODEX_")) },
            path: codex.path
        ).merging(["CODEX_HOME": codexHome, "BUDDY_MCP_TOKEN": token]) { _, run in run }
        return ProcessLaunch(
            executable: codex.executable,
            arguments: ["app-server"] + overrides.flatMap { ["-c", $0] },
            environment: childEnvironment,
            workingDirectory: folder
        )
    }

    /// The Codex home whose `auth.json` holds the owner's sign-in: `CODEX_HOME`, or `~/.codex`.
    public static func ownerHome(environment: [String: String]) -> String? {
        environment["CODEX_HOME"] ?? environment["HOME"].map { "\($0)/.codex" }
    }

    /// Codex left a file of its own where Buddy's run home links to the owner's sign-in.
    public struct SignInReplaced: LocalizedError, Equatable {
        public init() {}
        public var errorDescription: String? {
            "Codex saved its own copy of your sign-in in place of Buddy's link, and that copy may be the newer one."
        }
    }

    /// Makes `home` a Codex home for runs, with links to the owner's `auth.json` and `auth.lock` in `ownerHome`.
    /// Codex writes a refreshed token through the link into the owner's file, under the owner's lock, so the
    /// owner's terminal Codex and Buddy's runs keep one sign-in. A link to another home is replaced. A file Codex
    /// saved in place of a link is kept, because its token may be the only one still valid, and this throws.
    public static func linkSignIn(of ownerHome: String, into home: String) throws {
        let files = FileManager.default
        try files.createDirectory(atPath: home, withIntermediateDirectories: true)
        for name in ["auth.json", "auth.lock"] {
            let link = "\(home)/\(name)", target = "\(ownerHome)/\(name)"
            if let existing = try? files.destinationOfSymbolicLink(atPath: link) {
                if existing == target { continue }
                try files.removeItem(atPath: link)
            } else if (try? files.attributesOfItem(atPath: link)) != nil {
                throw SignInReplaced()
            }
            try files.createSymbolicLink(atPath: link, withDestinationPath: target)
        }
    }
}
