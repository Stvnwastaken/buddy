import Foundation
import Testing
import BuddyCore

private let laptop = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)

/// Plays both mouths. Each speaks every line it is given, except the lines the neural voice is set to fail.
private struct FakeMouth {
    var neuralFails: Set<String> = []

    func run(_ events: [BuddyEngine.Event], on engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
        var queue = events
        var performed: [BuddyEngine.Effect] = []
        while !queue.isEmpty {
            let effects = engine.handle(queue.removeFirst())
            performed += effects
            queue += effects.flatMap(reactions)
        }
        return performed
    }

    private func reactions(to effect: BuddyEngine.Effect) -> [BuddyEngine.Event] {
        guard case .speak(let line, let voice, _) = effect else { return [] }
        return voice == .neural && neuralFails.contains(line) ? [.lineFailed] : [.lineStarted, .lineFinished]
    }
}

/// Starts a turn and leaves the engine waiting for the reply.
private func ask(_ engine: inout BuddyEngine) {
    _ = engine.handle(.pushToTalkPressed)
    _ = engine.handle(.pushToTalkReleased)
    _ = engine.handle(.transcriptFinished("help"))
    _ = engine.handle(.screensCaptured([laptop]))
}

private func reply(_ text: String) -> [BuddyEngine.Event] {
    [.provider(.textDelta(text)), .provider(.completed)]
}

private func makeEngine() -> BuddyEngine {
    BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
}

/// The history a completed reply saves: every reply so far, in the one conversation the test's frozen clock keeps open.
private func saved(_ replies: String...) -> BuddyEngine.Effect {
    .saveHistory(ConversationHistory(conversations: [Conversation(
        turns: replies.map { TurnRecord(transcript: "help", reply: $0) },
        lastActivity: Date(timeIntervalSince1970: 1_000)
    )]))
}

struct VoiceTests {
    @Test func everyLineGoesToTheAppleVoiceUntilTheNeuralVoiceIsReady() {
        var engine = makeEngine()
        #expect(engine.state.neuralVoice == .loading)
        ask(&engine)
        #expect(FakeMouth().run(reply("Open the File menu.\nPick New Folder.\n"), on: &engine) == [
            .speak("Open the File menu.", voice: .apple),
            saved("Open the File menu.\nPick New Folder."),
            .showNotch(.line("Open the File menu.")),
            .speak("Pick New Folder.", voice: .apple),
            .showNotch(.line("Pick New Folder.")),
            .hideBuddy, .showNotch(.closing)
        ])

        #expect(engine.handle(.neuralVoiceObserved(.ready)) == [])
        #expect(engine.state.neuralVoice == .ready)
        ask(&engine)
        #expect(FakeMouth().run(reply("Open the File menu.\n[POINT:640,400:New Folder] Pick New Folder.\n"), on: &engine) == [
            .speak("Open the File menu.", voice: .neural),
            saved("Open the File menu.\nPick New Folder.", "Open the File menu.\nPick New Folder."),
            .showNotch(.line("Open the File menu.")),
            .speak("Pick New Folder.", voice: .neural),
            .showNotch(.line("Pick New Folder.")),
            .point(DisplayPoint(x: 720, y: 450), on: laptop.display, label: "New Folder"),
            .hideBuddy, .showNotch(.closing)
        ])
    }

    @Test func aLineTheNeuralVoiceFailsIsSpokenByTheAppleVoiceAndTheRestOfTheReplyStaysThere() {
        var engine = makeEngine()
        _ = engine.handle(.neuralVoiceObserved(.ready))
        let mouth = FakeMouth(neuralFails: ["Pick New Folder."])
        ask(&engine)
        #expect(mouth.run(reply("Open the File menu.\n[POINT:640,400:New Folder] Pick New Folder.\nName it.\n"), on: &engine) == [
            .speak("Open the File menu.", voice: .neural),
            saved("Open the File menu.\nPick New Folder.\nName it."),
            .showNotch(.line("Open the File menu.")),
            .speak("Pick New Folder.", voice: .neural),
            .speak("Pick New Folder.", voice: .apple),
            .showNotch(.line("Pick New Folder.")),
            .point(DisplayPoint(x: 720, y: 450), on: laptop.display, label: "New Folder"),
            .speak("Name it.", voice: .apple),
            .showNotch(.line("Name it.")),
            .hideBuddy, .showNotch(.closing)
        ])

        ask(&engine)
        #expect(mouth.run(reply("Done."), on: &engine) == [
            saved("Open the File menu.\nPick New Folder.\nName it.", "Done."),
            .speak("Done.", voice: .neural),
            .showNotch(.line("Done.")),
            .hideBuddy, .showNotch(.closing)
        ])
    }

    @Test(arguments: [
        [NeuralVoiceStatus.notInstalled],
        [.failed("The model is corrupt.")],
        [.ready, .failed("The model is corrupt.")],
        [.ready, .loading]
    ])
    func aMissingOrBrokenNeuralVoiceLeavesEveryLineToTheAppleVoice(statuses: [NeuralVoiceStatus]) {
        var engine = makeEngine()
        for status in statuses { #expect(engine.handle(.neuralVoiceObserved(status)) == []) }
        #expect(engine.state.neuralVoice == statuses.last)
        ask(&engine)
        #expect(FakeMouth().run(reply("It's up top.\nClick it.\n"), on: &engine) == [
            .speak("It's up top.", voice: .apple),
            saved("It's up top.\nClick it."),
            .showNotch(.line("It's up top.")),
            .speak("Click it.", voice: .apple),
            .showNotch(.line("Click it.")),
            .hideBuddy, .showNotch(.closing)
        ])
    }

    @Test func theReplysVoiceIsChosenWhenItsFirstLineIsSpoken() {
        var readyBeforeTheFirstLine = makeEngine()
        ask(&readyBeforeTheFirstLine)
        #expect(readyBeforeTheFirstLine.handle(.provider(.textDelta("It's up"))) == [])
        #expect(readyBeforeTheFirstLine.handle(.neuralVoiceObserved(.ready)) == [])
        #expect(FakeMouth().run([.provider(.textDelta(" top.\nClick it.\n")), .provider(.completed)], on: &readyBeforeTheFirstLine) == [
            .speak("It's up top.", voice: .neural),
            saved("It's up top.\nClick it."),
            .showNotch(.line("It's up top.")),
            .speak("Click it.", voice: .neural),
            .showNotch(.line("Click it.")),
            .hideBuddy, .showNotch(.closing)
        ])

        var readyDuringTheFirstLine = makeEngine()
        ask(&readyDuringTheFirstLine)
        #expect(readyDuringTheFirstLine.handle(.provider(.textDelta("It's up top.\nClick it.\n"))) == [
            .speak("It's up top.", voice: .apple)
        ])
        #expect(readyDuringTheFirstLine.handle(.lineStarted) == [.showNotch(.line("It's up top."))])
        #expect(readyDuringTheFirstLine.handle(.neuralVoiceObserved(.ready)) == [])
        #expect(readyDuringTheFirstLine.handle(.lineFinished) == [.speak("Click it.", voice: .apple)])
    }

    @Test func aFailureOnlyCountsBeforeTheLineStartsAndALineBothVoicesFailIsSkipped() {
        var engine = makeEngine()
        _ = engine.handle(.neuralVoiceObserved(.ready))
        ask(&engine)
        #expect(engine.handle(.provider(.textDelta("It's up top.\nClick it.\nThen pick one.\n"))) == [
            .speak("It's up top.", voice: .neural)
        ])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("It's up top."))])
        #expect(engine.handle(.lineFailed) == [])
        #expect(engine.handle(.lineFinished) == [.speak("Click it.", voice: .neural)])
        #expect(engine.handle(.lineFailed) == [.speak("Click it.", voice: .apple)])
        #expect(engine.handle(.lineFailed) == [.speak("Then pick one.", voice: .apple)])
        #expect(engine.handle(.lineFailed) == [.showNotch(.thinking)])
        #expect(engine.handle(.provider(.completed)) == [
            saved("It's up top.\nClick it.\nThen pick one."), .hideBuddy, .showNotch(.closing)
        ])
    }

    @Test(arguments: [
        ([], BuddyEngine.Event.interrupted, [BuddyEngine.Effect.cancelReply, .stopSpeaking, .hideBuddy, .showNotch(.idle)]),
        ([.lineStarted], .interrupted, [.cancelReply, .stopSpeaking, .hideBuddy, .showNotch(.idle)]),
        ([.lineFailed], .pushToTalkPressed, [.cancelReply, .stopSpeaking, .showNotch(.listening(heard: "")), .startListening]),
        ([.provider(.completed), .lineStarted], .pushToTalkPressed, [.stopSpeaking, .showNotch(.listening(heard: "")), .startListening])
    ] as [([BuddyEngine.Event], BuddyEngine.Event, [BuddyEngine.Effect])])
    func interruptionStopsTheNeuralVoiceWhileItPreparesOrSpeaksALine(
        before: [BuddyEngine.Event], interruption: BuddyEngine.Event, stops: [BuddyEngine.Effect]
    ) {
        var engine = makeEngine()
        _ = engine.handle(.neuralVoiceObserved(.ready))
        ask(&engine)
        #expect(engine.handle(.provider(.textDelta("Click the gear.\nThen"))) == [.speak("Click the gear.", voice: .neural)])
        for event in before { _ = engine.handle(event) }
        #expect(engine.handle(interruption) == stops)
        #expect([BuddyEngine.Event.lineFailed, .lineStarted, .lineFinished, .lineFailed].flatMap { engine.handle($0) } == [])
    }
}

struct VoicePickerTests {
    @Test func previewsUseTheListedVoiceAndCurrentSpeedWithoutStartingATurn() {
        var engine = makeEngine()
        #expect(engine.handle(.voicesObserved([.neural, .kokoro("am_adam"), .neural, .apple])) == [])
        #expect(engine.state.availableVoices == [.apple, .neural, .kokoro("am_adam")])
        #expect(engine.handle(.voicePreviewRequested(.neural)) == [])
        _ = engine.handle(.neuralVoiceObserved(.ready))
        _ = engine.handle(.speechSettingsChanged(SpeechSettings(speed: 0.75)))
        #expect(engine.handle(.voicePreviewRequested(.kokoro("am_adam"))) == [
            .previewVoice("Hello. I'm Buddy, your buddy on your Mac.", voice: .kokoro("am_adam"), speed: 0.75)
        ])
        #expect(engine.handle(.voicePreviewRequested(.apple)) == [
            .previewVoice("Hello. I'm Buddy, your buddy on your Mac.", voice: .apple, speed: 0.75)
        ])
        #expect(engine.handle(.voicePreviewRequested(.kokoro("not_installed"))) == [])
        #expect(engine.state.turn == .idle)
        #expect(engine.state.speechSettings == SpeechSettings(speed: 0.75))
    }

    @Test(arguments: [0.0, 2.1, Double.nan, Double.infinity])
    func invalidSpeedsDoNotChangeOrSaveChoices(speed: Double) {
        var engine = makeEngine()
        #expect(engine.handle(.speechSettingsChanged(SpeechSettings(voice: .apple, speed: speed))) == [])
        #expect(engine.state.speechSettings == SpeechSettings())
    }

    @Test func corruptOrOutOfRangeSavedChoicesUseDefaults() {
        #expect(BuddyEngine(speechSettingsData: Data("broken".utf8)).state.speechSettings == SpeechSettings())
        #expect(BuddyEngine(speechSettingsData: Data(#"{"speed":4,"voice":{"apple":{}}}"#.utf8)).state.speechSettings == SpeechSettings())
    }

    @Test func changingSettingsDuringSynthesisDoesNotLoseTheFailingLine() {
        var engine = makeEngine()
        _ = engine.handle(.neuralVoiceObserved(.ready))
        ask(&engine)
        #expect(engine.handle(.provider(.textDelta("One.\nTwo.\n"))) == [.speak("One.", voice: .neural)])
        _ = engine.handle(.speechSettingsChanged(SpeechSettings(voice: .kokoro("am_adam"), speed: 0.75)))
        #expect(engine.handle(.lineFailed) == [.speak("One.", voice: .apple)])
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.lineFinished) == [.speak("Two.", voice: .kokoro("am_adam"), speed: 0.75)])
    }

    @Test func speedChangesOnTheNextLineWithoutRetryingAFailedVoice() {
        var engine = makeEngine()
        _ = engine.handle(.neuralVoiceObserved(.ready))
        ask(&engine)
        _ = engine.handle(.provider(.textDelta("One.\nTwo.\n")))
        #expect(engine.handle(.lineFailed) == [.speak("One.", voice: .apple)])
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.speechSettingsChanged(SpeechSettings(speed: 0.5)))
        #expect(engine.handle(.lineFinished) == [.speak("Two.", voice: .apple, speed: 0.5)])
    }

    @Test func choicesApplyToTheNextLineAndSurviveReload() throws {
        var engine = makeEngine()
        _ = engine.handle(.neuralVoiceObserved(.ready))
        ask(&engine)
        #expect(engine.handle(.provider(.textDelta("One.\nTwo.\n"))) == [.speak("One.", voice: .neural)])
        #expect(engine.handle(.speechSettingsChanged(SpeechSettings(voice: .apple, speed: 1.5))) == [
            .saveSpeechSettings(Data(#"{"speed":1.5,"voice":{"apple":{}}}"#.utf8))
        ])
        _ = engine.handle(.lineStarted)
        #expect(engine.handle(.lineFinished) == [.speak("Two.", voice: .apple, speed: 1.5)])
        let restored = BuddyEngine(speechSettingsData: Data(#"{"speed":1.5,"voice":{"apple":{}}}"#.utf8))
        #expect(restored.state.speechSettings == SpeechSettings(voice: .apple, speed: 1.5))
    }
}
