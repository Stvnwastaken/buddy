import Foundation
import Testing
import BuddyCore

private let laptop = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)
private let leftMonitor = ScreenCapture(
    jpeg: Data([2]), display: DisplayRect(x: -1920, y: 180, width: 1920, height: 1080),
    pixelWidth: 1280, pixelHeight: 720, containsCursor: false
)
private let leftMonitorWithCursor = ScreenCapture(
    jpeg: Data([2]), display: leftMonitor.display, pixelWidth: 1280, pixelHeight: 720, containsCursor: true
)
private let laptopWithoutCursor = ScreenCapture(
    jpeg: Data([1]), display: laptop.display, pixelWidth: 1280, pixelHeight: 800, containsCursor: false
)

private func replyingEngine(screens: [ScreenCapture] = [laptop], spokenReplies: Bool = true) -> BuddyEngine {
    var engine = BuddyEngine(
        providerConnected: true, spokenReplies: spokenReplies, penSounds: false, now: { Date(timeIntervalSince1970: 1_000) },
        drawTimeLimit: .milliseconds(100)
    )
    let start: [BuddyEngine.Event] = [.pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("draw it"), .screensCaptured(screens)]
    for event in start { _ = engine.handle(event) }
    return engine
}

private func program(_ source: String) -> String {
    "```draw\n\(source)\n```\n"
}

/// Streams the reply in one piece, then plays every line it starts to the end.
private func play(_ reply: String, on engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
    var effects = engine.handle(.provider(.textDelta(reply))) + engine.handle(.provider(.completed))
    for _ in 0..<50 {
        guard case .replying = engine.state.turn else { break }
        effects += engine.handle(.lineStarted) + engine.handle(.lineFinished)
    }
    return effects
}

/// What streaming the whole program does, before the reply ends.
private func firstEffects(of source: String) -> [BuddyEngine.Effect] {
    var engine = replyingEngine()
    return engine.handle(.provider(.textDelta(program(source))))
}

private let urlProgram = program("""
beat("A web address has two parts.");
ring(100, 80, 300, 160);
beat("Then the path.");
arrow(400, 400, 320, 320);
stroke([[0, 0], [80, 80], [160, 0]]);
text("docs", 640, 400, 40);
""")

private let urlEffects: [BuddyEngine.Effect] = [
    .speak("A web address has two parts.", voice: .apple),
    savedTurn(transcript: "draw it", reply: "A web address has two parts.\nThen the path."),
    .showNotch(.line("A web address has two parts.")),
    .draw([.ring(from: DisplayPoint(x: 112.5, y: 810), to: DisplayPoint(x: 337.5, y: 720))], on: laptop.display),
    .speak("Then the path.", voice: .apple),
    .showNotch(.line("Then the path.")),
    .draw([
        .arrow(from: DisplayPoint(x: 450, y: 450), to: DisplayPoint(x: 360, y: 540)),
        .stroke([DisplayPoint(x: 0, y: 900), DisplayPoint(x: 90, y: 810), DisplayPoint(x: 180, y: 900)]),
        .text("docs", at: DisplayPoint(x: 720, y: 450), size: 45)
    ], on: laptop.display),
    .hideBuddy, .showNotch(.closing)
]

struct DrawProgramTests {
    @Test func handwritingCanBeRecordedByAProgram() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta(program("beat(\"A handwritten note.\"); handwriting(\"Three quarters\", 100, 80, 40);")))) == [
            .speak("A handwritten note.", voice: .apple)
        ])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("A handwritten note.")),
            .draw([.handwriting("Three quarters", at: DisplayPoint(x: 112.5, y: 810), size: 45)], on: laptop.display)
        ])
    }

    @Test func papersRecordTheirKindContentAndScaledGeometryOnTheirOwnLine() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta(program("""
        beat("First the card."); card("Three of four equal parts.", 100, 80, 400, 40);
        beat("Then the sticky."); sticky("Equal parts.", 600, 200);
        """)))) == [.speak("First the card.", voice: .apple)])
        #expect(engine.state.papers == [])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("First the card.")),
            .draw([.paper(DrawPaper(id: 1, kind: .card, words: "Three of four equal parts.",
                                  at: DisplayPoint(x: 112.5, y: 810), width: 450, size: 45))], on: laptop.display)
        ])
        #expect(engine.state.papers == [PlacedPaper(
            paper: DrawPaper(id: 1, kind: .card, words: "Three of four equal parts.",
                             at: DisplayPoint(x: 112.5, y: 810), width: 450, size: 45), display: laptop.display
        )])
        #expect(engine.handle(.lineFinished) == [.speak("Then the sticky.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Then the sticky.")),
            .draw([.paper(DrawPaper(id: 2, kind: .sticky, words: "Equal parts.",
                                  at: DisplayPoint(x: 675, y: 675), width: 270, size: 36))], on: laptop.display)
        ])
    }

    @Test func closingMovingAndPinningPapersGoThroughTheEngine() {
        var engine = replyingEngine()
        _ = play(program("beat(\"Look.\"); card(\"A note.\", 100, 80); sticky(\"A reminder.\", 600, 200);"), on: &engine)
        let moved = PlacedPaper(paper: DrawPaper(id: 1, kind: .card, words: "A note.",
                                                at: DisplayPoint(x: -500, y: 720), width: 472.5, size: 36),
                                display: laptop.display)
        #expect(engine.handle(.paperMoved(1, to: DisplayPoint(x: -500, y: 720))) == [.updatePaper(moved)])
        let pinned = PlacedPaper(paper: DrawPaper(id: 1, kind: .card, words: "A note.",
                                                 at: DisplayPoint(x: -500, y: 720), width: 472.5, size: 36),
                                 display: laptop.display, pinned: true)
        #expect(engine.handle(.paperPinToggled(1)) == [.updatePaper(pinned)])
        #expect(engine.handle(.paperClosed(2)) == [.removePaper(2)])
        #expect(engine.state.papers == [pinned])
        #expect(engine.handle(.pushToTalkPressed).contains(.removePaper(1)) == false)
        #expect(engine.state.papers == [pinned])
        #expect(engine.handle(.paperPinToggled(1)) == [.updatePaper(moved)])
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("thanks"))
        _ = engine.handle(.screensCaptured([laptop]))
        #expect(engine.handle(.pushToTalkPressed).contains(.removePaper(1)))
        #expect(engine.state.papers == [])
    }

    @Test(arguments: [BuddyEngine.Event.pushToTalkPressed, .interrupted, .clearHistoryRequested])
    func unpinnedPapersClearWithTheOtherMarks(event: BuddyEngine.Event) {
        var engine = replyingEngine()
        _ = play(program("beat(\"Look.\"); card(\"A note.\", 100, 80); sticky(\"A reminder.\", 600, 200);"), on: &engine)
        let effects = engine.handle(event)
        #expect(effects.contains(.removePaper(1)))
        #expect(effects.contains(.removePaper(2)))
        #expect(effects.contains(.clearAnnotations))
        #expect(engine.state.papers == [])
    }

    @Test(arguments: [BuddyEngine.Event.interrupted, .clearHistoryRequested])
    func escapeAndClearHistoryRemovePinnedPapersToo(event: BuddyEngine.Event) {
        var engine = replyingEngine()
        _ = play(program("beat(\"Look.\"); card(\"A note.\", 100, 80);"), on: &engine)
        _ = engine.handle(.paperPinToggled(1))
        #expect(engine.handle(event).contains(.removePaper(1)))
        #expect(engine.state.papers == [])
    }

    @Test func stalePaperActionsAndNonfiniteMovesAreIgnored() {
        var engine = replyingEngine()
        _ = play(program("beat(\"Look.\"); card(\"A note.\", 100, 80);"), on: &engine)
        #expect(engine.handle(.paperMoved(1, to: DisplayPoint(x: .nan, y: 0))) == [])
        #expect(engine.handle(.paperMoved(1, to: DisplayPoint(x: 0, y: .infinity))) == [])
        #expect(engine.handle(.paperClosed(1)) == [.removePaper(1)])
        #expect(engine.handle(.paperClosed(1)) == [])
        #expect(engine.handle(.paperPinToggled(1)) == [])
        #expect(engine.handle(.paperMoved(1, to: DisplayPoint(x: 0, y: 0))) == [])
        #expect(engine.state.papers == [])
    }

    @Test func handwritingMeasurementUsesTheDrawingFontAndDefaultSize() {
        #expect(firstEffects(of: """
        const narrow = measureHandwriting("iii");
        const wide = measureHandwriting("WWW", 32);
        const larger = measureHandwriting("WWW", 64);
        beat(`${narrow.width > 0} ${narrow.width < wide.width} ${larger.width > wide.width} ${larger.height > wide.height}`);
        """) == [.speak("true true true true", voice: .apple)])
    }

    @Test func newMarksUseTheSharedRevealTimingAfterDisplayMapping() {
        var engine = replyingEngine()
        let effects = play(program("""
        beat("Look.");
        handwriting("i", 100, 80, 40);
        handwriting("W".repeat(200), 100, 120, 200);
        card("A note.", 100, 200, 400);
        sticky("A reminder.", 600, 200);
        """), on: &engine)
        let durations = effects.flatMap { effect -> [Double] in
            guard case .draw(let marks, _) = effect else { return [] }
            return marks.map(\.revealDuration)
        }
        #expect(durations == [0.25, 1.2, 0.9, 0.54])
    }

    @Test func handwritingScratchesAndSilentPaperKeepTheFollowingStrokeAtItsRevealOffset() {
        var engine = replyingEngine()
        _ = engine.handle(.penSoundsChanged(true))
        _ = engine.handle(.provider(.textDelta(program("""
        beat("Look."); handwriting("i", 100, 80, 40); card("A note.", 100, 200, 400);
        stroke([[0, 0], [400, 0]]);
        """))))
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Look.")),
            .draw([
                .handwriting("i", at: DisplayPoint(x: 112.5, y: 810), size: 45),
                .paper(DrawPaper(id: 1, kind: .card, words: "A note.", at: DisplayPoint(x: 112.5, y: 675), width: 450, size: 36)),
                .stroke([DisplayPoint(x: 0, y: 900), DisplayPoint(x: 450, y: 900)])
            ], on: laptop.display),
            .playPenSounds([PenSoundCue(offset: 0, duration: 0.25), PenSoundCue(offset: 1.15, duration: 0.5)])
        ])
    }

    @Test func reducedMotionMakesHandwritingAndStrokeScratchTogetherWithoutAPaperCue() {
        var engine = replyingEngine()
        _ = engine.handle(.penSoundsChanged(true))
        _ = engine.handle(.reduceMotionChanged(true))
        _ = engine.handle(.provider(.textDelta(program("""
        beat("Look."); handwriting("i", 100, 80, 40); card("A note.", 100, 200, 400);
        stroke([[0, 0], [400, 0]]);
        """))))
        #expect(engine.handle(.lineStarted).last == .playPenSounds([
            PenSoundCue(offset: 0, duration: 0.08), PenSoundCue(offset: 0, duration: 0.08)
        ]))
    }

    @Test func disablingPenSoundsCancelsHandwritingAndKeepsTheNextHandwrittenLineSilent() {
        var engine = replyingEngine()
        _ = engine.handle(.penSoundsChanged(true))
        _ = engine.handle(.provider(.textDelta(program("""
        beat("First."); handwriting("i", 100, 80, 40);
        beat("Second."); handwriting("i", 100, 80, 40);
        """))))
        #expect(engine.handle(.lineStarted).last == .playPenSounds([PenSoundCue(offset: 0, duration: 0.25)]))
        #expect(engine.handle(.penSoundsChanged(false)) == [.stopPenSounds])
        _ = engine.handle(.lineFinished)
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Second.")),
            .draw([.handwriting("i", at: DisplayPoint(x: 112.5, y: 810), size: 45)], on: laptop.display)
        ])
    }

    @Test func papersUseTheCursorDisplayEvenWithANegativeOrigin() {
        var engine = replyingEngine(screens: [laptopWithoutCursor, leftMonitorWithCursor])
        _ = engine.handle(.provider(.textDelta(program("beat(\"Look.\"); card(\"A note.\", 100, 80, 400, 40);"))))
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Look.")),
            .draw([.paper(DrawPaper(id: 1, kind: .card, words: "A note.",
                                  at: DisplayPoint(x: -1770, y: 1140), width: 600, size: 60))], on: leftMonitor.display)
        ])
    }

    @Test(arguments: [
        ("handwriting(\"x\", 1, 2);", "Call beat(line) before drawing."),
        ("sticky(\"x\", 1, 2);", "Call beat(line) before drawing."),
        ("card(\"x\", 1, 2);", "Call beat(line) before drawing."),
        ("beat(\"Hi.\"); handwriting(\"\", 1, 2);", "handwriting needs words, then x and y."),
        ("beat(\"Hi.\"); handwriting(\"x\", NaN, 2);", "handwriting needs words, then x and y."),
        ("beat(\"Hi.\"); handwriting(\"x\", 1, 2, 0);", "handwriting's size must be a positive number."),
        ("beat(\"Hi.\"); card(\"x\", 1, 2, -1);", "card's width must be a positive number."),
        ("beat(\"Hi.\"); sticky(\"x\", 1, 2, Infinity);", "sticky's width must be a positive number."),
        ("beat(\"Hi.\"); sticky(\"x\", 1, 2, 240, NaN);", "sticky's size must be a positive number."),
        ("beat(\"Hi.\"); card(\" \");", "card needs words, then x and y."),
        ("beat(\"Hi.\"); card(\"x\".repeat(201), 1, 2);", "Text can have at most 200 characters."),
        ("beat(\"Hi.\"); handwriting(\"x\".repeat(201), 1, 2);", "Text can have at most 200 characters."),
        ("beat(\"Hi.\"); measureHandwriting(2);", "measureHandwriting needs words."),
        ("beat(\"Hi.\"); measureHandwriting(\"x\", -1);", "measureHandwriting's size must be a positive number."),
        ("beat(\"Hi.\"); for (let i = 0; i < 201; i++) card(\"x\", 1, 2);", "A draw program can have at most 200 marks.")
    ])
    func invalidNewMarksFailWithoutLeavingPaper(source: String, error: String) {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta(program(source)))) == [
            .cancelReply, .showNotch(.notice("The draw program failed: Error: \(error)"))
        ])
        #expect(engine.state.papers == [])
    }

    @Test func aProgramsBeatsAreSpokenInOrderAndEachLinesMarksDrawAsItStarts() {
        var engine = replyingEngine()
        #expect(play(urlProgram, on: &engine) == urlEffects)
    }

    @Test(arguments: [1, 2, 3, 7, 40, 1_000])
    func aProgramSplitAcrossDeltasRunsOnceItsFenceCloses(chunkSize: Int) {
        var engine = replyingEngine()
        let scalars = Array(urlProgram.unicodeScalars)
        var effects: [BuddyEngine.Effect] = []
        for start in stride(from: 0, to: scalars.count, by: chunkSize) {
            let chunk = String(String.UnicodeScalarView(scalars[start..<min(start + chunkSize, scalars.count)]))
            effects += engine.handle(.provider(.textDelta(chunk)))
        }
        #expect(effects == [.speak("A web address has two parts.", voice: .apple)])
    }

    @Test func blankLinesBeforeTheFenceAndAnythingAfterItAreIgnored() {
        var engine = replyingEngine()
        #expect(play("\n  \n" + urlProgram + "Hope that helps!\n", on: &engine) == urlEffects)
    }

    @Test func searchPartWayThroughAProgramLineLeavesTheLineWhole() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("```draw\nbeat(\"Just th"))) == [])
        #expect(engine.handle(.provider(.searching)) == [.speak("Let me look that up.", voice: .apple)])
        #expect(engine.handle(.lineStarted) + engine.handle(.lineFinished) == [
            .showNotch(.line("Let me look that up.")), .showNotch(.thinking)
        ])
        #expect(engine.handle(.provider(.textDelta("is.\");\n```\n"))) == [.speak("Just this.", voice: .apple)])
        #expect(engine.handle(.provider(.completed)) == [savedTurn(transcript: "draw it", reply: "Just this.")])
    }

    @Test func anUnclosedProgramRunsWhenTheReplyEnds() {
        var engine = replyingEngine()
        let unclosed = "```draw\nbeat(\"Just this.\");\nring(100, 80, 300, 160);"
        #expect(engine.handle(.provider(.textDelta(unclosed))) == [])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "draw it", reply: "Just this."), .speak("Just this.", voice: .apple)
        ])
    }

    @Test(arguments: ["```draw\nbeat(\"Just this.\");\n```", "```draw\nbeat(\"Just this.\");\n  ```  "])
    func aClosingFenceThatEndsTheReplyWithNoNewlineEndsTheProgram(reply: String) {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta(reply))) == [])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "draw it", reply: "Just this."), .speak("Just this.", voice: .apple)
        ])
    }

    @Test func linesBeforeTheFenceAreSpokenFirstAndTheProgramFollows() {
        var engine = replyingEngine()
        #expect(play("Sure, here's a picture.\n" + program("beat(\"Look.\"); ring(100, 80, 300, 160);"), on: &engine) == [
            .speak("Sure, here's a picture.", voice: .apple),
            savedTurn(transcript: "draw it", reply: "Sure, here's a picture.\nLook."),
            .showNotch(.line("Sure, here's a picture.")),
            .speak("Look.", voice: .apple),
            .showNotch(.line("Look.")),
            .draw([.ring(from: DisplayPoint(x: 112.5, y: 810), to: DisplayPoint(x: 337.5, y: 720))], on: laptop.display),
            .hideBuddy, .showNotch(.closing)
        ])
    }

    @Test func aBrokenProgramAfterASpokenLineStopsTheVoice() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("Sure, here's a picture.\n"))) == [.speak("Sure, here's a picture.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Sure, here's a picture."))])
        #expect(engine.handle(.provider(.textDelta(program("ring(1, 2, 3, 4);")))) == [
            .cancelReply, .stopSpeaking, .showNotch(.notice("The draw program failed: Error: Call beat(line) before drawing."))
        ])
        #expect(engine.state.turn == .idle)
    }

    @Test(arguments: [false, true])
    func aBrokenProgramDropsTheRunOfferOfALineBeforeIt(endsWithTheReply: Bool) {
        var engine = replyingEngine()
        _ = engine.handle(.provider(.textDelta("[RUN:Sort the Downloads folder] Want me to sort it as an agent run?\n")))
        _ = engine.handle(.lineStarted)
        #expect(engine.state.runOffer?.request == "Sort the Downloads folder")
        let broken = "```draw\nring(1, 2, 3, 4);"
        let effects = endsWithTheReply
            ? engine.handle(.provider(.textDelta(broken))) + engine.handle(.provider(.completed))
            : engine.handle(.provider(.textDelta(broken + "\n```\n")))
        #expect(effects == (endsWithTheReply ? [] : [.cancelReply]) + [
            .stopSpeaking, .showNotch(.notice("The draw program failed: Error: Call beat(line) before drawing."))
        ])
        #expect(engine.state.runOffer == nil)
    }

    @Test(arguments: [
        ("beat(\"Look.\");", [BuddyEngine.Effect.speak("Got it.", voice: .apple)]),
        ("ring(1, 2, 3, 4);", [
            BuddyEngine.Effect.cancelReply, .showNotch(.notice("The draw program failed: Error: Call beat(line) before drawing."))
        ])
    ])
    func aProfileEditBeforeTheFenceIsKeptWhetherOrNotTheProgramWorks(source: String, rest: [BuddyEngine.Effect]) {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("[REMEMBER:Likes diagrams.] Got it.\n" + program(source)))) == [
            .saveProfile(Profile(notes: ["Likes diagrams."]))
        ] + rest)
    }

    @Test func aProgramDrawsOnTheScreenWithTheCursor() {
        var engine = replyingEngine(screens: [laptopWithoutCursor, leftMonitorWithCursor])
        let source = program("beat(\"Over here.\"); ring(0, 0, canvas.width, canvas.height);")
        #expect(play(source, on: &engine) == [
            .speak("Over here.", voice: .apple),
            savedTurn(transcript: "draw it", reply: "Over here."),
            .showNotch(.line("Over here.")),
            .draw([.ring(from: DisplayPoint(x: -1920, y: 1260), to: DisplayPoint(x: 0, y: 180))], on: leftMonitor.display),
            .hideBuddy, .showNotch(.closing)
        ])
    }

    @Test func withSpokenRepliesOffEachBeatIsShownWithItsMarks() {
        var engine = replyingEngine(spokenReplies: false)
        #expect(engine.handle(.provider(.textDelta(program("beat(\"Look.\"); ring(100, 80, 300, 160);")))) == [
            .showNotch(.line("Look.")),
            .draw([.ring(from: DisplayPoint(x: 112.5, y: 810), to: DisplayPoint(x: 337.5, y: 720))], on: laptop.display),
            .waitForReading(.seconds(3))
        ])
    }

    @Test(arguments: [
        BuddyEngine.Event.pushToTalkPressed, .interrupted, .clearHistoryRequested
    ])
    func marksClearOnTheNextTurnEscapeOrClearingHistory(event: BuddyEngine.Event) {
        var engine = replyingEngine()
        _ = play(urlProgram, on: &engine)
        #expect(engine.handle(event).contains(.clearAnnotations))
    }

    @Test func measuringHelpersReportPathsAndText() {
        let source = """
        const p = measurePath([[0, 0], [30, 40], [30, 100]]);
        const narrow = measureText("iii", 40), wide = measureText("WWW", 40), none = measureText("", 40);
        const sized = narrow.width < wide.width && narrow.height === wide.height && wide.height > 40 && none.width === 0;
        const bigger = measureText("WWW", 80).width > wide.width;
        beat(`${p.length} ${p.left} ${p.top} ${p.right} ${p.bottom} ${sized} ${bigger} ${measureText("a").height === measureText("a", 32).height}`);
        """
        #expect(firstEffects(of: source) == [.speak("110 0 0 30 100 true true true", voice: .apple)])
    }

    @Test(arguments: [
        ("fetch(\"https://example.com\");", "ReferenceError: Can't find variable: fetch"),
        ("require(\"fs\");", "ReferenceError: Can't find variable: require"),
        ("new XMLHttpRequest();", "ReferenceError: Can't find variable: XMLHttpRequest"),
        ("console.log(\"hi\");", "ReferenceError: Can't find variable: console"),
        ("WebAssembly.validate(new Uint8Array());", "ReferenceError: Can't find variable: WebAssembly"),
        ("setTimeout(() => {}, 0);", "ReferenceError: Can't find variable: setTimeout"),
        ("webkit.messageHandlers.buddy.postMessage(1);", "ReferenceError: Can't find variable: webkit"),
        ("process.exit(1);", "ReferenceError: Can't find variable: process")
    ])
    func forbiddenAccessFailsTheProgram(source: String, error: String) {
        #expect(firstEffects(of: "beat(\"Hi.\"); " + source) == [.cancelReply, .showNotch(.notice("The draw program failed: \(error)"))])
    }

    @Test func importingAFileIsRefused() {
        let source = """
        beat("Start.");
        import("/etc/hosts").then(() => beat("Loaded."), () => beat("Refused."));
        import("file:///etc/hosts").then(() => beat("Loaded."), () => beat("Refused."));
        """
        var engine = replyingEngine()
        let spoken = play(program(source), on: &engine).compactMap { effect -> String? in
            guard case .speak(let line, _, _) = effect else { return nil }
            return line
        }
        #expect(spoken == ["Start.", "Refused.", "Refused."])
    }

    @Test(arguments: [
        "while (true) {}",
        "try { for (;;) {} } catch (e) {}",
        "const spin = () => { try { spin(); } catch (e) { spin(); } }; spin();"
    ])
    func aRunawayProgramHitsTheTimeLimit(loop: String) {
        let started = Date()
        #expect(firstEffects(of: "beat(\"Hi.\"); " + loop) == [
            .cancelReply, .showNotch(.notice("The draw program took too long, so I stopped it."))
        ])
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test(arguments: [
        ("ring(1, 2, 3, 4);", "The draw program failed: Error: Call beat(line) before drawing."),
        ("const a = 1;", "The draw program had nothing to say."),
        ("beat(\"   \");", "The draw program failed: Error: beat(line) needs a line to say."),
        ("beat(\"Hi.\"); ring(1, 2, 3);", "The draw program failed: Error: ring needs four finite numbers."),
        ("beat(\"Hi.\"); arrow(1, 2, NaN, 4);", "The draw program failed: Error: arrow needs four finite numbers."),
        ("beat(\"Hi.\"); stroke([[1, 2]]);", "The draw program failed: Error: stroke needs at least 2 points, each [x, y]."),
        ("beat(\"Hi.\"); stroke([[1, 2], [3]]);", "The draw program failed: Error: stroke needs at least 2 points, each [x, y]."),
        ("beat(\"Hi.\"); text(\"\", 1, 2);", "The draw program failed: Error: text needs words, then x and y."),
        ("beat(\"Hi.\"); text(\"a\", 1, 2, -3);", "The draw program failed: Error: text's size must be a positive number."),
        ("for (let i = 0; i < 31; i++) beat(\"Hi.\");", "The draw program failed: Error: A draw program can have at most 30 beats."),
        ("beat(\"Hi.\"); for (let i = 0; i < 201; i++) ring(1, 2, 3, 4);",
         "The draw program failed: Error: A draw program can have at most 200 marks."),
        ("beat(\"Hi.\"); stroke(Array.from({ length: 501 }, (_, i) => [i, i]));",
         "The draw program failed: Error: A stroke can have at most 500 points."),
        ("beat(\"a\".repeat(301));", "The draw program failed: Error: A line can have at most 300 characters."),
        ("beat(\"Hi.\"); text(\"a\".repeat(201), 1, 2);", "The draw program failed: Error: Text can have at most 200 characters."),
        ("beat(\"Hi.\"", "The draw program failed: SyntaxError: Unexpected end of script"),
        ("throw new Error(\"nope\");", "The draw program failed: Error: nope")
    ])
    func aBrokenProgramShowsANoticeAndDrawsNothing(source: String, notice: String) {
        #expect(firstEffects(of: source) == [.cancelReply, .showNotch(.notice(notice))])
    }

    @Test func aProgramThatFailsWhenTheReplyEndsEndsTheTurnWithItsNotice() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("```draw\nring(1, 2, 3, 4);"))) == [])
        #expect(engine.handle(.provider(.completed)) == [
            .showNotch(.notice("The draw program failed: Error: Call beat(line) before drawing."))
        ])
        #expect(engine.state.turn == .idle)
    }

    @Test func aLinesWhitespaceIsCollapsedIntoOneSpokenLine() {
        #expect(firstEffects(of: "beat(\"  One\\n  line,\\tplease. \");") == [.speak("One line, please.", voice: .apple)])
    }

    @Test func thePromptsDrawExampleRunsAndDrawsEveryMark() throws {
        let example = try #require(TalkInstructions.system.firstMatch(of: /```draw\n[\s\S]*?\n```/)).output
        var engine = replyingEngine()
        let effects = play(String(example) + "\n", on: &engine)
        let spoken = effects.filter { if case .speak = $0 { true } else { false } }
        let drawn = effects.flatMap { effect -> [DrawMark<DisplayPoint>] in
            guard case .draw(let marks, _) = effect else { return [] }
            return marks
        }
        let marks = example.matches(of: /\b(?:stroke|arrow|ring|text)\(/).count
        #expect(spoken.count == example.matches(of: /beat\(/).count)
        #expect(drawn.count == marks)
        #expect(marks >= 3)
    }
}
