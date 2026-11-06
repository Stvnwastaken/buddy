import Foundation
import Testing
import BuddyCore

struct ClaudeRunLaunchTests {
    @Test func runWorksInItsFolderOnOpusWithShellAndFileToolsAndOnlyBuddysMCPServerAndNoShellStartupFiles() throws {
        let launch = ClaudeLaunch.run(
            environment: [
                "HOME": "/Users/owner",
                "PATH": "/usr/bin:/bin",
                "CLAUDE_CONFIG_DIR": "/Users/owner/.claude",
                "ANTHROPIC_BASE_URL": "http://100.64.0.7:8317",
                "CLAUDECODE": "1",
                "BUDDY_MCP_TOKEN": "stale-token",
                "SHELL": "/opt/homebrew/bin/fish",
                "ZDOTDIR": "/Users/owner/.config/zsh",
                "BASH_ENV": "/Users/owner/.bashrc",
                "ENV": "/Users/owner/.shrc"
            ],
            folder: runFolder,
            mcpURL: try #require(URL(string: "http://127.0.0.1:49152/mcp")),
            token: "run-token",
            approvalMode: .auto,
            isExecutable: { $0 == "/opt/homebrew/bin/claude" }
        )
        #expect(launch == ProcessLaunch(
            executable: "/opt/homebrew/bin/claude",
            arguments: [
                "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--model", "opus",
                "--system-prompt", RunInstructions.system(for: .auto),
                "--tools", "Bash,Read,Write,Edit,Glob,Grep",
                "--mcp-config",
                #"{"mcpServers":{"buddy":{"headers":{"Authorization":"Bearer ${BUDDY_MCP_TOKEN}"},"timeout":1200000,"type":"http","url":"http://127.0.0.1:49152/mcp"}}}"#,
                "--strict-mcp-config",
                "--permission-prompt-tool", "stdio",
                "--permission-mode", "default",
                "--settings", #"{"permissions":{"ask":["Bash","Read","Write","Edit","Glob","Grep","mcp__buddy__*"]}}"#,
                "--setting-sources", "",
                "--disable-slash-commands",
                "--no-session-persistence"
            ],
            environment: [
                "HOME": "/Users/owner",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/bin:/bin",
                "CLAUDE_CONFIG_DIR": "/Users/owner/.claude",
                "BUDDY_MCP_TOKEN": "run-token",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                "SHELL": "/bin/zsh",
                "ZDOTDIR": "/var/empty"
            ],
            workingDirectory: runFolder
        ))
    }

    @Test func runNeedsAnInstalledClaude() throws {
        #expect(ClaudeLaunch.run(
            environment: ["HOME": "/Users/owner", "PATH": "/usr/bin:/bin"],
            folder: runFolder,
            mcpURL: try #require(URL(string: "http://127.0.0.1:49152/mcp")),
            token: "run-token",
            approvalMode: .auto,
            isExecutable: { _ in false }
        ) == nil)
    }
}
