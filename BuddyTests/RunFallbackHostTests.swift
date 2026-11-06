import BuddyCore
import Foundation
import Testing
@testable import Buddy

@MainActor
struct RunFallbackHostTests {
    @Test func simulatedLimitFinishesOnTheOtherProviderWithoutRepeatingTheFirstAction() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buddy-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let run = FallbackRun(root: root)
        defer { run.host.stopAll() }
        run.start()
        let deadline = ContinuousClock.now + .seconds(20)
        while run.engine.state.runs.first?.isActive == true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(run.engine.state.runs.first?.status == .done)
        #expect(run.launched == [.claudeCode, .codex])
        #expect(run.folders.count == 2)
        #expect(run.folders.first == run.folders.last)
        #expect(run.tokens.count == 2)
        #expect(run.tokens.first != run.tokens.last)
        let folder = try #require(run.folders.first)
        #expect(try String(contentsOf: folder.appending(path: "output/actions.txt"), encoding: .utf8) == "first\nsecond\n")
        #expect(try String(contentsOf: folder.appending(path: "brief.md"), encoding: .utf8) == "# Brief\n\nThe owner asked: complete two actions\n")
        #expect(try String(contentsOf: folder.appending(path: "note.md"), encoding: .utf8) == "# Two actions\n- [x] First\n- [x] Second\n\n## Provider switch\nClaude reached its limit. Switched to Codex; continuing from the saved progress.")
        #expect(try String(contentsOf: folder.appending(path: "report.md"), encoding: .utf8) == "Asked: complete two actions\n\nCompleted both actions once.\n")
        let input = try String(contentsOf: folder.appending(path: "scratch/resume.json"), encoding: .utf8)
        #expect(input.contains("First action completed; second is still pending."))
        #expect(input.contains("- [x] First"))
        #expect(input.contains("Do not repeat completed actions."))
        #expect(run.engine.state.runs.first?.denials == [])
        #expect(run.engine.state.runs.first?.asks == [])
        #expect(run.startCount == 1)
        #expect(run.resumeCount == 1)
    }
}

@MainActor
private final class FallbackRun {
    var engine = BuddyEngine(providerConnected: true)
    var launched: [ProviderCLI] = []
    var folders: [URL] = []
    var tokens: [String] = []
    var startCount = 0
    var resumeCount = 0
    private let root: URL

    lazy var host = AgentRunHost(runsFolder: root) { [unowned self] cli, _, folder, port, token in
        launched.append(cli)
        folders.append(folder)
        tokens.append(token)
        return ProcessLaunch(
            executable: "/usr/bin/python3", arguments: ["-c", Self.provider],
            environment: ["BUDDY_TEST_CLI": cli == .codex ? "codex" : "claude", "BUDDY_TEST_PORT": String(port), "BUDDY_TEST_TOKEN": token],
            workingDirectory: folder.path
        )
    }

    init(root: URL) { self.root = root }

    func start() {
        for event: BuddyEngine.Event in [
            .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("agent, complete two actions"), .screensCaptured([])
        ] { send(event) }
    }

    func send(_ event: BuddyEngine.Event) {
        for effect in engine.handle(event) {
            switch effect {
            case .startRun(let id, let brief, let cli, let mode):
                startCount += 1
                host.start(id, brief, on: cli, approving: mode) { [weak self] in self?.send(.run(id, $0)) }
            case .pauseRun(let id), .stopRun(let id): host.stop(id)
            case .resumeRun(let id, let brief, let cli, let mode):
                resumeCount += 1
                host.resume(id, brief, on: cli, approving: mode) { [weak self] in self?.send(.run(id, $0)) }
            case .saveRunNote(let id, let note): host.saveNote(id, note)
            case .saveRunReport(let id, let report): host.saveReport(id, report)
            case .answerApproval(let id, let request, let answer): host.answerApproval(id, request: request, answer)
            case .answerTool(let call, let answer): host.answerTool(call, answer)
            case .speak: send(.lineStarted); send(.lineFinished)
            default: break
            }
        }
    }

    private static let provider = #"""
    import json, os, pathlib, sys, urllib.request
    def emit(value):
        print(json.dumps(value), flush=True)
    def read():
        return json.loads(sys.stdin.readline())
    def note(text):
        data = json.dumps({"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"update_run_note","arguments":{"note":text}}}).encode()
        request = urllib.request.Request("http://127.0.0.1:" + os.environ["BUDDY_TEST_PORT"] + "/mcp", data=data, headers={"Authorization":"Bearer " + os.environ["BUDDY_TEST_TOKEN"], "Content-Type":"application/json"})
        with urllib.request.urlopen(request, timeout=5) as response:
            assert not json.load(response)["result"].get("isError", False)
    if os.environ["BUDDY_TEST_CLI"] == "claude":
        read()
        emit({"type":"assistant","message":{"content":[{"type":"tool_use"}]}})
        emit({"type":"control_request","request_id":"first","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"output/actions.txt","content":"first\n"}}})
        assert read()["response"]["response"]["behavior"] == "allow"
        pathlib.Path("output/actions.txt").write_text("first\n")
        note("# Two actions\n- [x] First\n- [ ] Second")
        emit({"type":"assistant","message":{"content":[{"type":"text","text":"First action completed; second is still pending."}]}})
        emit({"type":"assistant","error":"rate_limit"})
        emit({"type":"result","is_error":True,"result":"Simulated limit"})
    else:
        assert read()["method"] == "initialize"
        emit({"id":1,"result":{}})
        assert read()["method"] == "initialized"
        assert read()["method"] == "account/read"
        emit({"id":2,"result":{"account":{"type":"chatgpt"}}})
        assert read()["method"] == "thread/start"
        emit({"id":3,"result":{"thread":{"id":"t"},"cwd":os.getcwd(),"approvalPolicy":"untrusted","approvalsReviewer":"user"}})
        turn = read()
        pathlib.Path("scratch/resume.json").write_text(json.dumps(turn))
        assert "First action completed; second is still pending." in str(turn)
        assert pathlib.Path("output/actions.txt").read_text() == "first\n"
        emit({"id":4,"result":{"turn":{"id":"u"}}})
        emit({"method":"item/commandExecution/requestApproval","id":99,"params":{"threadId":"t","turnId":"u","itemId":"second","command":"/usr/bin/printf 'second\\n' >> output/actions.txt","cwd":os.getcwd()}})
        assert read()["result"]["decision"] == "accept"
        with open("output/actions.txt", "a") as output:
            output.write("second\n")
        note("# Two actions\n- [x] First\n- [x] Second")
        emit({"method":"item/completed","params":{"threadId":"t","item":{"type":"agentMessage","id":"m","text":"Completed both actions once."}}})
        emit({"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"completed","error":None}}})
    """#
}
