import Foundation
import Testing
import BuddyCore

struct PenSoundTests {
    private func cues(_ effects: [BuddyEngine.Effect]) -> [[PenSoundCue]] {
        effects.compactMap { if case .playPenSounds(let cues) = $0 { cues } else { nil } }
    }

    private func replying(penSounds: Bool = true, spokenReplies: Bool = true, reduceMotion: Bool = false) -> BuddyEngine {
        var engine = BuddyEngine(providerConnected: true, spokenReplies: spokenReplies, penSounds: penSounds, reduceMotion: reduceMotion)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("Draw."))
        _ = engine.handle(.screensCaptured([ScreenCapture(
            jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1280, height: 800),
            pixelWidth: 1280, pixelHeight: 800, containsCursor: true
        )]))
        return engine
    }

    private let oneStroke = "```draw\nbeat(\"Look.\"); stroke([[0, 0], [450, 0]]);\n```\n"

    @Test func theNextLinesPenStartsAtZeroWithoutCuttingOffThePreviousReveal() {
        var engine = replying()
        _ = engine.handle(.provider(.textDelta("""
        ```draw
        beat("First."); stroke([[0,0],[900,0],[0,0]]);
        beat("Second."); stroke([[0,20],[450,20]]);
        ```

        """)))
        #expect(cues(engine.handle(.lineStarted)) == [[PenSoundCue(offset: 0, duration: 1.2)]])
        #expect(engine.handle(.lineFinished) == [.speak("Second.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Second.")),
            .draw([.stroke([DisplayPoint(x: 0, y: 780), DisplayPoint(x: 450, y: 780)])],
                  on: DisplayRect(x: 0, y: 0, width: 1280, height: 800)),
            .playPenSounds([PenSoundCue(offset: 0, duration: 0.5)])
        ])
    }

    @Test func textConsumesRevealTimeWithoutScratchingAndArrowsAndRingsScratchToo() {
        var engine = replying()
        _ = engine.handle(.provider(.textDelta("""
        ```draw
        beat("Marks.");
        stroke([[0, 0], [90, 0]]);
        text(".", 100, 100, 16);
        arrow(0, 0, 422, 0);
        ring(0, 0, 84, 84);
        ```

        """)))
        #expect(cues(engine.handle(.lineStarted)) == [[
            PenSoundCue(offset: 0, duration: 0.25),
            PenSoundCue(offset: 0.5, duration: 0.5),
            PenSoundCue(offset: 1, duration: 0.3490658503988659)
        ]])
        _ = engine.handle(.interrupted)
        engine = replying()
        _ = engine.handle(.provider(.textDelta("```draw\nbeat(\"Words.\"); text(\".\", 100, 100, 16);\n```\n")))
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Words.")),
            .draw([.text(".", at: DisplayPoint(x: 100, y: 700), size: 16)], on: DisplayRect(x: 0, y: 0, width: 1280, height: 800))
        ])
    }

    @Test(arguments: [BuddyEngine.Event.interrupted, .pushToTalkPressed, .clearHistoryRequested])
    func clearingTheDrawingAlsoCancelsItsSound(event: BuddyEngine.Event) {
        var engine = replying()
        _ = engine.handle(.provider(.textDelta(oneStroke)))
        #expect(cues(engine.handle(.lineStarted)) == [[PenSoundCue(offset: 0, duration: 0.5)]])
        let effects = engine.handle(event)
        #expect(effects.contains(.stopPenSounds))
        #expect(effects.contains(.clearAnnotations))
    }

    @Test func reduceMotionPutsShortScratchesAtTheInstantMarksAppear() {
        var engine = replying()
        _ = engine.handle(.reduceMotionChanged(true))
        _ = engine.handle(.provider(.textDelta("```draw\nbeat(\"Look.\"); stroke([[0,0],[450,0]]); arrow(0,0,422,0);\n```\n")))
        #expect(cues(engine.handle(.lineStarted)) == [[
            PenSoundCue(offset: 0, duration: 0.08), PenSoundCue(offset: 0, duration: 0.08)
        ]])
        var animated = replying(reduceMotion: true)
        _ = animated.handle(.reduceMotionChanged(false))
        _ = animated.handle(.provider(.textDelta(oneStroke)))
        #expect(cues(animated.handle(.lineStarted)) == [[PenSoundCue(offset: 0, duration: 0.5)]])
    }

    @Test func cueDurationUsesDisplayPointsAfterScreenshotScaling() {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("Draw."))
        _ = engine.handle(.screensCaptured([ScreenCapture(
            jpeg: Data([1]), display: DisplayRect(x: -2560, y: 0, width: 2560, height: 1600),
            pixelWidth: 1280, pixelHeight: 800, containsCursor: true
        )]))
        _ = engine.handle(.provider(.textDelta(oneStroke)))
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Look.")),
            .draw([.stroke([DisplayPoint(x: -2560, y: 1600), DisplayPoint(x: -1660, y: 1600)])],
                  on: DisplayRect(x: -2560, y: 0, width: 2560, height: 1600)),
            .playPenSounds([PenSoundCue(offset: 0, duration: 1)])
        ])
    }

    @Test func switchingOffStopsPendingAndPlayingScratchesAndFutureLinesStaySilentUntilReenabled() {
        var engine = replying()
        _ = engine.handle(.provider(.textDelta("""
        ```draw
        beat("First."); stroke([[0, 0], [450, 0]]);
        beat("Second."); stroke([[0, 0], [450, 0]]);
        beat("Third."); stroke([[0, 0], [450, 0]]);
        ```

        """)))
        #expect(engine.handle(.lineStarted).last == .playPenSounds([PenSoundCue(offset: 0, duration: 0.5)]))
        #expect(engine.handle(.penSoundsChanged(false)) == [.stopPenSounds])
        #expect(engine.state.penSounds == false)
        _ = engine.handle(.lineFinished)
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Second.")),
            .draw([.stroke([DisplayPoint(x: 0, y: 800), DisplayPoint(x: 450, y: 800)])],
                  on: DisplayRect(x: 0, y: 0, width: 1280, height: 800))
        ])
        #expect(engine.handle(.penSoundsChanged(false)) == [])
        #expect(engine.handle(.penSoundsChanged(true)) == [])
        #expect(engine.state.penSounds == true)
        _ = engine.handle(.lineFinished)
        #expect(engine.handle(.lineStarted).last == .playPenSounds([PenSoundCue(offset: 0, duration: 0.5)]))
    }

    @Test func savedOffPreferenceKeepsDrawingAndIsIndependentOfSpeech() {
        var muted = replying(penSounds: false, spokenReplies: false)
        #expect(muted.handle(.provider(.textDelta(oneStroke))) == [
            .showNotch(.line("Look.")),
            .draw([.stroke([DisplayPoint(x: 0, y: 800), DisplayPoint(x: 450, y: 800)])],
                  on: DisplayRect(x: 0, y: 0, width: 1280, height: 800)),
            .waitForReading(.seconds(3))
        ])
        var audible = replying(spokenReplies: false)
        #expect(audible.handle(.provider(.textDelta(oneStroke))) == [
            .showNotch(.line("Look.")),
            .draw([.stroke([DisplayPoint(x: 0, y: 800), DisplayPoint(x: 450, y: 800)])],
                  on: DisplayRect(x: 0, y: 0, width: 1280, height: 800)),
            .playPenSounds([PenSoundCue(offset: 0, duration: 0.5)]),
            .waitForReading(.seconds(3))
        ])
    }

    @Test func penCuesFollowTheRevealsOfMappedMarksAndStartOnlyWithTheLine() {
        var engine = replying()
        let effects = engine.handle(.provider(.textDelta("""
        ```draw
        beat("Three strokes.");
        stroke([[0, 0], [90, 0]]);
        stroke([[0, 20], [450, 20]]);
        stroke([[0, 40], [900, 40], [0, 40]]);
        ```

        """)))
        #expect(effects == [.speak("Three strokes.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Three strokes.")),
            .draw([
                .stroke([DisplayPoint(x: 0, y: 800), DisplayPoint(x: 90, y: 800)]),
                .stroke([DisplayPoint(x: 0, y: 780), DisplayPoint(x: 450, y: 780)]),
                .stroke([DisplayPoint(x: 0, y: 760), DisplayPoint(x: 900, y: 760), DisplayPoint(x: 0, y: 760)])
            ], on: DisplayRect(x: 0, y: 0, width: 1280, height: 800)),
            .playPenSounds([
                PenSoundCue(offset: 0, duration: 0.25),
                PenSoundCue(offset: 0.25, duration: 0.5),
                PenSoundCue(offset: 0.75, duration: 1.2)
            ])
        ])
    }
}
