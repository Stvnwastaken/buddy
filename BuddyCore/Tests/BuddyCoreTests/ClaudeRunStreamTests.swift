import Foundation
import Testing
import BuddyCore

let runFolder = "/Users/owner/Library/Application Support/Buddy/Runs/2026-11-01-070412-1"

private func line(_ json: String) -> ClaudeRunStream.Output {
    .write(Data((json + "\n").utf8))
}

private func received(_ json: String, by stream: inout ClaudeRunStream) -> [ClaudeRunStream.Output] {
    stream.received(Data((json + "\n").utf8))
}

private func splitAtAnswer(_ recording: Data) throws -> (before: Data, after: Data) {
    let marker = try #require(recording.firstRange(of: Data("\n\n".utf8)))
    return (recording[..<marker.lowerBound] + Data("\n".utf8), recording[marker.upperBound...])
}

private func feed(_ data: Data, inChunksOf size: Int, to stream: inout ClaudeRunStream) -> [ClaudeRunStream.Output] {
    stride(from: data.startIndex, to: data.endIndex, by: size).flatMap { start in
        stream.received(data.subdata(in: start..<min(start + size, data.endIndex)))
    }
}

private func started() -> ClaudeRunStream.Output {
    .event(.started(folder: runFolder))
}

private func permissionPrompt(_ tool: String, _ input: String) -> String {
    #"{"type":"control_request","request_id":"prompt-1","request":{"subtype":"can_use_tool","tool_name":"\#(tool)","input":\#(input),"tool_use_id":"toolu_fixture1"}}"#
}

struct ClaudeRunStreamTests {
    @Test func usageLimitCarriesTheLastPartialReportInsteadOfFailingTheRun() {
        var stream = ClaudeRunStream()
        _ = stream.start(RunBrief(request: "List apps", captures: []), folder: runFolder)
        #expect(received(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Listed apps; still need to save them."}]}}"#, by: &stream) == [started()])
        #expect(received(#"{"type":"assistant","error":"rate_limit","message":{"content":[{"type":"text","text":"Limit reached."}]}}"#, by: &stream) == [])
        #expect(received(#"{"type":"result","is_error":true,"result":"Limit reached."}"#, by: &stream) == [
            .event(.limitReached(partialReport: "Listed apps; still need to save them.")), .closeInput
        ])
        #expect(stream.ended(stderr: "") == [])
    }

    @Test func aSuccessfulResultAfterALimitRefusalNeverRestartsCompletedWork() {
        var stream = ClaudeRunStream()
        _ = stream.start(RunBrief(request: "List apps", captures: []), folder: runFolder)
        _ = received(#"{"type":"assistant","error":"rate_limit"}"#, by: &stream)
        #expect(received(#"{"type":"result","is_error":false,"result":"Already completed."}"#, by: &stream) == [
            .event(.finished(report: "Already completed.")), .closeInput
        ])
    }

    @Test func aLimitFollowedByProcessExitStillHandsOffThePartialReport() {
        var stream = ClaudeRunStream()
        _ = stream.start(RunBrief(request: "List apps", captures: []), folder: runFolder)
        _ = received(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Listed apps."}]}}"#, by: &stream)
        _ = received(#"{"type":"assistant","error":"rate_limit"}"#, by: &stream)
        #expect(stream.ended(stderr: "Usage limit reached") == [.event(.limitReached(partialReport: "Listed apps."))])
        #expect(stream.ended(stderr: "") == [])
    }

    @Test func briefIsSentAsTheScreenshotsAfterTheirLabelsThenTheFolderAndRequest() {
        var stream = ClaudeRunStream()
        let brief = RunBrief(request: "Make a folder on my Desktop.", captures: [ScreenCapture(
            jpeg: Data([1, 2, 3]), display: DisplayRect(x: 0, y: 0, width: 1512, height: 982),
            pixelWidth: 1280, pixelHeight: 827, containsCursor: true
        )])
        #expect(stream.start(brief, folder: runFolder) == [line(
            #"{"message":{"content":[{"text":"Screen 1 of 1, 1280x827 pixels, with the cursor:","type":"text"},"#
            + #"{"source":{"data":"AQID","media_type":"image/jpeg","type":"base64"},"type":"image"},"#
            + #"{"text":"Your run folder is /Users/owner/Library/Application Support/Buddy/Runs/2026-11-01-070412-1.\n\n"#
            + #"The owner asked: Make a folder on my Desktop.","type":"text"}],"role":"user"},"type":"user"}"#
        )])
    }

    @Test(arguments: [1, 2, 7, 64, 100_000])
    func recordedDeniedCommandReplaysIntoRunEventsHoweverTheOutputIsSplit(chunkSize: Int) throws {
        let (before, after) = try splitAtAnswer(fixture("run-denied"))
        var stream = ClaudeRunStream()
        _ = stream.start(RunBrief(request: "Make a folder named made-by-probe in the run folder.", captures: []), folder: runFolder)
        #expect(feed(before, inChunksOf: chunkSize, to: &stream) == [
            started(),
            .event(.toolUsed),
            .event(.approvalRequested(
                id: "00000000-0000-4000-8000-000000000004",
                .command(#"mkdir "/Users/owner/Library/Application Support/Buddy/Runs/2026-11-01-070412-1/made-by-probe""#)
            ))
        ])
        #expect(stream.answer("00000000-0000-4000-8000-000000000004", .deny("Buddy doesn't allow this command.")) == [line(
            #"{"response":{"request_id":"00000000-0000-4000-8000-000000000004","#
            + #""response":{"behavior":"deny","message":"Buddy doesn't allow this command."},"subtype":"success"},"type":"control_response"}"#
        )])
        #expect(feed(after, inChunksOf: chunkSize, to: &stream) == [.event(.finished(report: "Denied.")), .closeInput])
        #expect(stream.ended(stderr: "") == [])
    }

    @Test(arguments: [1, 2, 7, 64, 100_000])
    func recordedRunNoteUpdateIsAllowedWithItsOwnInputHoweverTheOutputIsSplit(chunkSize: Int) throws {
        let (before, after) = try splitAtAnswer(fixture("run-note"))
        var stream = ClaudeRunStream()
        _ = stream.start(RunBrief(request: "Set the run note to hello.", captures: []), folder: runFolder)
        #expect(feed(before, inChunksOf: chunkSize, to: &stream) == [
            started(),
            .event(.toolUsed),
            .event(.approvalRequested(id: "00000000-0000-4000-8000-000000000004", .buddyTool("mcp__buddy__update_run_note")))
        ])
        #expect(stream.answer("00000000-0000-4000-8000-000000000004", .allow) == [line(
            #"{"response":{"request_id":"00000000-0000-4000-8000-000000000004","#
            + #""response":{"behavior":"allow","updatedInput":{"note":"hello"}},"subtype":"success"},"type":"control_response"}"#
        )])
        #expect(stream.answer("00000000-0000-4000-8000-000000000004", .allow) == [])
        #expect(feed(after, inChunksOf: chunkSize, to: &stream) == [.event(.finished(report: "Done.")), .closeInput])
    }

    @Test(arguments: [
        ("mcp__buddy__show_beats", #"{"lines":"Look here."}"#, ApprovalRequest.buddyTool("mcp__buddy__show_beats")),
        ("Read", #"{"file_path":"/Users/owner/Desktop/todo.txt"}"#, .read(path: "/Users/owner/Desktop/todo.txt")),
        ("Glob", #"{"pattern":"*.md"}"#, .read(path: ".")),
        ("Grep", #"{"pattern":"TODO","path":"/Users/owner/Documents"}"#, .read(path: "/Users/owner/Documents")),
        ("Write", #"{"file_path":"output/apps.txt","content":"Finder"}"#, .write(path: "output/apps.txt")),
        ("Edit", #"{"file_path":"note.md","old_string":"a","new_string":"b"}"#, .edit(path: "note.md")),
        ("MultiEdit", #"{"file_path":"scratch/a.txt","edits":[]}"#, .edit(path: "scratch/a.txt")),
        ("NotebookEdit", #"{"notebook_path":"scratch/a.ipynb","new_source":"1"}"#, .edit(path: "scratch/a.ipynb")),
        ("Bash", #"{"command":"osascript -e 'name of every application process'"}"#, .command("osascript -e 'name of every application process'")),
        ("Read", #"{"path":"note.md"}"#, .other(tool: "Read")),
        ("Bash", #"{"script":"ls"}"#, .other(tool: "Bash")),
        ("WebFetch", #"{"url":"https://example.com"}"#, .other(tool: "WebFetch"))
    ] as [(String, String, ApprovalRequest)])
    func permissionPromptNamesTheToolUseInBuddysTerms(tool: String, input: String, request: ApprovalRequest) {
        var stream = ClaudeRunStream()
        _ = stream.start(RunBrief(request: "List my open apps.", captures: []), folder: runFolder)
        #expect(received(permissionPrompt(tool, input), by: &stream) == [
            started(),
            .event(.approvalRequested(id: "prompt-1", request))
        ])
    }

    @Test func allowSendsBackTheToolInputUnchanged() {
        var stream = ClaudeRunStream()
        _ = received(permissionPrompt("Edit", #"{"file_path":"output/list.txt","old_string":"a\nb","new_string":"c/d","replace_all":true}"#), by: &stream)
        #expect(stream.answer("prompt-1", .allow) == [line(
            #"{"response":{"request_id":"prompt-1","response":{"behavior":"allow","updatedInput":"#
            + #"{"file_path":"output/list.txt","new_string":"c/d","old_string":"a\nb","replace_all":true}},"#
            + #""subtype":"success"},"type":"control_response"}"#
        )])
        #expect(stream.answer("prompt-2", .allow) == [])
    }

    @Test func otherControlRequestsAreRefusedAtOnce() {
        var stream = ClaudeRunStream()
        _ = stream.start(RunBrief(request: "List my open apps.", captures: []), folder: runFolder)
        #expect(received(#"{"type":"control_request","request_id":"hook-1","request":{"subtype":"hook_callback","callback_id":"1"}}"#, by: &stream) == [
            started(),
            line(#"{"response":{"error":"Buddy doesn't handle this request.","request_id":"hook-1","subtype":"error"},"type":"control_response"}"#)
        ])
    }

    @Test func toolUsesOfSubagentsAreNotSteps() {
        var stream = ClaudeRunStream()
        let assistant = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_fixture2","name":"Read","input":{}}]},"parent_tool_use_id":"#
        #expect(received(assistant + #""toolu_fixture1"}"#, by: &stream) == [])
        #expect(received(assistant + "null}", by: &stream) == [.event(.toolUsed)])
    }

    @Test func signedOutCLIFailsTheRun() throws {
        var stream = ClaudeRunStream()
        _ = stream.start(RunBrief(request: "List my open apps.", captures: []), folder: runFolder)
        #expect(stream.received(try fixture("signed-out")) == [started(), .event(.failed(.signedOut)), .closeInput])
    }

    @Test func errorResultFailsTheRunWithItsFirstLineAndDropsUnansweredPrompts() {
        var stream = ClaudeRunStream()
        _ = received(permissionPrompt("Bash", #"{"command":"ls"}"#), by: &stream)
        let result = #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 529 Overloaded\nTry again later."}"#
        #expect(received(result, by: &stream) == [.event(.failed(.error("API Error: 529 Overloaded"))), .closeInput])
        #expect(stream.answer("prompt-1", .allow) == [])
        #expect(received(permissionPrompt("Bash", #"{"command":"ls"}"#), by: &stream) == [])
    }

    @Test func processEndingBeforeItsResultFailsTheRunWithTheLastErrorLine() {
        var quitting = ClaudeRunStream()
        _ = quitting.start(RunBrief(request: "List my open apps.", captures: []), folder: runFolder)
        #expect(quitting.ended(stderr: "warning: retrying\nerror: socket hang up\n") == [.event(.failed(.error("error: socket hang up")))])
        #expect(quitting.ended(stderr: "") == [])

        var silent = ClaudeRunStream()
        #expect(silent.ended(stderr: "") == [.event(.failed(.error("it quit unexpectedly")))])
    }
}
