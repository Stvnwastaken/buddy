import Testing
import BuddyCore

struct CodexLaunchTests {
    @Test func talkUsesTheOwnersChatGPTSignInWithLiveWebSearchButWithoutTheirProxyHooksPluginsOrOtherTools() {
        let launch = CodexLaunch.talk(
            environment: [
                "HOME": "/Users/owner",
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "CODEX_HOME": "/Users/owner/.codex",
                "CODEX_SANDBOX": "seatbelt",
                "CODEX_COMPANION_SESSION_ID": "session-1",
                "OPENAI_BASE_URL": "http://100.64.0.7:8317/v1",
                "OPENAI_API_KEY": "proxy-key",
                "ANTHROPIC_BASE_URL": "http://100.64.0.7:8317"
            ],
            workingDirectory: "/Users/owner/Library/Application Support/Buddy/Codex",
            isExecutable: { $0 == "/Users/owner/.local/bin/codex" }
        )
        #expect(launch == ProcessLaunch(
            executable: "/Users/owner/.local/bin/codex",
            arguments: [
                "app-server",
                "-c", #"model_provider="openai""#,
                "-c", #"model_reasoning_effort="low""#,
                "-c", "notify=[]",
                "-c", "features.hooks=false",
                "-c", "features.plugins=false",
                "-c", "features.apps=false",
                "-c", "features.computer_use=false",
                "-c", "features.browser_use=false",
                "-c", "features.shell_tool=false",
                "-c", "features.unified_exec=false",
                "-c", "features.view_image=false",
                "-c", "features.sleep_tool=false",
                "-c", "features.image_generation=false",
                "-c", "features.goals=false",
                "-c", "features.tool_suggest=false",
                "-c", #"web_search="live""#,
                "-c", "skills.include_instructions=false",
                "-c", "include_permissions_instructions=false",
                "-c", "include_environment_context=false",
                "-c", "include_apps_instructions=false",
                "-c", "include_collaboration_mode_instructions=false",
                "-c", #"history.persistence="none""#
            ],
            environment: [
                "HOME": "/Users/owner",
                "PATH": "/Users/owner/.local/bin:/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "CODEX_HOME": "/Users/owner/.codex",
                "ANTHROPIC_BASE_URL": "http://100.64.0.7:8317"
            ],
            workingDirectory: "/Users/owner/Library/Application Support/Buddy/Codex"
        ))
    }

    @Test func utilityIsTheTalkServerWithWebSearchOff() {
        let environment = ["HOME": "/Users/owner", "PATH": "/usr/bin:/bin", "CODEX_HOME": "/Users/owner/.codex"]
        let talk = CodexLaunch.talk(environment: environment, workingDirectory: "/tmp/codex", isExecutable: { $0 == "/Users/owner/.local/bin/codex" })
        let utility = CodexLaunch.utility(environment: environment, workingDirectory: "/tmp/codex", isExecutable: { $0 == "/Users/owner/.local/bin/codex" })
        #expect(utility?.arguments.filter { $0.hasPrefix("web_search=") } == [#"web_search="disabled""#])
        #expect(utility?.arguments.filter { !$0.hasPrefix("web_search=") } == talk?.arguments.filter { !$0.hasPrefix("web_search=") })
        #expect(utility?.environment == talk?.environment)
    }

    @Test(arguments: [
        ("/usr/local/bin:/usr/bin", ["/usr/local/bin/codex", "/Users/owner/.local/bin/codex"], "/usr/local/bin/codex"),
        ("/usr/bin:/bin", ["/Users/owner/.local/bin/codex", "/opt/homebrew/bin/codex"], "/Users/owner/.local/bin/codex"),
        ("/usr/bin:/bin", ["/opt/homebrew/bin/codex"], "/opt/homebrew/bin/codex"),
        ("/usr/bin:/bin", ["/usr/local/bin/codex"], "/usr/local/bin/codex"),
        ("bin:/usr/bin", ["bin/codex"], nil),
        ("/usr/bin:/bin", ["/usr/bin/claude"], nil)
    ] as [(String, [String], String?)])
    func talkFindsCodexOnThePathThenInItsUsualInstallFolders(path: String, installed: [String], executable: String?) {
        let launch = CodexLaunch.talk(
            environment: ["HOME": "/Users/owner", "PATH": path],
            workingDirectory: "/tmp/talk",
            isExecutable: installed.contains
        )
        #expect(launch?.executable == executable)
    }
}
