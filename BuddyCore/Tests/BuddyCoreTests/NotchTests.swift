import BuddyCore
import Foundation
import Testing

private let notchScreen = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)

private func askedEngine(spoken: Bool = true) -> BuddyEngine {
    var engine = BuddyEngine(providerConnected: true, spokenReplies: spoken, now: { Date(timeIntervalSince1970: 1_000) })
    _ = engine.handle(.pushToTalkPressed)
    _ = engine.handle(.pushToTalkReleased)
    _ = engine.handle(.transcriptFinished("help"))
    _ = engine.handle(.screensCaptured([notchScreen]))
    return engine
}

/// An asked engine whose one-line reply has been spoken to the end.
private func repliedEngine() -> BuddyEngine {
    var engine = askedEngine()
    _ = engine.handle(.provider(.textDelta("Open Settings.")))
    _ = engine.handle(.provider(.completed))
    _ = engine.handle(.lineStarted)
    #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
    return engine
}

struct NotchTests {
    @Test func aSpokenTurnShowsTheHeardWordsThenThinkingThenEachLineAsItStarts() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: "")), .startListening])
        #expect(engine.handle(.transcriptUpdated("where is")) == [.showNotch(.listening(heard: "where is"))])
        #expect(engine.handle(.transcriptUpdated(" where is wi-fi ")) == [.showNotch(.listening(heard: "where is wi-fi"))])
        #expect(engine.handle(.pushToTalkReleased) == [.stopListening, .showBuddy, .showNotch(.thinking)])
        #expect(engine.handle(.transcriptFinished("where is wi-fi")) == [.captureScreens])
        #expect(engine.handle(.screensCaptured([notchScreen])) == [
            .sendTurn(TurnRequest(transcript: "where is wi-fi", captures: [notchScreen]))
        ])
        #expect(engine.handle(.provider(.textDelta("It's in the menu bar.\nClick it.\n"))) == [
            .speak("It's in the menu bar.", voice: .apple)
        ])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("It's in the menu bar."))])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "where is wi-fi", reply: "It's in the menu bar.\nClick it.")
        ])
        #expect(engine.handle(.lineFinished) == [.speak("Click it.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Click it."))])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
    }

    @Test func aTypedQuestionThinksOnceItIsSubmitted() {
        var engine = BuddyEngine(providerConnected: true)
        #expect(controlDoubleTap.flatMap { engine.handle($0) } == [.hideBuddy, .showTextBox])
        #expect(engine.handle(.textBoxSubmitted("  help\n")) == [
            .hideTextBox, .showBuddy, .showNotch(.thinking), .captureScreens
        ])
        #expect(engine.handle(.screensCaptured([notchScreen])) == [
            .sendTurn(TurnRequest(transcript: "help", captures: [notchScreen]))
        ])
    }

    @Test func theStripKeepsThinkingUntilTheFirstLineStarts() {
        var engine = askedEngine()
        #expect(engine.handle(.provider(.textDelta("One "))) == [])
        #expect(engine.handle(.provider(.textDelta("line.\n"))) == [.speak("One line.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("One line."))])
    }

    @Test func theStripShowsThinkingWhileTheNextSpokenLineStreams() {
        var engine = askedEngine()
        _ = engine.handle(.provider(.textDelta("First line.\n")))
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("First line."))])
        #expect(engine.handle(.lineFinished) == [.showNotch(.thinking)])
        #expect(engine.handle(.provider(.textDelta("Second line.\n"))) == [.speak("Second line.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Second line."))])
    }

    @Test func withSpokenRepliesOffTheStripShowsEachLineThenCloses() {
        var engine = askedEngine(spoken: false)
        #expect(engine.handle(.provider(.textDelta("First line.\nSecond line.\n"))) == [
            .showNotch(.line("First line.")), .waitForReading(.seconds(3))
        ])
        #expect(engine.handle(.replyLineRead) == [.showNotch(.line("Second line.")), .waitForReading(.seconds(3))])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "help", reply: "First line.\nSecond line.")
        ])
        #expect(engine.handle(.replyLineRead) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.state.turn == .idle)
    }

    @Test func escClosesTheStripAtOnceAfterTheReply() {
        var engine = repliedEngine()
        #expect(engine.handle(.interrupted) == [.showNotch(.idle)])
        #expect(engine.handle(.interrupted) == [])
    }

    @Test(arguments: [false, true])
    func escClosesTheStripAtOnceDuringTheReply(spoken: Bool) {
        var engine = askedEngine(spoken: spoken)
        _ = engine.handle(.provider(.textDelta("First line.\n")))
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.interrupted) == [
            .cancelReply, spoken ? .stopSpeaking : .cancelReading, .hideBuddy, .showNotch(.idle)
        ])
        #expect(engine.handle(.provider(.textDelta("late\n"))) == [])
        #expect(engine.handle(.lineStarted) == [])
        #expect(engine.handle(.replyLineRead) == [])
    }

    @Test(arguments: [false, true])
    func escWhileThinkingClosesTheStrip(afterTranscript: Bool) {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        if afterTranscript { _ = engine.handle(.transcriptFinished("help")) }
        #expect(engine.handle(.interrupted) == [.hideBuddy, .showNotch(.idle)])
        #expect(engine.handle(.screensCaptured([notchScreen])) == [])
    }

    @Test func aNewPressReplacesTheClosingStripWithListening() {
        var engine = repliedEngine()
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: "")), .startListening])
    }

    @Test(arguments: [false, true])
    func openingTheComposerKeepsThinkingButANewPressReplacesTheTurn(typed: Bool) {
        var engine = askedEngine()
        if typed {
            #expect(controlDoubleTap.flatMap { engine.handle($0) } == [.showTextBox])
            #expect(engine.handle(.provider(.textDelta("Still working.\n"))) == [.speak("Still working.", voice: .apple)])
        } else {
            #expect(engine.handle(.pushToTalkPressed) == [
                .cancelReply, .showNotch(.listening(heard: "")), .startListening
            ])
            #expect(engine.handle(.provider(.completed)) == [])
        }
    }

    @Test(arguments: [false, true])
    func aProviderFailureShowsItsNoticeUntilItExpires(lineStarted: Bool) {
        var engine = askedEngine()
        _ = engine.handle(.provider(.textDelta("First line.\n")))
        if lineStarted { _ = engine.handle(.lineStarted) }
        #expect(engine.handle(.provider(.failed(.signedOut))) == [
            .stopSpeaking, .showNotch(.notice("Claude Code is signed out. Run claude in Terminal to sign in."))
        ])
        #expect(engine.handle(.noticeExpired) == [.hideBuddy, .showNotch(.idle)])
    }

    @Test(arguments: [false, true])
    func aNoticeWhileTheTextBoxIsOpenStillExpires(boxClosedFirst: Bool) {
        var engine = BuddyEngine(providerConnected: true)
        _ = controlDoubleTap.flatMap { engine.handle($0) }
        #expect(engine.handle(.typingRefused) == [
            .showNotch(.notice("I didn't type that, because secure input is on, as in a password field."))
        ])
        if boxClosedFirst { #expect(engine.handle(.textBoxDismissed) == [.hideTextBox]) }
        #expect(engine.handle(.noticeExpired) == (boxClosedFirst ? [.hideBuddy] : []) + [.showNotch(.idle)])
        #expect(engine.handle(.noticeExpired) == [])
    }

    @Test func aCaptureFailureReplacesThinkingWithItsNotice() {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("help"))
        #expect(engine.handle(.captureFailed("No display available.")) == [.showNotch(.notice("No display available."))])
        #expect(engine.handle(.interrupted) == [.hideBuddy, .showNotch(.idle)])
    }

    @Test func anEmptyTranscriptClosesTheStripAtOnce() {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished(" \n ")) == [.hideBuddy, .showNotch(.idle)])
    }

    @Test func aReplyWithNoLinesClosesTheStripAtOnce() {
        var engine = askedEngine()
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "help", reply: ""), .hideBuddy, .showNotch(.idle)
        ])
    }

    @Test func aNoticeAtTheEndOfAReplyStaysUpWhileTheStripCloses() {
        var engine = askedEngine()
        _ = engine.handle(.provider(.textDelta("[TYPE:640,400:cats] Typing cats.")))
        _ = engine.handle(.provider(.completed))
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Typing cats.")),
            .showNotch(.notice("Buddy needs Accessibility permission to type for you."))
        ])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
    }

    @Test(arguments: [false, true])
    func clearingHistoryClosesTheStrip(spoken: Bool) {
        var engine = askedEngine(spoken: spoken)
        _ = engine.handle(.provider(.textDelta("First line.\n")))
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.clearHistoryRequested) == [
            .cancelReply, spoken ? .stopSpeaking : .cancelReading,
            .cancelCapture, .resetProvider, .hideBuddy, .showNotch(.idle), .clearHistory
        ])
        #expect(engine.handle(.provider(.completed)) == [])
        #expect(engine.handle(.lineFinished) == [])
        #expect(engine.handle(.replyLineRead) == [])
    }
}
