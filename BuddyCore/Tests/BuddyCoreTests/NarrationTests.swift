import BuddyCore
import Foundation
import Testing

private let narrationScreen = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)

private func narrationEngine(spoken: Bool = false) -> BuddyEngine {
    var engine = BuddyEngine(providerConnected: true, spokenReplies: spoken, now: { Date(timeIntervalSince1970: 1_000) })
    _ = engine.handle(.pushToTalkPressed)
    _ = engine.handle(.pushToTalkReleased)
    _ = engine.handle(.transcriptFinished("help"))
    _ = engine.handle(.screensCaptured([narrationScreen]))
    return engine
}

struct NarrationTests {
    @Test func silentRepliesShowTheirWordsAndPointWithoutStartingSpeech() {
        var engine = narrationEngine()
        #expect(engine.handle(.provider(.textDelta("[POINT:640,400:settings] Open Settings.\nNext, choose Wi-Fi.\n"))) == [
            .showNotch(.line("Open Settings.")),
            .point(DisplayPoint(x: 720, y: 450), on: narrationScreen.display, label: "settings"),
            .waitForReading(.seconds(3))
        ])
        #expect(engine.handle(.lineStarted) == [])
        #expect(engine.handle(.lineFinished) == [])
        #expect(engine.handle(.replyLineRead) == [
            .showNotch(.line("Next, choose Wi-Fi.")), .waitForReading(.seconds(3))
        ])
        _ = engine.handle(.provider(.completed))
        #expect(engine.handle(.replyLineRead) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(.clockTick) == [])
        #expect(engine.handle(.interrupted) == [.showNotch(.idle)])
        #expect(engine.state.turn == .idle)
    }

    @Test(arguments: [false, true])
    func disablingNarrationStopsTheCurrentLineAndKeepsItsTextAndPoint(alreadySpeaking: Bool) {
        var engine = narrationEngine(spoken: true)
        #expect(engine.handle(.provider(.textDelta("[POINT:640,400:settings] Open Settings.\nNext, choose Wi-Fi.\n"))) == [
            .speak("Open Settings.", voice: .apple)
        ])
        if alreadySpeaking { _ = engine.handle(.lineStarted) }
        #expect(engine.handle(.spokenRepliesChanged(false)) == [.stopSpeaking]
            + (alreadySpeaking ? [] : [.showNotch(.line("Open Settings."))])
            + [.point(DisplayPoint(x: 720, y: 450), on: narrationScreen.display, label: "settings"), .waitForReading(.seconds(3))])
        #expect(engine.handle(.lineStarted) == [])
        #expect(engine.handle(.lineFinished) == [])
        #expect(engine.handle(.lineFailed) == [])
        #expect(engine.handle(.replyLineRead) == [
            .showNotch(.line("Next, choose Wi-Fi.")), .waitForReading(.seconds(3))
        ])
    }

    @Test func enablingNarrationWaitsForTheNextLineAndEndsTheReplyLikeASpokenOne() {
        var engine = narrationEngine()
        _ = engine.handle(.provider(.textDelta("First line.\nSecond line.\n")))
        #expect(engine.handle(.spokenRepliesChanged(true)) == [])
        #expect(engine.handle(.replyLineRead) == [.speak("Second line.", voice: .apple)])
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
    }

    @Test func disablingNarrationWhileTheNextLineStreamsKeepsThinkingAndClosesTheReply() {
        var engine = narrationEngine(spoken: true)
        _ = engine.handle(.provider(.textDelta("[POINT:640,400:settings] Open Settings.\n")))
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Open Settings.")),
            .point(DisplayPoint(x: 720, y: 450), on: narrationScreen.display, label: "settings")
        ])
        #expect(engine.handle(.lineFinished) == [.showNotch(.thinking)])
        #expect(engine.handle(.spokenRepliesChanged(false)) == [])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "help", reply: "Open Settings."), .hideBuddy, .showNotch(.closing)
        ])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(.interrupted) == [.showNotch(.idle)])
    }

    @Test func interruptionCancelsReadingAndTheProviderAndIgnoresLateCallbacks() {
        var engine = narrationEngine()
        _ = engine.handle(.provider(.textDelta("Read this.\n")))
        #expect(engine.handle(.interrupted) == [.cancelReply, .cancelReading, .hideBuddy, .showNotch(.idle)])
        #expect(engine.handle(.replyLineRead) == [])
        #expect(engine.handle(.provider(.completed)) == [])
        #expect(engine.state.turn == .idle)
    }

    @Test func aNewTurnCancelsReadingBeforeItListens() {
        var engine = narrationEngine()
        _ = engine.handle(.provider(.textDelta("Read this.\n")))
        #expect(engine.handle(.pushToTalkPressed) == [
            .cancelReply, .cancelReading, .showNotch(.listening(heard: "")), .startListening
        ])
        #expect(engine.handle(.replyLineRead) == [])
        #expect(engine.state.turn == .held)
    }

    @Test func clearingHistoryCancelsTheReadingTimer() {
        var engine = narrationEngine()
        _ = engine.handle(.provider(.textDelta("Read this.\n")))
        #expect(engine.handle(.clearHistoryRequested) == [
            .cancelReply, .cancelReading, .cancelCapture, .resetProvider, .hideBuddy, .showNotch(.idle), .clearHistory
        ])
        #expect(engine.handle(.replyLineRead) == [])
    }

    @Test func aProviderFailureCancelsReadingAndShowsTheFailure() {
        var engine = narrationEngine()
        _ = engine.handle(.provider(.textDelta("Read this.\n")))
        #expect(engine.handle(.provider(.failed(.notInstalled))) == [
            .cancelReading, .showNotch(.notice("Claude Code isn't installed. Install it and sign in, then try again."))
        ])
        #expect(engine.handle(.replyLineRead) == [])
        #expect(engine.state.turn == .idle)
    }

    @Test func longLinesHaveABoundedReadingTime() {
        var engine = narrationEngine()
        let words = Array(repeating: "word", count: 100).joined(separator: " ")
        #expect(engine.handle(.provider(.textDelta(words + ".\n"))) == [
            .showNotch(.line(words + ".")), .waitForReading(.seconds(20))
        ])
    }

    @Test func silentRepliesDrawTheirMarksAndClearThemBeforeATypedQuestion() {
        var engine = narrationEngine()
        #expect(engine.handle(.provider(.textDelta("[RING:600,380,680,420] Click Save.\n"))) == [
            .showNotch(.line("Click Save.")),
            .annotate(.shape(.ring, from: DisplayPoint(x: 675, y: 472.5), to: DisplayPoint(x: 765, y: 427.5)), on: narrationScreen.display),
            .waitForReading(.seconds(3))
        ])
        #expect(engine.handle(.lineStarted) == [])
        #expect(engine.handle(.provider(.completed)) == [savedTurn(transcript: "help", reply: "Click Save.")])
        #expect(engine.handle(.replyLineRead) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
        #expect(controlDoubleTap.flatMap { engine.handle($0) } == [
            .clearAnnotations, .hideBuddy, .showNotch(.idle), .showTextBox
        ])
        #expect(engine.state.turn == .typing)
    }

    @Test(arguments: [false, true])
    func mutingASpokenLineDrawsItsMarksExactlyOnce(alreadySpeaking: Bool) {
        var engine = narrationEngine(spoken: true)
        let ring = BuddyEngine.Effect.annotate(
            .shape(.ring, from: DisplayPoint(x: 675, y: 472.5), to: DisplayPoint(x: 765, y: 427.5)), on: narrationScreen.display
        )
        #expect(engine.handle(.provider(.textDelta("[RING:600,380,680,420] Click Save.\n"))) == [
            .speak("Click Save.", voice: .apple)
        ])
        if alreadySpeaking { #expect(engine.handle(.lineStarted) == [.showNotch(.line("Click Save.")), ring]) }
        #expect(engine.handle(.spokenRepliesChanged(false)) == [.stopSpeaking]
            + (alreadySpeaking ? [] : [.showNotch(.line("Click Save.")), ring]) + [.waitForReading(.seconds(3))])
        #expect(engine.handle(.lineStarted) == [])
        #expect(engine.handle(.interrupted) == [
            .cancelReply, .cancelReading, .clearAnnotations, .hideBuddy, .showNotch(.idle)
        ])
    }

}
