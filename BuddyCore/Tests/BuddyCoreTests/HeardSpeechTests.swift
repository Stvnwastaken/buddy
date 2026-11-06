import Foundation
import Testing
import BuddyCore

private let laptop = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)

/// SpeechTranscriber's results, as (text, isFinal), for "Open the settings. Then find the battery section.
/// What does low power mode do?" with pauses, recorded on macOS 26.6.2 with volatile and fast results.
/// The owner let go of push-to-talk after "What does".
private let resultsWhileHeld: [(String, Bool)] = [
    ("Open", false),
    ("Open the", false),
    ("Open the settings", false),
    ("Open the settings.", false),
    ("Open the settings.", true),
    (" Then", false),
    (" Then find", false),
    (" Then find the", false),
    (" Then find the battery", false),
    (" Then find the battery se", false),
    (" Then find the battery section", false),
    (" Then find the battery section.", false),
    (" Then find the battery section.", true),
    (" What", false),
    (" What does", false)
]
private let resultsAfterRelease: [(String, Bool)] = [
    (" What does low", false),
    (" What does low power", false),
    (" What does low power mode", false),
    (" What does low power mode do", false),
    (" What does low power mode do?", false),
    (" What does low power mode do?", true)
]

struct HeardSpeechTests {
    @Test func recordedResultsShowBesideTheWaveformAndTheTurnSendsTheFinalTranscript() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        var heard = HeardSpeech()
        let hear = { (results: [(String, Bool)]) in
            results.flatMap { text, isFinal in
                heard.receive(text, isFinal: isFinal)
                return engine.handle(.transcriptUpdated(heard.text))
            }
        }
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: "")), .startListening])
        #expect(hear(resultsWhileHeld) == [
            .showNotch(.listening(heard: "Open")),
            .showNotch(.listening(heard: "Open the")),
            .showNotch(.listening(heard: "Open the settings")),
            .showNotch(.listening(heard: "Open the settings.")),
            .showNotch(.listening(heard: "Open the settings. Then")),
            .showNotch(.listening(heard: "Open the settings. Then find")),
            .showNotch(.listening(heard: "Open the settings. Then find the")),
            .showNotch(.listening(heard: "Open the settings. Then find the battery")),
            .showNotch(.listening(heard: "Open the settings. Then find the battery se")),
            .showNotch(.listening(heard: "Open the settings. Then find the battery section")),
            .showNotch(.listening(heard: "Open the settings. Then find the battery section.")),
            .showNotch(.listening(heard: "Open the settings. Then find the battery section. What")),
            .showNotch(.listening(heard: "Open the settings. Then find the battery section. What does"))
        ])
        #expect(engine.handle(.pushToTalkReleased) == [.stopListening, .showBuddy, .showNotch(.thinking)])
        #expect(hear(resultsAfterRelease) == [])
        #expect(engine.handle(.transcriptFinished(heard.text)) == [.captureScreens])
        #expect(engine.handle(.screensCaptured([laptop])) == [.sendTurn(TurnRequest(
            transcript: "Open the settings. Then find the battery section. What does low power mode do?",
            captures: [laptop]
        ))])
    }

    @Test func aGuessNoFinalResultReplacedStaysInTheTranscript() {
        var heard = HeardSpeech()
        heard.receive("Open the settings.", isFinal: true)
        heard.receive(" Then find", isFinal: false)
        heard.receive(" Then find the battery", isFinal: false)
        #expect(heard.text == "Open the settings. Then find the battery")
    }

    @Test func wordsHeardOutsideAHeldPushToTalkAreNotShown() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(engine.handle(.transcriptUpdated("early")) == [])
        _ = engine.handle(.pushToTalkPressed)
        #expect(engine.handle(.transcriptUpdated(" where is\n")) == [.showNotch(.listening(heard: "where is"))])
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptUpdated("where is the")) == [])
        _ = engine.handle(.transcriptFinished("where is the wi-fi menu"))
        #expect(engine.handle(.transcriptUpdated("late")) == [])
        _ = engine.handle(.screensCaptured([laptop]))
        #expect(engine.handle(.transcriptUpdated("late")) == [])
        _ = engine.handle(.provider(.textDelta("Top right.")))
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "where is the wi-fi menu", reply: "Top right."), .speak("Top right.", voice: .apple)
        ])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Top right."))])
        #expect(engine.handle(.transcriptUpdated("late")) == [])
        _ = engine.handle(.interrupted)
        #expect(engine.handle(.transcriptUpdated("late")) == [])
    }
}
