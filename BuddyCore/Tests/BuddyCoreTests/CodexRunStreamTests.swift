import Foundation
import Testing
import BuddyCore

private let thread = "00000000-0000-4000-8000-000000000003"
private let turn = "00000000-0000-4000-8000-000000000004"

private func line(_ json: String) -> RunStreamOutput {
    .write(Data((json + "\n").utf8))
}

private func line(_ object: [String: Any]) -> RunStreamOutput {
    var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    data.append(UInt8(ascii: "\n"))
    return .write(data)
}

private func received(_ json: String, by stream: inout CodexRunStream) -> [RunStreamOutput] {
    stream.received(Data((json + "\n").utf8))
}

private func feed(_ text: String, inChunksOf size: Int, to stream: inout CodexRunStream) -> [RunStreamOutput] {
    let data = Data((text + "\n").utf8)
    return stride(from: data.startIndex, to: data.endIndex, by: size).flatMap { start in
        stream.received(data.subdata(in: start..<min(start + size, data.endIndex)))
    }
}

private func ready(policy: String = #""untrusted""#, reviewer: String = "user") -> String {
    #"{"id":3,"result":{"thread":{"id":"\#(thread)"},"cwd":"\#(runFolder)","approvalPolicy":\#(policy),"approvalsReviewer":"\#(reviewer)","sandbox":{"type":"dangerFullAccess"}}}"#
}

/// A stream whose thread has started, with the brief sent.
private func working(_ brief: RunBrief = RunBrief(request: "List my open apps.", captures: [])) -> CodexRunStream {
    var stream = CodexRunStream()
    _ = stream.start(brief, folder: runFolder)
    _ = received(#"{"id":1,"result":{"userAgent":"buddy/0.166.0"}}"#, by: &stream)
    _ = received(#"{"id":2,"result":{"account":{"type":"chatgpt","email":"owner@example.com"}}}"#, by: &stream)
    _ = received(ready(), by: &stream)
    return stream
}

private func commandApproval(_ command: String, cwd: String = runFolder, kind: String = "command") -> String {
    let fields: [String: Any] = [
        "id": 0, "method": "item/commandExecution/requestApproval",
        "params": ["kind": kind, "threadId": thread, "turnId": turn, "itemId": "exec-1", "command": command, "cwd": cwd]
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
}

private let threadStart = line([
    "id": 3, "method": "thread/start",
    "params": [
        "approvalsReviewer": "user",
        "baseInstructions": RunInstructions.system(for: .auto),
        "config": ["projects": [runFolder: ["trust_level": "untrusted"]]],
        "cwd": runFolder,
        "ephemeral": true,
        "sandbox": "danger-full-access"
    ] as [String: Any]
])

struct CodexRunStreamTests {
    @Test func usageLimitCarriesThePartialReportForTheOtherProvider() {
        var stream = working()
        #expect(received(#"{"method":"item/completed","params":{"threadId":"\#(thread)","item":{"type":"agentMessage","id":"m","text":"Listed apps; not saved yet."}}}"#, by: &stream) == [])
        #expect(received(#"{"method":"turn/completed","params":{"threadId":"\#(thread)","turn":{"id":"\#(turn)","status":"failed","error":{"message":"Usage limit reached","codexErrorInfo":"usageLimitExceeded"}}}}"#, by: &stream) == [
            .event(.limitReached(partialReport: "Listed apps; not saved yet.")), .closeInput
        ])
    }

    @Test(arguments: [1, 2, 7, 64, 100_000])
    func recordedRunReplaysIntoRunEventsHoweverTheOutputIsSplit(chunkSize: Int) throws {
        let segments = String(decoding: try fixture("codex-run"), as: UTF8.self).components(separatedBy: "\n\n")
        #expect(segments.count == 5)
        var stream = CodexRunStream()
        #expect(stream.start(RunBrief(request: "Make a folder.", captures: []), folder: runFolder) == [
            line(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"buddy","version":"1.0"}}}"#)
        ])
        #expect(feed(segments[0], inChunksOf: chunkSize, to: &stream) == [
            line(#"{"method":"initialized"}"#),
            line(#"{"id":2,"method":"account/read","params":{}}"#),
            threadStart,
            .event(.started(folder: runFolder)),
            line(#"{"id":4,"method":"turn/start","params":{"input":[{"text":"Your run folder is \#(runFolder).\n\nThe owner asked: Make a folder.","type":"text"}],"threadId":"\#(thread)"}}"#),
            .event(.toolUsed),
            .event(.approvalRequested(id: "0", .command("/bin/cat brief.md")))
        ])
        #expect(stream.answer("0", .allow) == [line(#"{"id":0,"result":{"decision":"accept"}}"#)])
        #expect(stream.answer("0", .allow) == [])

        #expect(feed(segments[1], inChunksOf: chunkSize, to: &stream) == [
            .event(.toolUsed),
            .event(.toolUsed),
            .event(.approvalRequested(id: "1", .command("mkdir output/made-by-probe")))
        ])
        #expect(stream.answer("1", .allow) == [line(#"{"id":1,"result":{"decision":"accept"}}"#)])

        #expect(feed(segments[2], inChunksOf: chunkSize, to: &stream) == [
            .event(.toolUsed),
            .event(.toolUsed),
            .event(.approvalRequested(id: "2", .changes([.write(path: "\(runFolder)/output/made-by-probe/hello.txt")])))
        ])
        #expect(stream.answer("2", .allow) == [line(#"{"id":2,"result":{"decision":"accept"}}"#)])

        #expect(feed(segments[3], inChunksOf: chunkSize, to: &stream) == [
            .event(.toolUsed),
            .event(.toolUsed),
            .event(.approvalRequested(id: "3", .command("cd output")))
        ])
        #expect(stream.answer("3", .deny("Buddy keeps commands in the run folder; use paths instead of `cd`.")) == [
            line(
                #"{"id":5,"method":"turn/steer","params":{"expectedTurnId":"\#(turn)","input":[{"text":"Buddy declined `cd output`. "#
                    + #"Buddy keeps commands in the run folder; use paths instead of `cd`.","type":"text"}],"threadId":"\#(thread)"}}"#
            ),
            line(#"{"id":3,"result":{"decision":"decline"}}"#)
        ])

        #expect(feed(segments[4], inChunksOf: chunkSize, to: &stream) == [
            .event(.toolUsed),
            .event(.finished(report: "Created `\(runFolder)/output/made-by-probe/hello.txt` containing `hi` using apply_patch.\n\n"
                + "Updated the run note. Buddy declined `cd output`; I did not retry it.")),
            .closeInput
        ])
        #expect(stream.ended(stderr: "") == [])
    }

    @Test func briefNamesEachScreenSavedInTheRunFolderAfterItsLabel() {
        var stream = CodexRunStream()
        let screens = [
            ScreenCapture(jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1512, height: 982), pixelWidth: 1280, pixelHeight: 827, containsCursor: true),
            ScreenCapture(jpeg: Data([2]), display: DisplayRect(x: 1512, y: 0, width: 1920, height: 1080), pixelWidth: 1280, pixelHeight: 720, containsCursor: false)
        ]
        _ = stream.start(RunBrief(request: "List my open apps.", captures: screens), folder: runFolder)
        _ = received(#"{"id":1,"result":{}}"#, by: &stream)
        _ = received(#"{"id":2,"result":{"account":{"type":"chatgpt"}}}"#, by: &stream)
        #expect(received(ready(), by: &stream) == [
            .event(.started(folder: runFolder)),
            line(
                #"{"id":4,"method":"turn/start","params":{"input":["#
                    + #"{"text":"Screen 1 of 2, 1280x827 pixels, with the cursor:","type":"text"},"#
                    + #"{"path":"\#(runFolder)/screen-1.jpg","type":"localImage"},"#
                    + #"{"text":"Screen 2 of 2, 1280x720 pixels:","type":"text"},"#
                    + #"{"path":"\#(runFolder)/screen-2.jpg","type":"localImage"},"#
                    + #"{"text":"Your run folder is \#(runFolder).\n\nThe owner asked: List my open apps.","type":"text"}],"#
                    + #""threadId":"\#(thread)"}}"#
            )
        ])
    }

    @Test(arguments: [
        (#""never""#, "user"),
        (#""on-request""#, "user"),
        (#"{"granular":{"sandbox_approval":true,"rules":true,"skill_approval":false,"request_permissions":false,"mcp_elicitations":true}}"#, "user"),
        (#""untrusted""#, "auto_review")
    ])
    func threadThatWouldNotAskBuddyFailsTheRunBeforeTheBrief(policy: String, reviewer: String) {
        var stream = CodexRunStream()
        _ = stream.start(RunBrief(request: "List my open apps.", captures: []), folder: runFolder)
        _ = received(#"{"id":1,"result":{}}"#, by: &stream)
        _ = received(#"{"id":2,"result":{"account":{"type":"chatgpt"}}}"#, by: &stream)
        #expect(received(ready(policy: policy, reviewer: reviewer), by: &stream) == [
            .event(.failed(.error("it wouldn't ask Buddy before each command"))),
            .closeInput
        ])
        #expect(received(commandApproval("/bin/zsh -lc ls"), by: &stream) == [])
        #expect(stream.ended(stderr: "") == [])
    }

    @Test(arguments: [#"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#, #"{"id":2,"result":{"account":{"type":"apiKey"}}}"#])
    func codexWithoutAChatGPTSignInFailsTheRun(account: String) {
        var stream = CodexRunStream()
        _ = stream.start(RunBrief(request: "List my open apps.", captures: []), folder: runFolder)
        _ = received(#"{"id":1,"result":{}}"#, by: &stream)
        #expect(received(account, by: &stream) == [.event(.failed(.signedOut)), .closeInput])
    }

    @Test func aFailedSetupRequestFailsTheRunWithItsFirstLine() {
        var stream = CodexRunStream()
        _ = stream.start(RunBrief(request: "List my open apps.", captures: []), folder: runFolder)
        _ = received(#"{"id":1,"result":{}}"#, by: &stream)
        _ = received(#"{"id":2,"result":{"account":{"type":"chatgpt"}}}"#, by: &stream)
        #expect(received(#"{"id":3,"error":{"code":-32603,"message":"MCP server buddy failed to start\ncaused by: connection refused"}}"#, by: &stream) == [
            .event(.failed(.error("MCP server buddy failed to start"))),
            .closeInput
        ])
    }

    @Test(arguments: [
        ("/bin/zsh -lc ls", runFolder, ApprovalRequest.command("ls")),
        ("/bin/zsh -lc 'mkdir output'", runFolder, .command("mkdir output")),
        (
            #"/bin/zsh -lc "/usr/bin/osascript -e 'tell application \"System Events\" to get name of first process whose frontmost is true' ""#,
            runFolder,
            .command(#"/usr/bin/osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' "#)
        ),
        (#"/bin/bash -c 'echo \$HOME'"#, runFolder, .command(#"echo \$HOME"#)),
        ("/bin/zsh -lc 'rm notes.txt'", "/Users/owner/Desktop", .command("cd '/Users/owner/Desktop' && rm notes.txt")),
        ("/bin/zsh -lc ls", "/Users/owner/it's here", .command(#"cd '/Users/owner/it'\''s here' && ls"#)),
        ("/bin/zsh -lc ls > /tmp/out", runFolder, .command("/bin/zsh -lc ls > /tmp/out")),
        ("/bin/zsh -lc ls -la", runFolder, .command("/bin/zsh -lc ls -la")),
        ("/usr/bin/python3 -c 'print(1)'", runFolder, .command("/usr/bin/python3 -c 'print(1)'"))
    ] as [(String, String, ApprovalRequest)])
    func commandApprovalNamesTheScriptTheShellWouldRun(command: String, cwd: String, request: ApprovalRequest) {
        var stream = working()
        #expect(received(commandApproval(command, cwd: cwd), by: &stream) == [.event(.approvalRequested(id: "0", request))])
    }

    @Test func inputForARunningCommandIsATerminalInputRequest() {
        var stream = working()
        #expect(received(commandApproval("/bin/zsh -lc cat", kind: "writeStdin"), by: &stream) == [
            .event(.approvalRequested(id: "0", .other(tool: "terminal input")))
        ])
    }

    @Test func patchApprovalNamesEveryFileThePatchChanges() {
        var stream = working()
        let changes = #"[{"path":"\#(runFolder)/output/new.txt","kind":{"type":"add"},"diff":"hi\n"},"#
            + #"{"path":"\#(runFolder)/note.md","kind":{"type":"update","move_path":null},"diff":"@@"},"#
            + #"{"path":"/Users/owner/Desktop/old.txt","kind":{"type":"delete"},"diff":""},"#
            + #"{"path":"\#(runFolder)/scratch/a.txt","kind":{"type":"update","move_path":"/Users/owner/Desktop/a.txt"},"diff":""}]"#
        #expect(received(
            #"{"method":"item/started","params":{"item":{"type":"fileChange","id":"patch-1","changes":\#(changes),"status":"inProgress"},"threadId":"\#(thread)","turnId":"\#(turn)"}}"#,
            by: &stream
        ) == [.event(.toolUsed)])
        #expect(received(
            #"{"method":"item/fileChange/requestApproval","id":7,"params":{"threadId":"\#(thread)","turnId":"\#(turn)","itemId":"patch-1","reason":null,"grantRoot":null}}"#,
            by: &stream
        ) == [.event(.approvalRequested(id: "7", .changes([
            .write(path: "\(runFolder)/output/new.txt"),
            .edit(path: "\(runFolder)/note.md"),
            .delete(path: "/Users/owner/Desktop/old.txt"),
            .delete(path: "\(runFolder)/scratch/a.txt"),
            .write(path: "/Users/owner/Desktop/a.txt")
        ])))])
    }

    @Test func patchApprovalForAPatchCodexNeverShowedIsAnApplyPatchRequest() {
        var stream = working()
        #expect(received(
            #"{"method":"item/fileChange/requestApproval","id":7,"params":{"threadId":"\#(thread)","turnId":"\#(turn)","itemId":"patch-9"}}"#,
            by: &stream
        ) == [.event(.approvalRequested(id: "7", .other(tool: "apply_patch")))])
    }

    @Test(arguments: [
        #"{"id":4,"method":"item/tool/requestUserInput","params":{"threadId":"\#(thread)","turnId":"\#(turn)","itemId":"i","questions":[]}}"#,
        #"{"id":4,"method":"mcpServer/elicitation/request","params":{"threadId":"\#(thread)","serverName":"buddy","mode":"url","message":"m","url":"https://example.com","elicitationId":"e"}}"#,
        #"{"id":4,"method":"item/permissions/requestApproval","params":{"threadId":"\#(thread)","turnId":"\#(turn)","itemId":"i"}}"#,
        #"{"id":4,"method":"item/commandExecution/requestApproval","params":{"threadId":"another-thread","turnId":"t","itemId":"i","command":"ls"}}"#
    ])
    func otherServerRequestsAreRefusedAtOnce(request: String) {
        var stream = working()
        #expect(received(request, by: &stream) == [
            line(#"{"error":{"code":-32601,"message":"Buddy doesn't handle this request."},"id":4}"#)
        ])
    }

    @Test(arguments: [
        (#""status":"failed","error":{"message":"unauthorized","codexErrorInfo":"unauthorized"}"#, ProviderFailure.signedOut),
        (#""status":"failed","error":{"message":"You've hit your usage limit.\nTry again later.","codexErrorInfo":{"usageLimitExceeded":{}}}"#, .error("You've hit your usage limit.")),
        (#""status":"failed","error":null"#, .error("it returned an error")),
        (#""status":"interrupted","error":null"#, .error("it was interrupted"))
    ] as [(String, ProviderFailure)])
    func turnThatDoesNotCompleteFailsTheRunAndDropsWaitingApprovals(ending: String, failure: ProviderFailure) {
        var stream = working()
        _ = received(commandApproval("/bin/zsh -lc ls"), by: &stream)
        #expect(received(#"{"method":"turn/completed","params":{"threadId":"\#(thread)","turn":{"id":"\#(turn)",\#(ending)}}}"#, by: &stream) == [
            .event(.failed(failure)),
            .closeInput
        ])
        #expect(stream.answer("0", .allow) == [])
        #expect(stream.ended(stderr: "error: gone") == [])
    }

    @Test func processEndingBeforeTheTurnCompletesFailsTheRunWithTheLastErrorLine() {
        var stream = working()
        #expect(stream.ended(stderr: "warning: retrying\n\u{1B}[31merror: stream disconnected\u{1B}[0m\n") == [
            .event(.failed(.error("error: stream disconnected")))
        ])
        #expect(stream.ended(stderr: "") == [])

        var silent = CodexRunStream()
        #expect(silent.ended(stderr: "") == [.event(.failed(.error("it quit unexpectedly")))])
    }

    @Test func eventsOfAnotherThreadAreIgnored() {
        var stream = working()
        let other = "another-thread"
        #expect(received(#"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"e"},"threadId":"\#(other)","turnId":"t"}}"#, by: &stream) == [])
        #expect(received(#"{"method":"turn/completed","params":{"threadId":"\#(other)","turn":{"id":"t","status":"completed","error":null}}}"#, by: &stream) == [])
    }
}
