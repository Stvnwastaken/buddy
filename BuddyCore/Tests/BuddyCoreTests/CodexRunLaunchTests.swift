import Foundation
import Testing
import BuddyCore

struct CodexRunLaunchTests {
    @Test func runWorksInItsFolderFromBuddysCodexHomeWithOnlyBuddysMCPServerAndNoShellStartupFiles() throws {
        let launch = CodexLaunch.run(
            environment: [
                "HOME": "/Users/owner",
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "CODEX_HOME": "/Users/owner/.codex",
                "CODEX_SANDBOX": "seatbelt",
                "OPENAI_API_KEY": "proxy-key",
                "BUDDY_MCP_TOKEN": "stale-token",
                "SHELL": "/opt/homebrew/bin/fish",
                "ZDOTDIR": "/Users/owner/.config/zsh",
                "BASH_ENV": "/Users/owner/.bashrc",
                "ENV": "/Users/owner/.shrc"
            ],
            folder: runFolder,
            codexHome: "/Users/owner/Library/Application Support/Buddy/Codex run home",
            mcpURL: try #require(URL(string: "http://127.0.0.1:49152/mcp")),
            token: "run-token",
            isExecutable: { $0 == "/Users/owner/.local/bin/codex" }
        )
        #expect(launch == ProcessLaunch(
            executable: "/Users/owner/.local/bin/codex",
            arguments: [
                "app-server",
                "-c", #"model_provider="openai""#,
                "-c", #"cli_auth_credentials_store="file""#,
                "-c", "notify=[]",
                "-c", "features.hooks=false",
                "-c", "features.plugins=false",
                "-c", "features.apps=false",
                "-c", "features.computer_use=false",
                "-c", "features.browser_use=false",
                "-c", "features.image_generation=false",
                "-c", "features.goals=false",
                "-c", "features.tool_suggest=false",
                "-c", "features.multi_agent=false",
                "-c", "features.shell_snapshot=false",
                "-c", "features.unified_exec=false",
                "-c", "features.sleep_tool=false",
                "-c", #"web_search="disabled""#,
                "-c", "skills.include_instructions=false",
                "-c", "include_apps_instructions=false",
                "-c", "include_collaboration_mode_instructions=false",
                "-c", #"history.persistence="none""#,
                "-c", #"shell_environment_policy.filters.BUDDY_MCP_TOKEN="exclude""#,
                "-c", #"mcp_servers.buddy.url="http://127.0.0.1:49152/mcp""#,
                "-c", #"mcp_servers.buddy.bearer_token_env_var="BUDDY_MCP_TOKEN""#,
                "-c", #"mcp_servers.buddy.default_tools_approval_mode="approve""#,
                "-c", "mcp_servers.buddy.required=true",
                "-c", "mcp_servers.buddy.tool_timeout_sec=1200"
            ],
            environment: [
                "HOME": "/Users/owner",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/Users/owner/.local/bin:/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "CODEX_HOME": "/Users/owner/Library/Application Support/Buddy/Codex run home",
                "BUDDY_MCP_TOKEN": "run-token",
                "SHELL": "/bin/zsh",
                "ZDOTDIR": "/var/empty"
            ],
            workingDirectory: runFolder
        ))
    }

    @Test func runIsNilWithoutCodex() throws {
        #expect(CodexLaunch.run(
            environment: ["HOME": "/Users/owner", "PATH": "/usr/bin:/bin"], folder: runFolder, codexHome: "/tmp/home",
            mcpURL: try #require(URL(string: "http://127.0.0.1:49152/mcp")), token: "t", isExecutable: { _ in false }
        ) == nil)
    }

    @Test(arguments: [
        (["HOME": "/Users/owner", "CODEX_HOME": "/Volumes/Work/codex"], "/Volumes/Work/codex"),
        (["HOME": "/Users/owner"], "/Users/owner/.codex"),
        ([:], nil)
    ] as [([String: String], String?)])
    func ownersSignInIsInTheirCodexHome(environment: [String: String], home: String?) {
        #expect(CodexLaunch.ownerHome(environment: environment) == home)
    }

    @Test func runHomeLinksTheOwnersSignInAndLockAndFollowsTheirHomeWhenItMoves() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buddy-codex-home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = "\(root)/run home"
        try CodexLaunch.linkSignIn(of: "\(root)/owner", into: home)
        try CodexLaunch.linkSignIn(of: "\(root)/owner", into: home)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home).sorted() == ["auth.json", "auth.lock"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(home)/auth.json") == "\(root)/owner/auth.json")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(home)/auth.lock") == "\(root)/owner/auth.lock")

        try CodexLaunch.linkSignIn(of: "\(root)/moved", into: home)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(home)/auth.json") == "\(root)/moved/auth.json")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(home)/auth.lock") == "\(root)/moved/auth.lock")
    }

    @Test func aSignInCodexSavedInPlaceOfTheLinkIsKept() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buddy-codex-home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = "\(root)/run home"
        try CodexLaunch.linkSignIn(of: "\(root)/owner", into: home)
        try FileManager.default.removeItem(atPath: "\(home)/auth.json")
        try Data("newer".utf8).write(to: URL(fileURLWithPath: "\(home)/auth.json"))

        #expect(throws: CodexLaunch.SignInReplaced()) { try CodexLaunch.linkSignIn(of: "\(root)/owner", into: home) }
        #expect(try String(contentsOfFile: "\(home)/auth.json", encoding: .utf8) == "newer")
        #expect(CodexLaunch.SignInReplaced().localizedDescription
            == "Codex saved its own copy of your sign-in in place of Buddy's link, and that copy may be the newer one.")
    }
}
