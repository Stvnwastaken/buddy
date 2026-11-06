import Testing
import BuddyCore

struct ClaudeLaunchTests {
    @Test func proxyUsesTheChosenModelAndHubWithoutTheLocalOAuthToken() {
        let launch = ClaudeLaunch.talk(
            environment: [
                "HOME": "/Users/owner", "PATH": "/usr/bin", "LANG": "en_US.UTF-8",
                "CLAUDE_CODE_OAUTH_TOKEN": "local-login", "ANTHROPIC_AUTH_TOKEN": "wrong-proxy",
                "ANTHROPIC_BASE_URL": "https://wrong.example", "CLAUDE_CODE_USE_BEDROCK": "1"
            ],
            workingDirectory: "/tmp/talk",
            proxy: ClaudeProxy(baseURL: "https://hub.example:8317", token: "hub-access", model: "buddy-account/gpt-6.1-sol"),
            isExecutable: { $0 == "/Users/owner/.local/bin/claude" }
        )
        #expect(launch?.environment == [
            "HOME": "/Users/owner", "PATH": "/Users/owner/.local/bin:/usr/bin", "LANG": "en_US.UTF-8",
            "ANTHROPIC_BASE_URL": "https://hub.example:8317", "ANTHROPIC_AUTH_TOKEN": "hub-access"
        ])
        #expect(launch?.arguments.contains("buddy-account/gpt-6.1-sol") == true)
        #expect(launch?.arguments.contains("sonnet") == false)
        #expect(launch?.arguments.contains("hub-access") == false)
        #expect(launch?.arguments.contains("--no-session-persistence") == true)
        #expect(launch?.workingDirectory == "/tmp/talk")
    }

    @Test func talkUsesTheCLIsOwnLoginAndTheOwnersOptOutsFromAnEmptyFolderWithOnlyWebSearchAndNoUserSettings() {
        let launch = ClaudeLaunch.talk(
            environment: [
                "HOME": "/Users/owner",
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "CLAUDE_CONFIG_DIR": "/Users/owner/.claude",
                "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat-owner",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                "DISABLE_TELEMETRY": "1",
                "ANTHROPIC_BASE_URL": "http://100.64.0.7:8317",
                "ANTHROPIC_AUTH_TOKEN": "proxy-token",
                "CLAUDECODE": "1",
                "CLAUDE_CODE_ENTRYPOINT": "cli",
                "CLAUDE_CODE_USE_BEDROCK": "1",
                "CLAUDE_EFFORT": "max"
            ],
            workingDirectory: "/Users/owner/Library/Application Support/Buddy/Claude",
            isExecutable: { $0 == "/Users/owner/.local/bin/claude" }
        )
        #expect(launch == ProcessLaunch(
            executable: "/Users/owner/.local/bin/claude",
            arguments: [
                "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--include-partial-messages",
                "--verbose",
                "--model", "sonnet",
                "--system-prompt", TalkInstructions.system,
                "--tools", "WebSearch",
                "--allowedTools", "WebSearch",
                "--setting-sources", "",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--no-session-persistence"
            ],
            environment: [
                "HOME": "/Users/owner",
                "PATH": "/Users/owner/.local/bin:/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "CLAUDE_CONFIG_DIR": "/Users/owner/.claude",
                "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat-owner",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                "DISABLE_TELEMETRY": "1"
            ],
            workingDirectory: "/Users/owner/Library/Application Support/Buddy/Claude"
        ))
    }

    @Test(arguments: [
        ("/usr/local/bin:/usr/bin", ["/usr/local/bin/claude", "/Users/owner/.local/bin/claude"], "/usr/local/bin/claude"),
        ("/usr/bin:/bin", ["/Users/owner/.local/bin/claude", "/opt/homebrew/bin/claude"], "/Users/owner/.local/bin/claude"),
        ("/usr/bin:/bin", ["/Users/owner/.claude/local/claude"], "/Users/owner/.claude/local/claude"),
        ("/usr/bin:/bin", ["/opt/homebrew/bin/claude"], "/opt/homebrew/bin/claude"),
        ("/usr/bin:/bin", ["/usr/local/bin/claude"], "/usr/local/bin/claude"),
        ("bin:/usr/bin", ["bin/claude"], nil),
        ("/usr/bin:/bin", [], nil)
    ] as [(String, [String], String?)])
    func talkFindsClaudeOnThePathThenInItsUsualInstallFolders(path: String, installed: [String], executable: String?) {
        let launch = ClaudeLaunch.talk(
            environment: ["HOME": "/Users/owner", "PATH": path],
            workingDirectory: "/tmp/talk",
            isExecutable: installed.contains
        )
        #expect(launch?.executable == executable)
    }
}
