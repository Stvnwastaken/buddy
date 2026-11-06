import Foundation
import Testing
import BuddyCore

let recordedUsage = ProviderUsage(
    fiveHour: UsageWindow(utilization: 0.24, resetsAt: Date(timeIntervalSince1970: 1_793_509_200)),
    sevenDay: UsageWindow(utilization: 0.25, resetsAt: Date(timeIntervalSince1970: 1_793_667_600))
)

let recordedTalkTurn: [ProviderEvent] = [
    .usage(recordedUsage),
    .textDelta("It"),
    .textDelta("'s in the menu bar at"),
    .textDelta(" the top right of"),
    .textDelta(" your screen,"),
    .textDelta(" the little"),
    .textDelta(" fan-"),
    .textDelta("shaped Wi-"),
    .textDelta("Fi icon just"),
    .textDelta(" left"),
    .textDelta(" of the cl"),
    .textDelta("ock and next"),
    .textDelta(" to the play-"),
    .textDelta("button"),
    .textDelta(" icon. Click it to"),
    .textDelta(" see networ"),
    .textDelta("ks and switch between them."),
    .textDelta("\n\n[POINT:1104,"),
    .textDelta("12:Wi-F"),
    .textDelta("i ic"),
    .textDelta("on]"),
    .completed
]

let wifiQuestion = TurnRequest(transcript: "Where is the Wi-Fi menu?", captures: [ScreenCapture(
    jpeg: Data([1, 2, 3]), display: DisplayRect(x: 0, y: 0, width: 1512, height: 982),
    pixelWidth: 1280, pixelHeight: 827, containsCursor: true
)])

func fixtureURL(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
}

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

/// The usage reported during the recorded search turn, which only moved the 5-hour window.
private func searchUsage(_ fiveHour: Double) -> ProviderEvent {
    .usage(ProviderUsage(
        fiveHour: UsageWindow(utilization: fiveHour, resetsAt: Date(timeIntervalSince1970: 1_793_599_200)),
        sevenDay: UsageWindow(utilization: 0.51, resetsAt: Date(timeIntervalSince1970: 1_793_667_600))
    ))
}

private func line(_ json: String) -> ClaudeStream.Output {
    .write(Data((json + "\n").utf8))
}

private func asked(_ text: String) -> TurnRequest {
    TurnRequest(transcript: text, captures: [])
}

/// The recorded output split where Buddy cancelled the reply, which the recording marks with a blank line.
private func splitAtCancel(_ recording: Data) throws -> (before: Data, after: Data) {
    let marker = try #require(recording.firstRange(of: Data("\n\n".utf8)))
    return (recording[..<marker.lowerBound] + Data("\n".utf8), recording[marker.upperBound...])
}

struct ClaudeStreamTests {
    @Test(arguments: [1, 2, 7, 64, 100_000])
    func recordedTalkTurnReplaysIntoProviderEventsHoweverTheOutputIsSplit(chunkSize: Int) throws {
        var stream = ClaudeStream()
        #expect(stream.send(wifiQuestion) == [line(
            #"{"message":{"content":[{"text":"Your owner's profile is empty. They haven't asked you to remember anything about them.","type":"text"},{"text":"The dock has no agent runs.","type":"text"},"#
            + #"{"text":"Screen 1 of 1, 1280x827 pixels, with the cursor:","type":"text"},"#
            + #"{"source":{"data":"AQID","media_type":"image/jpeg","type":"base64"},"type":"image"},"#
            + #"{"text":"Where is the Wi-Fi menu?","type":"text"}],"role":"user"},"type":"user"}"#
        )])
        let recording = try fixture("talk-turn")
        var outputs: [ClaudeStream.Output] = []
        for start in stride(from: 0, to: recording.count, by: chunkSize) {
            outputs += stream.received(recording.subdata(in: start..<min(start + chunkSize, recording.count)))
        }
        #expect(outputs == recordedTalkTurn.map { .event($0) })
    }

    @Test(arguments: [1, 7, 64, 100_000])
    func recordedSearchTurnReportsEachSearchThenStreamsTheAnswer(chunkSize: Int) throws {
        var stream = ClaudeStream()
        _ = stream.send(asked("What's the top news story today?"))
        let recording = try fixture("search-turn")
        var outputs: [ClaudeStream.Output] = []
        for start in stride(from: 0, to: recording.count, by: chunkSize) {
            outputs += stream.received(recording.subdata(in: start..<min(start + chunkSize, recording.count)))
        }
        let answer = [
            "The lead story I", " found is", " a business jet crash in a", " Florida neighborhood", " this", " Sunday.\nN",
            "ine people were", " a", "board, and the transportation", " secretary says", " all nine died.\nThat", " com",
            "es from A", "P-", "style headlines on", " aggregator sites, so", " check", " the", " Associated Press site",
            " if", " you need", " it", " confirmed."
        ].map(ProviderEvent.textDelta)
        let events: [ProviderEvent] = [.searching, searchUsage(0.59), searchUsage(0.6), .searching, searchUsage(0.61)] + answer + [.completed]
        #expect(outputs == events.map { .event($0) })
    }

    @Test func searchInACancelledReplyIsNotReported() throws {
        var stream = ClaudeStream()
        _ = stream.send(asked("What's the top news story today?"))
        _ = stream.cancel()
        #expect(stream.received(try fixture("search-turn")) == [searchUsage(0.59), searchUsage(0.6), searchUsage(0.61)].map { .event($0) })
    }

    @Test func cancelledReplyIsInterruptedAndTheNextTurnWaitsForItsResult() throws {
        let (before, after) = try splitAtCancel(fixture("interrupted-turn"))
        var stream = ClaudeStream()
        #expect(stream.send(asked("Explain in detail, in at least twelve sentences, how a lighthouse lens works.")) == [line(
            #"{"message":{"content":[{"text":"Your owner's profile is empty. They haven't asked you to remember anything about them.","type":"text"},{"text":"The dock has no agent runs.","type":"text"},{"text":"Explain in detail, in at least twelve sentences, how a lighthouse lens works.","type":"text"}],"role":"user"},"type":"user"}"#
        )])
        #expect(stream.received(before) == [
            .event(.usage(recordedUsage)),
            .event(.textDelta("A lighthouse l"))
        ])
        #expect(stream.cancel() == [line(#"{"request":{"subtype":"interrupt"},"request_id":"interrupt-1","type":"control_request"}"#)])
        #expect(stream.cancel() == [])
        #expect(stream.send(asked("Just say the word two.")) == [])
        #expect(stream.received(after) == [
            line(#"{"message":{"content":[{"text":"Your owner's profile is empty. They haven't asked you to remember anything about them.","type":"text"},{"text":"The dock has no agent runs.","type":"text"},{"text":"Just say the word two.","type":"text"}],"role":"user"},"type":"user"}"#),
            .event(.textDelta("Two. [POINT:")),
            .event(.textDelta("none]")),
            .event(.completed)
        ])
        #expect(stream.cancel() == [])
    }

    @Test func usageReportedAfterACancelStillArrives() throws {
        let recording = String(decoding: try fixture("talk-turn"), as: UTF8.self)
        let usageLine = try #require(recording.split(separator: "\n").first { $0.contains(#""type":"rate_limit_event""#) })
        var stream = ClaudeStream()
        _ = stream.send(wifiQuestion)
        _ = stream.cancel()
        #expect(stream.received(Data((usageLine + "\n").utf8)) == [.event(.usage(recordedUsage))])
    }

    @Test func signedOutCLIEndsTheTurnAndItsProcess() throws {
        var stream = ClaudeStream()
        _ = stream.send(wifiQuestion)
        #expect(stream.received(try fixture("signed-out")) == [.event(.failed(.signedOut)), .endProcess])
    }

    @Test(arguments: ["rate_limit", "billing_error"])
    func refusalForTheUsageLimitFailsTheTurnAsLimitReached(error: String) {
        var stream = ClaudeStream()
        _ = stream.send(asked("help"))
        let refusal = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You've hit your limit"}]},"error":"\#(error)"}"#
        let result = #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit · resets 5pm"}"#
        #expect(stream.received(Data((refusal + "\n" + result + "\n").utf8)) == [.event(.failed(.limitReached))])
    }

    @Test func rejectedWindowCountsAsFull() {
        var stream = ClaudeStream()
        _ = stream.send(asked("help"))
        let event = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1793509200,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.98,"resetsAt":1793509200,"status":"rejected"},"seven_day":{"utilization":0.40,"resetsAt":1793667600,"status":"allowed"}}}}"#
        #expect(stream.received(Data((event + "\n").utf8)) == [.event(.usage(ProviderUsage(
            fiveHour: UsageWindow(utilization: 1, resetsAt: Date(timeIntervalSince1970: 1_793_509_200)),
            sevenDay: UsageWindow(utilization: 0.40, resetsAt: Date(timeIntervalSince1970: 1_793_667_600))
        )))])
    }

    @Test func errorResultFailsTheTurnWithItsFirstLine() {
        var stream = ClaudeStream()
        _ = stream.send(asked("help"))
        let result = #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 529 Overloaded\nTry again later."}"#
        #expect(stream.received(Data((result + "\n").utf8)) == [.event(.failed(.error("API Error: 529 Overloaded")))])
    }

    @Test func processEndingMidReplyFailsTheTurnWithTheLastErrorLine() throws {
        let recording = try fixture("talk-turn")
        var stream = ClaudeStream()
        _ = stream.send(wifiQuestion)
        let firstLines = recording.split(separator: UInt8(ascii: "\n")).prefix(3).map { $0 + Data("\n".utf8) }
        #expect(stream.received(firstLines.reduce(Data(), +)) == [.event(.usage(recordedUsage))])
        #expect(stream.ended(stderr: "warning: retrying\nerror: socket hang up\n") == [.event(.failed(.error("error: socket hang up")))])
        #expect(stream.ended(stderr: "") == [])
        #expect(stream.cancel() == [])
    }

    @Test func processEndingWhileTheNextTurnWaitsFailsThatTurn() {
        var waiting = ClaudeStream()
        _ = waiting.send(asked("tell me a story"))
        _ = waiting.cancel()
        _ = waiting.send(asked("say two"))
        #expect(waiting.ended(stderr: "") == [.event(.failed(.error("it quit unexpectedly")))])

        var cancelledOnly = ClaudeStream()
        _ = cancelledOnly.send(asked("tell me a story"))
        _ = cancelledOnly.cancel()
        #expect(cancelledOnly.ended(stderr: "") == [])
    }
}
