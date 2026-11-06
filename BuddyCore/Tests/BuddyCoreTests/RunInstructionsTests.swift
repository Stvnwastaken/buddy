import Foundation
import Testing
import BuddyCore

struct RunInstructionsTests {
    private static let autoRules = [
        "- Keep the shell in the run folder. Use paths instead of cd.",
        "- Buddy can check only plain commands:",
        "- Buddy approves each tool use. On its own it allows reading anything,"
    ]

    @Test func autoTeachesWhatBuddyAllowsOnItsOwn() {
        let instructions = RunInstructions.system(for: .auto)
        #expect(Self.autoRules.allSatisfy(instructions.contains))
        #expect(!instructions.contains("Your owner chose"))
    }

    @Test func approveOnlyKeepsBuddysRulesAndSaysEveryCommandAndChangeWaits() {
        let instructions = RunInstructions.system(for: .approveOnly)
        #expect(Self.autoRules.allSatisfy(instructions.contains))
        #expect(instructions.contains(
            "- Your owner chose to approve every command and file change themselves, even ones Buddy would allow on its own. "
                + "Each one waits on your card, so use as few as the task needs."
        ))
    }

    @Test func yoloDropsBuddysChecksAndKeepsAskingAboutTheOwnersChoices() {
        let instructions = RunInstructions.system(for: .yolo)
        #expect(!Self.autoRules.contains(where: instructions.contains))
        #expect(!instructions.contains("waits until your owner approves"))
        #expect(instructions.contains(
            "- Your owner chose to let you run any command and change any file without asking. Nothing stops a mistake, "
                + "so check each command before you run it and change only what the task needs."
        ))
        #expect(instructions.contains("Settle any detail that is your owner's choice with ask_owner first."))
    }

    @Test(arguments: ApprovalMode.allCases)
    func codexThreadStartsWithTheRunsInstructions(mode: ApprovalMode) throws {
        var stream = CodexRunStream(approvalMode: mode)
        _ = stream.start(RunBrief(request: "Make a folder.", captures: []), folder: "/tmp/run")
        _ = stream.received(Data(#"{"id":1,"result":{}}"#.utf8) + Data("\n".utf8))
        let output = stream.received(Data(#"{"id":2,"result":{"account":{"type":"chatgpt"}}}"#.utf8) + Data("\n".utf8))
        guard case .write(let data) = try #require(output.first) else { Issue.record("no thread/start"); return }
        let message = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(message["params"] as? [String: Any])
        #expect(params["baseInstructions"] as? String == RunInstructions.system(for: mode))
    }

    @Test(arguments: ApprovalMode.allCases)
    func claudeRunStartsWithTheRunsInstructions(mode: ApprovalMode) throws {
        let mcpURL = try #require(URL(string: "http://127.0.0.1:49152/mcp"))
        let launch = try #require(ClaudeLaunch.run(
            environment: ["HOME": "/Users/owner", "PATH": "/usr/bin:/bin"], folder: "/tmp/run",
            mcpURL: mcpURL, token: "t", approvalMode: mode,
            isExecutable: { $0 == "/Users/owner/.local/bin/claude" }
        ))
        let prompt = try #require(launch.arguments.firstIndex(of: "--system-prompt"))
        #expect(launch.arguments[prompt + 1] == RunInstructions.system(for: mode))
    }
}
