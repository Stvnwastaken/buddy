import Foundation
import Testing
import BuddyCore

let codexWeeklyUsage = ProviderUsage(
    fiveHour: nil,
    sevenDay: UsageWindow(utilization: 0.13, resetsAt: Date(timeIntervalSince1970: 1_793_800_846))
)
let codexWeeklyUsageAfterATurn = ProviderUsage(
    fiveHour: nil,
    sevenDay: UsageWindow(utilization: 0.14, resetsAt: Date(timeIntervalSince1970: 1_793_800_846))
)

let codexSearchUsage = ProviderUsage(
    fiveHour: nil,
    sevenDay: UsageWindow(utilization: 0.27, resetsAt: Date(timeIntervalSince1970: 1_793_800_846))
)

let saveDialog = ScreenCapture(
    jpeg: Data([7, 8, 9]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)
let keepChangesQuestion = TurnRequest(transcript: "What do I click to keep my changes?", captures: [saveDialog])
let recordedCodexTalkTurn: [ProviderEvent] = [
    "[", "POINT", ":", "860", ",", "515", ":", "Save", "]", " Click", " Save", " to", " keep", " your", " changes", "."
].map(ProviderEvent.textDelta) + [.usage(codexWeeklyUsageAfterATurn), .completed]

private let screenshotFolder = "/tmp/buddy-screens"
private let firstScreenshot = "/tmp/buddy-screens/turn-1-screen-1.jpg"
private let fixtureThread = "00000000-0000-4000-8000-000000000003"

private func line(_ json: String) -> CodexStream.Output {
    .write(Data((json + "\n").utf8))
}

private func received(_ json: String...) -> Data {
    Data(json.map { $0 + "\n" }.joined().utf8)
}

private func asked(_ text: String) -> TurnRequest {
    TurnRequest(transcript: text, captures: [])
}

private func jsonString(_ text: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return String(decoding: try encoder.encode(text), as: UTF8.self)
}

private let preparing: [CodexStream.Output] = [
    line(#"{"method":"initialized"}"#),
    line(#"{"id":2,"method":"account/read","params":{}}"#),
    line(#"{"id":3,"method":"account/rateLimits/read"}"#),
    line(#"{"id":4,"method":"config/read","params":{}}"#),
    line(#"{"id":5,"method":"model/list","params":{}}"#)
]

private func threadStart(_ id: Int = 6, model: String = "gpt-6.1-sol", instructions: String = TalkInstructions.system) throws -> CodexStream.Output {
    line(
        #"{"id":\#(id),"method":"thread/start","params":{"approvalPolicy":"never","baseInstructions":"#
        + (try jsonString(instructions))
        + #","config":{"mcp_servers.browser.enabled":false,"mcp_servers.notes.enabled":false},"#
        + #""ephemeral":true,"model":"\#(model)","sandbox":"read-only"}}"#
    )
}

private let emptyProfileInput = #"{"text":"Your owner's profile is empty. They haven't asked you to remember anything about them.","type":"text"},{"text":"The dock has no agent runs.","type":"text"},"#

private func turnStart(
    _ id: Int, _ input: String, profile: String = emptyProfileInput, thread: String = fixtureThread
) -> CodexStream.Output {
    line(#"{"id":\#(id),"method":"turn/start","params":{"input":[\#(profile)\#(input)],"threadId":"\#(thread)"}}"#)
}

private func unsubscribe(_ id: Int, from thread: String = fixtureThread) -> CodexStream.Output {
    line(#"{"id":\#(id),"method":"thread/unsubscribe","params":{"threadId":"\#(thread)"}}"#)
}

private func threadStarted(_ id: Int, _ thread: String) -> Data {
    received(#"{"id":\#(id),"result":{"thread":{"id":"\#(thread)"}}}"#)
}

private let keepChangesInput = #"{"text":"Screen 1 of 1, 1280x800 pixels, with the cursor:","type":"text"},"#
    + #"{"path":"/tmp/buddy-screens/turn-1-screen-1.jpg","type":"localImage"},"#
    + #"{"text":"What do I click to keep my changes?","type":"text"}"#

private func readyStream() throws -> CodexStream {
    var stream = CodexStream(imageFolder: screenshotFolder)
    _ = stream.start()
    _ = stream.received(try fixture("codex-startup"))
    return stream
}

private func splitAtCancel(_ recording: Data) throws -> (before: Data, after: Data) {
    let marker = try #require(recording.firstRange(of: Data("\n\n".utf8)))
    return (recording[..<marker.lowerBound] + Data("\n".utf8), recording[marker.upperBound...])
}

struct CodexStreamTests {
    @Test(arguments: ["null", "{}", #"{"config":[]}"#])
    func unreadableConfigurationFailsBeforeAThreadCanEnableAnyTools(result: String) {
        var stream = CodexStream(imageFolder: screenshotFolder)
        _ = stream.start()
        _ = stream.send(keepChangesQuestion)
        _ = stream.received(received(#"{"id":1,"result":{}}"#))
        #expect(stream.received(received(#"{"id":4,"result":\#(result)}"#)) == [
            .event(.failed(.error("it returned an unreadable configuration"))), .endProcess
        ])
    }

    @Test(arguments: ["null", "{}", #"{"turn":{"id":42}}"#])
    func missingTurnIDFailsAndDeletesScreenshotsBeforeRetiringTheProcess(result: String) throws {
        var stream = try readyStream()
        _ = stream.send(keepChangesQuestion)
        #expect(stream.received(received(#"{"id":7,"result":\#(result)}"#)) == [
            .event(.failed(.error("it started no turn"))), .deleteFiles([firstScreenshot]), .endProcess
        ])
    }

    @Test func aUtilityThreadUsesItsOwnInstructionsAndTheFirstPreferredModelOffered() throws {
        let utility = CodexThread(instructions: UtilityInstructions.system, preferredModels: ["gpt-7-mini", "gpt-6-luna"])
        var stream = CodexStream(imageFolder: screenshotFolder, thread: utility)
        _ = stream.start()
        #expect(stream.received(try fixture("codex-startup")) == preparing + [
            try threadStart(model: "gpt-6-luna", instructions: UtilityInstructions.system), .event(.usage(codexWeeklyUsage))
        ])
        var unoffered = CodexStream(imageFolder: screenshotFolder, thread: CodexThread(instructions: UtilityInstructions.system, preferredModels: ["gpt-7-mini"]))
        _ = unoffered.start()
        #expect(unoffered.received(try fixture("codex-startup")) == preparing + [
            try threadStart(instructions: UtilityInstructions.system), .event(.usage(codexWeeklyUsage))
        ])
    }

    @Test(arguments: [1, 7, 64, 100_000])
    func recordedStartupSignsInThenStartsAThreadWithoutTheOwnersToolsHoweverTheOutputIsSplit(chunkSize: Int) throws {
        var stream = CodexStream(imageFolder: screenshotFolder)
        #expect(stream.start() == [line(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"buddy","version":"1.0"}}}"#)])
        let recording = try fixture("codex-startup")
        var outputs: [CodexStream.Output] = []
        for start in stride(from: 0, to: recording.count, by: chunkSize) {
            outputs += stream.received(recording.subdata(in: start..<min(start + chunkSize, recording.count)))
        }
        #expect(outputs == preparing + [try threadStart(), .event(.usage(codexWeeklyUsage))])
    }

    @Test(arguments: [
        (#"[{"model":"gpt-6-luna","isDefault":false},{"model":"gpt-6.1-sol","isDefault":true}]"#, "gpt-6.1-sol"),
        (#"[{"model":"gpt-6-luna"},{"model":"gpt-6.1-sol"}]"#, "gpt-6-luna")
    ])
    func threadUsesTheModelCodexMarksAsDefaultOrElseItsFirst(models: String, expected: String) throws {
        var stream = CodexStream(imageFolder: screenshotFolder)
        _ = stream.start()
        let recording = String(decoding: try fixture("codex-startup"), as: UTF8.self).split(separator: "\n").map { line in
            line.hasPrefix(#"{"id":5,"#) ? #"{"id":5,"result":{"data":\#(models)}}"# : String(line)
        }
        #expect(stream.received(Data((recording.joined(separator: "\n") + "\n").utf8)).contains(try threadStart(model: expected)))
    }

    @Test func recordedTalkTurnStreamsTheReplyThenDeletesItsScreenshot() throws {
        var stream = try readyStream()
        #expect(stream.send(keepChangesQuestion) == [
            .saveFile(path: firstScreenshot, contents: Data([7, 8, 9])),
            turnStart(7, keepChangesInput)
        ])
        #expect(stream.received(try fixture("codex-talk-turn")) == recordedCodexTalkTurn.map { .event($0) } + [
            .deleteFiles([firstScreenshot])
        ])
        #expect(stream.cancel() == [])
    }

    @Test func recordedSearchTurnReportsTheSearchThenStreamsTheAnswer() throws {
        var stream = try readyStream()
        _ = stream.send(asked("What's the top news story today?"))
        let answer = [
            "A", " leading", " story", " today", " is", " the", " final", " push", " before", " Tuesday", "’s", " U", ".S",
            ".", " mid", "term", " elections", ",", " with", " control", " of", " Congress", " at", " stake", ".\n", "The",
            " Associated", " Press", " reports", " Trump", " is", " rally", "ing", " in", " Iowa", " and", " Kansas", " as",
            " Republicans", " fight", " to", " hold", " both", " chambers", "."
        ].map(ProviderEvent.textDelta)
        let events: [ProviderEvent] = [.searching, .usage(codexSearchUsage)] + answer + [.usage(codexSearchUsage), .completed]
        #expect(stream.received(try fixture("codex-search-turn")) == events.map { .event($0) })
    }

    @Test func searchInACancelledTurnIsNotReported() throws {
        var stream = try readyStream()
        _ = stream.send(asked("What's the top news story today?"))
        let recording = try fixture("codex-search-turn")
        let accepted = try #require(recording.firstRange(of: Data("\n".utf8)))
        _ = stream.received(recording[..<accepted.upperBound])
        #expect(stream.cancel() == [line(
            #"{"id":8,"method":"turn/interrupt","params":{"threadId":"\#(fixtureThread)","turnId":"00000000-0000-4000-8000-000000000004"}}"#
        )])
        #expect(stream.received(recording[accepted.upperBound...]) == [.event(.usage(codexSearchUsage)), .event(.usage(codexSearchUsage))])
    }

    @Test func turnAskedDuringStartupWaitsForTheThread() throws {
        var stream = CodexStream(imageFolder: screenshotFolder)
        _ = stream.start()
        #expect(stream.send(keepChangesQuestion) == [])
        #expect(stream.received(try fixture("codex-startup")) == preparing + [
            try threadStart(),
            .event(.usage(codexWeeklyUsage)),
            .saveFile(path: firstScreenshot, contents: Data([7, 8, 9])),
            turnStart(7, keepChangesInput)
        ])
    }

    @Test func cancelledTurnIsInterruptedAndTheNextTurnWaitsForItToEnd() throws {
        let (before, after) = try splitAtCancel(fixture("codex-interrupted-turn"))
        var stream = try readyStream()
        _ = stream.send(keepChangesQuestion)
        _ = stream.received(try fixture("codex-talk-turn"))
        #expect(stream.send(asked("Explain in detail, in at least twelve sentences, how a lighthouse lens works.")) == [
            turnStart(8, #"{"text":"Explain in detail, in at least twelve sentences, how a lighthouse lens works.","type":"text"}"#)
        ])
        #expect(stream.received(before) == ["A", " lighthouse", " lens", " gathers"].map { .event(.textDelta($0)) })
        #expect(stream.cancel() == [
            line(#"{"id":9,"method":"turn/interrupt","params":{"threadId":"\#(fixtureThread)","turnId":"00000000-0000-4000-8000-000000000006"}}"#)
        ])
        #expect(stream.cancel() == [])
        #expect(stream.send(asked("Just say the word two.")) == [])
        #expect(stream.received(after) == [
            .event(.usage(codexWeeklyUsageAfterATurn)),
            turnStart(10, #"{"text":"Just say the word two.","type":"text"}"#),
            .event(.textDelta("two")),
            .event(.usage(codexWeeklyUsageAfterATurn)),
            .event(.completed)
        ])
        #expect(stream.cancel() == [])
    }

    @Test func turnCancelledBeforeCodexAcceptsItIsInterruptedOnceItIs() throws {
        var stream = try readyStream()
        _ = stream.send(keepChangesQuestion)
        #expect(stream.cancel() == [])
        #expect(stream.received(received(
            #"{"id":7,"result":{"turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"\#(fixtureThread)","turnId":"turn-1","itemId":"msg-1","delta":"Click"}}"#
        )) == [line(#"{"id":8,"method":"turn/interrupt","params":{"threadId":"\#(fixtureThread)","turnId":"turn-1"}}"#)])
        #expect(stream.received(received(
            #"{"method":"turn/completed","params":{"threadId":"\#(fixtureThread)","turn":{"id":"turn-1","items":[],"status":"interrupted","error":null}}}"#
        )) == [.deleteFiles([firstScreenshot])])
    }

    @Test func newConversationStartsAFreshThreadOnTheSameProcessAndLetsGoOfTheOldOne() throws {
        var stream = try readyStream()
        _ = stream.send(keepChangesQuestion)
        _ = stream.received(try fixture("codex-talk-turn"))
        #expect(stream.endConversation() == [try threadStart(8), unsubscribe(9)])
        #expect(stream.send(asked("and the sound menu")) == [])
        #expect(stream.received(threadStarted(8, "thread-2")) == [
            turnStart(10, #"{"text":"and the sound menu","type":"text"}"#, thread: "thread-2")
        ])
    }

    @Test func onlyEachThreadsFirstTurnCarriesTheRecentTurnsButEveryTurnCarriesTheProfileAndDate() throws {
        let question = TurnRequest(transcript: "Which gear?", captures: [], recentTurns: [
            TurnRecord(transcript: "Where are settings?", reply: "Click the gear.")
        ], profile: Profile(notes: ["Goes by Sam."]), today: "Sunday, November 1, 2026")
        let today = #"{"text":"Today is Sunday, November 1, 2026.","type":"text"},"#
        let sam = #"{"text":"Your owner's profile, the notes they asked you to remember about them:\n- Goes by Sam.","type":"text"},"#
            + #"{"text":"The dock has no agent runs.","type":"text"},"#
        let primed = #"{"text":"Recent exchanges in this conversation (text only):\nOwner: Where are settings?\nBuddy: Click the gear.","type":"text"},"#
            + today + #"{"text":"Which gear?","type":"text"}"#
        var stream = try readyStream()
        #expect(stream.send(question) == [turnStart(7, primed, profile: sam)])
        #expect(stream.received(received(
            #"{"id":7,"result":{"turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"\#(fixtureThread)","turn":{"id":"turn-1","items":[],"status":"completed","error":null}}}"#
        )) == [.event(.completed)])
        #expect(stream.send(question) == [turnStart(8, today + #"{"text":"Which gear?","type":"text"}"#, profile: sam)])
        #expect(stream.received(received(
            #"{"id":8,"result":{"turn":{"id":"turn-2","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"\#(fixtureThread)","turn":{"id":"turn-2","items":[],"status":"completed","error":null}}}"#
        )) == [.event(.completed)])
        #expect(stream.endConversation() == [try threadStart(9), unsubscribe(10)])
        #expect(stream.send(question) == [])
        #expect(stream.received(threadStarted(9, "thread-2")) == [turnStart(11, primed, profile: sam, thread: "thread-2")])
    }

    @Test func summariesPrimeOnlyEachThreadsFirstTurn() throws {
        let question = TurnRequest(
            transcript: "What is my kite called?", captures: [],
            earlierSummaries: ["The owner's kite is Copper Finch."], summary: "The owner asked about settings."
        )
        let primed = #"{"text":"Summaries of earlier conversations, oldest first:\n- The owner's kite is Copper Finch.","type":"text"},"#
            + #"{"text":"Summary of this conversation so far:\nThe owner asked about settings.","type":"text"},"#
            + #"{"text":"What is my kite called?","type":"text"}"#
        var stream = try readyStream()
        #expect(stream.send(question) == [turnStart(7, primed)])
        #expect(stream.received(received(
            #"{"id":7,"result":{"turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"\#(fixtureThread)","turn":{"id":"turn-1","items":[],"status":"completed","error":null}}}"#
        )) == [.event(.completed)])
        #expect(stream.send(question) == [turnStart(8, #"{"text":"What is my kite called?","type":"text"}"#)])
    }

    @Test func newConversationDuringACancelledTurnLetsGoOfTheOldThreadOnceThatTurnEnds() throws {
        var stream = try readyStream()
        _ = stream.send(keepChangesQuestion)
        _ = stream.received(received(#"{"id":7,"result":{"turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}}"#))
        #expect(stream.endConversation() == [
            line(#"{"id":8,"method":"turn/interrupt","params":{"threadId":"\#(fixtureThread)","turnId":"turn-1"}}"#),
            try threadStart(9)
        ])
        #expect(stream.send(asked("and the sound menu")) == [])
        #expect(stream.received(threadStarted(9, "thread-2")) == [])
        #expect(stream.received(received(
            #"{"method":"item/agentMessage/delta","params":{"threadId":"\#(fixtureThread)","turnId":"turn-1","itemId":"msg-1","delta":"Click"}}"#,
            #"{"method":"turn/completed","params":{"threadId":"\#(fixtureThread)","turn":{"id":"turn-1","items":[],"status":"interrupted","error":null}}}"#
        )) == [
            .deleteFiles([firstScreenshot]),
            unsubscribe(10),
            turnStart(11, #"{"text":"and the sound menu","type":"text"}"#, thread: "thread-2")
        ])
    }

    @Test func newConversationBeforeTheFirstThreadStartsKeepsThatThread() throws {
        var stream = CodexStream(imageFolder: screenshotFolder)
        _ = stream.start()
        #expect(stream.endConversation() == [])
        _ = stream.send(keepChangesQuestion)
        #expect(stream.received(try fixture("codex-startup")).last == turnStart(7, keepChangesInput))
    }

    @Test func eachAgentMessageInATurnStartsOnItsOwnLine() throws {
        var stream = try readyStream()
        _ = stream.send(asked("what time is it?"))
        #expect(stream.received(received(
            #"{"id":7,"result":{"turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"\#(fixtureThread)","turnId":"turn-1","itemId":"msg-1","delta":"Let me check."}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"\#(fixtureThread)","turnId":"turn-1","itemId":"msg-2","delta":"[POINT:1180,12:clock] "}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"\#(fixtureThread)","turnId":"turn-1","itemId":"msg-2","delta":"It's 10:42."}}"#
        )) == [
            .event(.textDelta("Let me check.")),
            .event(.textDelta("\n")),
            .event(.textDelta("[POINT:1180,12:clock] ")),
            .event(.textDelta("It's 10:42."))
        ])
    }

    @Test(arguments: [
        ("failed", #"{"message":"Internal server error.\nTry again.","codexErrorInfo":"internalServerError"}"#,
         [CodexStream.Output.event(.failed(.error("Internal server error.")))]),
        ("failed", #"{"message":"You've hit your usage limit.","codexErrorInfo":"usageLimitExceeded"}"#,
         [.event(.failed(.limitReached))]),
        ("failed", #"{"message":"401 Unauthorized","codexErrorInfo":"unauthorized"}"#,
         [.event(.failed(.signedOut)), .endProcess]),
        ("failed", "null", [.event(.failed(.error("it returned an error")))]),
        ("interrupted", "null", [.event(.failed(.error("it was interrupted")))])
    ])
    func turnThatEndsUnfinishedReportsWhyAndDeletesItsScreenshot(status: String, error: String, expected: [CodexStream.Output]) throws {
        var stream = try readyStream()
        _ = stream.send(keepChangesQuestion)
        let outputs = stream.received(received(
            #"{"id":7,"result":{"turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"\#(fixtureThread)","turn":{"id":"turn-1","items":[],"status":"\#(status)","error":\#(error)}}}"#
        ))
        #expect(outputs == [expected[0], .deleteFiles([firstScreenshot])] + expected.dropFirst())
    }

    @Test(arguments: [
        #"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#,
        #"{"id":2,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}"#
    ])
    func accountNotSignedInWithChatGPTFailsTheTurnAndEndsTheProcess(account: String) throws {
        let startup = String(decoding: try fixture("codex-startup"), as: UTF8.self).split(separator: "\n").map(String.init)
        let throughAccount = try #require(startup.firstIndex { $0.hasPrefix(#"{"id":2,"#) })
        let replayed = Data((startup[..<throughAccount] + [account]).map { $0 + "\n" }.joined().utf8)

        var asking = CodexStream(imageFolder: screenshotFolder)
        _ = asking.start()
        _ = asking.send(keepChangesQuestion)
        #expect(asking.received(replayed) == preparing + [.event(.failed(.signedOut)), .endProcess])

        var warming = CodexStream(imageFolder: screenshotFolder)
        _ = warming.start()
        #expect(warming.received(replayed) == preparing + [.endProcess])
    }

    @Test func startupRequestThatFailsFailsTheWaitingTurnAndEndsTheProcess() throws {
        var stream = CodexStream(imageFolder: screenshotFolder)
        _ = stream.start()
        _ = stream.received(received(#"{"id":1,"result":{"userAgent":"buddy/0.166.0","codexHome":"/Users/owner/.codex"}}"#))
        _ = stream.send(asked("help"))
        #expect(stream.received(received(
            #"{"id":4,"error":{"code":-32600,"message":"invalid config: unknown field `featurs`\nat line 3"}}"#
        )) == [.event(.failed(.error("invalid config: unknown field `featurs`"))), .endProcess])
    }

    @Test func everyRequestFromCodexIsRefused() throws {
        var stream = try readyStream()
        #expect(stream.received(received(
            #"{"id":0,"method":"item/tool/requestUserInput","params":{"threadId":"\#(fixtureThread)","turnId":"turn-1","itemId":"call-1","questions":[]}}"#,
            #"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"\#(fixtureThread)","turnId":"turn-1","itemId":"call-2"}}"#
        )) == [
            line(#"{"error":{"code":-32601,"message":"Buddy answers no requests during talk."},"id":0}"#),
            line(#"{"error":{"code":-32601,"message":"Buddy answers no requests during talk."},"id":"approval-1"}"#)
        ])
    }

    @Test(arguments: [
        (#"{"primary":{"usedPercent":61,"windowDurationMins":300,"resetsAt":1793520000},"secondary":{"usedPercent":22,"windowDurationMins":10080,"resetsAt":1793800846}}"#,
         [CodexStream.Output.event(.usage(ProviderUsage(
            fiveHour: UsageWindow(utilization: 0.61, resetsAt: Date(timeIntervalSince1970: 1_793_520_000)),
            sevenDay: UsageWindow(utilization: 0.22, resetsAt: Date(timeIntervalSince1970: 1_793_800_846))
         )))]),
        (#"{"primary":{"usedPercent":40,"windowDurationMins":60,"resetsAt":1793520000},"secondary":null}"#, []),
        (#"{"primary":null,"secondary":null}"#, [])
    ])
    func usageUpdateCountsOnlyItsFiveHourAndSevenDayWindows(rateLimits: String, expected: [CodexStream.Output]) throws {
        var stream = try readyStream()
        #expect(stream.received(received(
            #"{"method":"account/rateLimits/updated","params":{"rateLimits":\#(rateLimits)}}"#
        )) == expected)
    }

    @Test func processEndingMidTurnFailsItWithTheLastErrorLineAndDeletesItsScreenshot() throws {
        var stream = try readyStream()
        _ = stream.send(keepChangesQuestion)
        #expect(stream.ended(stderr: "\u{1B}[2m2026-11-01T07:00:33Z\u{1B}[0m \u{1B}[31mERROR\u{1B}[0m codex: stream disconnected\n") == [
            .event(.failed(.error("2026-11-01T07:00:33Z ERROR codex: stream disconnected"))),
            .deleteFiles([firstScreenshot])
        ])
        #expect(stream.ended(stderr: "") == [])
        #expect(stream.cancel() == [])
    }

    @Test func processEndingWhileATurnWaitsFailsThatTurn() {
        var stream = CodexStream(imageFolder: screenshotFolder)
        _ = stream.start()
        _ = stream.send(asked("say two"))
        #expect(stream.ended(stderr: "") == [.event(.failed(.error("it quit unexpectedly")))])
    }
}
