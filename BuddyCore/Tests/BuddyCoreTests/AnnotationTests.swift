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
    jpeg: Data([2]), display: leftMonitor.display,
    pixelWidth: 1280, pixelHeight: 720, containsCursor: true
)
private let laptopWithoutCursor = ScreenCapture(
    jpeg: Data([1]), display: laptop.display,
    pixelWidth: 1280, pixelHeight: 800, containsCursor: false
)

private let ringAroundSave = BuddyEngine.Effect.annotate(
    .shape(.ring, from: DisplayPoint(x: 675, y: 472.5), to: DisplayPoint(x: 765, y: 427.5)), on: laptop.display
)

private func replyingEngine(
    screens: [ScreenCapture] = [laptop], profile: Profile = Profile(),
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000) }
) -> BuddyEngine {
    var engine = BuddyEngine(providerConnected: true, profile: profile, now: now)
    let start: [BuddyEngine.Event] = [.pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("help"), .screensCaptured(screens)]
    for event in start { _ = engine.handle(event) }
    return engine
}

private func effectsOfReply(_ reply: String, screens: [ScreenCapture] = [laptop]) -> [BuddyEngine.Effect] {
    var engine = replyingEngine(screens: screens)
    #expect(engine.handle(.provider(.textDelta(reply))) == [])
    return engine.handle(.provider(.completed)) + engine.handle(.lineStarted)
}

private func spoken(_ words: String, marking marks: [BuddyEngine.Effect]) -> [BuddyEngine.Effect] {
    [savedTurn(transcript: "help", reply: words), .speak(words, voice: .apple), .showNotch(.line(words))] + marks
}

struct AnnotationTests {
    @Test(arguments: [
        ("[ARROW:800,480,640,400] Click the gear.", "Click the gear.",
         .shape(.arrow, from: DisplayPoint(x: 900, y: 360), to: DisplayPoint(x: 720, y: 450))),
        ("Drag from here [LINE:80,160,400,160] to there.", "Drag from here to there.",
         .shape(.line, from: DisplayPoint(x: 90, y: 720), to: DisplayPoint(x: 450, y: 720))),
        ("Click Save. [RING:600, 380, 680, 420]", "Click Save.",
         .shape(.ring, from: DisplayPoint(x: 675, y: 472.5), to: DisplayPoint(x: 765, y: 427.5))),
        ("Type your name [UNDERLINE:120,200,360,224] in this field.", "Type your name in this field.",
         .shape(.underline, from: DisplayPoint(x: 135, y: 675), to: DisplayPoint(x: 405, y: 648))),
        ("[HIGHLIGHT:0,0,1280,40] That's the menu bar.", "That's the menu bar.",
         .shape(.highlight, from: DisplayPoint(x: 0, y: 900), to: DisplayPoint(x: 1440, y: 855))),
        ("Press [LABEL:640,400:  Save here ] the button.", "Press the button.",
         .label("Save here", at: DisplayPoint(x: 720, y: 450)))
    ] as [(String, String, Annotation<DisplayPoint>)])
    func everyTagKindDrawsItsMarkAsItsLineStarts(reply: String, words: String, annotation: Annotation<DisplayPoint>) {
        #expect(effectsOfReply(reply) == spoken(words, marking: [.annotate(annotation, on: laptop.display)]))
    }

    @Test(arguments: [
        ("Click the [RING:600,380,680,420]Save button.", "Click the Save button."),
        ("Click Save[RING:600,380,680,420].", "Click Save."),
        ("Click[RING:600,380,680,420] Save.", "Click Save."),
        ("[RING:600,380,680,420]Click Save.", "Click Save."),
        ("Click [TARGET:1,2][RING:600,380,680,420]Save.", "Click Save."),
        ("Use [esc:now]here. [RING:600,380,680,420]", "Use [esc:now]here."),
        ("Click ([RING:600,380,680,420]Save).", "Click (Save)."),
        ("It's in Save[RING:600,380,680,420]'s menu.", "It's in Save's menu."),
        ("Click [ARROW:1,2]Save [RING:600,380,680,420] [POINT:none]2.", "Click Save 2.")
    ])
    func cuttingATagLeavesOneSpaceBetweenWords(reply: String, words: String) {
        #expect(effectsOfReply(reply) == spoken(words, marking: [ringAroundSave]))
    }

    @Test(arguments: [
        ("Click [TARGET:640,400] Save. [RING:600,380,680,420]", "Click Save."),
        ("[TYPE:hello] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[TYPE:640,400] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[TYPE:640,400:  ] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[TYPE:640,400:screen2] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[TARGET:600,380,680] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[TARGET:600,380,680,420:Save] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[ARROW:800,480,640] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[ARROW:800,480,640,400,5,6] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[LABEL:640,400,12:Save] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[POINT:640,400,12:save] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("Click [LINE:a,b,c,d] Save. [RING:600,380,680,420]", "Click Save."),
        ("Click [RING:1.5,2,3,4] Save. [RING:600,380,680,420]", "Click Save."),
        ("[ARROW:-5,2,3,4] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[RING:] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[LABEL:640,400] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[LABEL:640,400:  ] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[POINT:640,400:] Click Save [RING:600,380,680,420].", "Click Save."),
        ("[UNDERLINE:120,200,360,224:screenB] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[LABEL:640,400:Save:screen] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[POINT:screen2] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[HIGHLIGHT:0,0,1280,40:menu bar] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("[POINT:640,400:save:here] Click Save. [RING:600,380,680,420]", "Click Save."),
        ("Press [Return] or [esc:now] to finish. [RING:600,380,680,420]", "Press [Return] or [esc:now] to finish.")
    ])
    func malformedTagsAreSkippedAndTheRestOfTheLineStillWorks(reply: String, words: String) {
        #expect(effectsOfReply(reply) == spoken(words, marking: [ringAroundSave]))
    }

    @Test(arguments: [
        ("Look here. [RING:640,360,700,400:screen2]", [laptop, leftMonitor], [
            .annotate(.shape(.ring, from: DisplayPoint(x: -960, y: 720), to: DisplayPoint(x: -870, y: 660)), on: leftMonitor.display)
        ]),
        ("Look here. [ARROW:800,480,640,400]", [laptop, leftMonitor], [
            .annotate(.shape(.arrow, from: DisplayPoint(x: 900, y: 360), to: DisplayPoint(x: 720, y: 450)), on: laptop.display)
        ]),
        ("Look here. [ARROW:800,480,640,400]", [leftMonitorWithCursor, laptopWithoutCursor], [
            .annotate(.shape(.arrow, from: DisplayPoint(x: -720, y: 540), to: DisplayPoint(x: -960, y: 660)), on: leftMonitor.display)
        ]),
        ("Look here. [ARROW:800,480,640,400]", [laptopWithoutCursor, leftMonitorWithCursor], [
            .annotate(.shape(.arrow, from: DisplayPoint(x: -720, y: 540), to: DisplayPoint(x: -960, y: 660)), on: leftMonitor.display)
        ]),
        ("Look here. [LINE:80,160,400,160:screen2]", [leftMonitorWithCursor, laptopWithoutCursor], [
            .annotate(.shape(.line, from: DisplayPoint(x: 90, y: 720), to: DisplayPoint(x: 450, y: 720)), on: laptop.display)
        ]),
        ("Look here. [LABEL:640,400:Save:screen3]", [laptop, leftMonitor], [
            .annotate(.label("Save", at: DisplayPoint(x: 720, y: 450)), on: laptop.display)
        ]),
        ("Look here. [UNDERLINE:1200,780,1400,900]", [laptop], [
            .annotate(.shape(.underline, from: DisplayPoint(x: 1350, y: 22.5), to: DisplayPoint(x: 1440, y: 0)), on: laptop.display)
        ]),
        ("[POINT:640,360:Finder:screen2] Look here [RING:600,380,680,420].", [laptop, leftMonitor], [
            .point(DisplayPoint(x: -960, y: 720), on: leftMonitor.display, label: "Finder"),
            ringAroundSave
        ])
    ] as [(String, [ScreenCapture], [BuddyEngine.Effect])])
    func marksLandOnTheScreenTheyNameElseTheCursorScreen(reply: String, screens: [ScreenCapture], marks: [BuddyEngine.Effect]) {
        #expect(effectsOfReply(reply, screens: screens) == spoken("Look here.", marking: marks))
    }

    @Test func eachLinesMarksFireWhenTheMouthStartsThatLine() {
        var engine = replyingEngine(screens: [laptop, leftMonitor])
        #expect(engine.handle(.provider(.textDelta(
            "[RING:72,0,112,24] Open the [POINT:92,11:File menu] File menu [ARROW:300,100,200,60].\n"
                + "Pick New Folder.\n[LABEL:640,360:Finder:screen2] It opens here.\n"
        ))) == [.speak("Open the File menu.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("Open the File menu.")),
            .point(DisplayPoint(x: 103.5, y: 887.625), on: laptop.display, label: "File menu"),
            .annotate(.shape(.ring, from: DisplayPoint(x: 81, y: 900), to: DisplayPoint(x: 126, y: 873)), on: laptop.display),
            .annotate(.shape(.arrow, from: DisplayPoint(x: 337.5, y: 787.5), to: DisplayPoint(x: 225, y: 832.5)), on: laptop.display)
        ])
        #expect(engine.handle(.lineStarted) == [])
        #expect(engine.handle(.lineFinished) == [.speak("Pick New Folder.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Pick New Folder."))])
        #expect(engine.handle(.lineFinished) == [.speak("It opens here.", voice: .apple)])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "help", reply: "Open the File menu.\nPick New Folder.\nIt opens here.")
        ])
        #expect(engine.handle(.lineStarted) == [
            .showNotch(.line("It opens here.")),
            .annotate(.label("Finder", at: DisplayPoint(x: -960, y: 720)), on: leftMonitor.display)
        ])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
    }

    @Test(arguments: [false, true])
    func marksWaitForTheVoiceToStartIncludingAfterNeuralFallback(neuralFails: Bool) {
        var engine = replyingEngine()
        #expect(engine.handle(.neuralVoiceObserved(.ready)) == [])
        #expect(engine.handle(.provider(.textDelta("[RING:600,380,680,420] Click Save.\n"))) == [
            .speak("Click Save.", voice: .neural)
        ])
        if neuralFails {
            #expect(engine.handle(.lineFailed) == [.speak("Click Save.", voice: .apple)])
        }
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Click Save.")), ringAroundSave])
        #expect(engine.handle(.lineStarted) == [])
        #expect(engine.handle(.provider(.completed)) == [savedTurn(transcript: "help", reply: "Click Save.")])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.handle(.interrupted) == [.clearAnnotations, .showNotch(.idle)])
    }

    @Test(arguments: [
        ([.provider(.textDelta("[RING:600,380,680,420] Click Save.\nThen")), .lineStarted], BuddyEngine.Event.pushToTalkPressed,
         [BuddyEngine.Effect.cancelReply, .stopSpeaking, .clearAnnotations, .showNotch(.listening(heard: "")), .startListening]),
        ([.provider(.textDelta("[RING:600,380,680,420] Click Save.\nThen")), .lineStarted], .interrupted,
         [.cancelReply, .stopSpeaking, .clearAnnotations, .hideBuddy, .showNotch(.idle)]),
        ([.provider(.textDelta("[RING:600,380,680,420] Click Save.\nThen"))], .pushToTalkPressed,
         [.cancelReply, .stopSpeaking, .showNotch(.listening(heard: "")), .startListening]),
        ([.provider(.textDelta("[RING:600,380,680,420] Click Save.")), .provider(.completed), .lineStarted, .lineFinished],
         .pushToTalkPressed, [.clearAnnotations, .showNotch(.listening(heard: "")), .startListening]),
        ([.provider(.textDelta("Click Save.")), .provider(.completed), .lineStarted, .lineFinished],
         .pushToTalkPressed, [.showNotch(.listening(heard: "")), .startListening]),
        ([.provider(.textDelta("[RING:600,380,680,420] Click Save.")), .provider(.completed), .lineStarted, .lineFinished],
         .interrupted, [.clearAnnotations, .showNotch(.idle)]),
        ([.provider(.textDelta("Click Save.")), .provider(.completed), .lineStarted, .lineFinished],
         .interrupted, [.showNotch(.idle)]),
        ([.provider(.textDelta("[RING:600,380,680,420] Click Save.\nThen")), .lineStarted], .clearHistoryRequested,
         [.cancelReply, .stopSpeaking, .clearAnnotations, .cancelCapture, .resetProvider, .hideBuddy, .showNotch(.idle),
          .clearHistory]),
        ([.provider(.textDelta("[RING:600,380,680,420] Click Save.")), .provider(.completed), .lineStarted, .lineFinished],
         .clearHistoryRequested,
         [.clearAnnotations, .cancelCapture, .resetProvider, .hideBuddy, .showNotch(.idle), .clearHistory]),
        ([.provider(.textDelta("Click Save.")), .provider(.completed), .lineStarted, .lineFinished],
         .clearHistoryRequested, [.cancelCapture, .resetProvider, .hideBuddy, .showNotch(.idle), .clearHistory])
    ] as [([BuddyEngine.Event], BuddyEngine.Event, [BuddyEngine.Effect])])
    func marksClearOnTheNextTurnEscapeOrClearingHistory(
        before: [BuddyEngine.Event], event: BuddyEngine.Event, expected: [BuddyEngine.Effect]
    ) {
        var engine = replyingEngine()
        for earlier in before { _ = engine.handle(earlier) }
        #expect(engine.handle(event) == expected)
    }

    @Test func marksStayAfterTheReplyUntilTheNextTurnStarts() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("[RING:600,380,680,420] Click Save."))) == [])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "help", reply: "Click Save."), .speak("Click Save.", voice: .apple)
        ])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Click Save.")), ringAroundSave])
        #expect(engine.handle(.lineFinished) == [.hideBuddy, .showNotch(.closing)])
        #expect(engine.handle(.pushToTalkPressed) == [.clearAnnotations, .showNotch(.listening(heard: "")), .startListening])
        let nextTurn: [BuddyEngine.Event] = [
            .pushToTalkReleased, .transcriptFinished("thanks"), .screensCaptured([laptop]),
            .provider(.textDelta("You're welcome.")), .provider(.completed), .lineStarted, .lineFinished
        ]
        #expect(nextTurn.flatMap { engine.handle($0) } == [
            .stopListening, .showBuddy, .showNotch(.thinking), .captureScreens,
            .sendTurn(TurnRequest(
                transcript: "thanks", captures: [laptop], recentTurns: [TurnRecord(transcript: "help", reply: "Click Save.")]
            )),
            .saveHistory(ConversationHistory(conversations: [Conversation(
                turns: [TurnRecord(transcript: "help", reply: "Click Save."), TurnRecord(transcript: "thanks", reply: "You're welcome.")],
                lastActivity: Date(timeIntervalSince1970: 1_000)
            )])),
            .speak("You're welcome.", voice: .apple),
            .showNotch(.line("You're welcome.")),
            .hideBuddy, .showNotch(.closing)
        ])
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: "")), .startListening])
    }

    @Test func escapeWhileIdleClearsTheMarksOnceWithoutKeepingTheConversationAlive() {
        let clock = ConversationClock()
        var engine = replyingEngine(now: { clock.now })
        let reply: [BuddyEngine.Event] = [
            .provider(.textDelta("[LABEL:640,400:Save] Click Save.")), .provider(.completed), .lineStarted, .lineFinished
        ]
        #expect(reply.flatMap { engine.handle($0) } == [
            savedTurn(transcript: "help", reply: "Click Save."), .speak("Click Save.", voice: .apple),
            .showNotch(.line("Click Save.")),
            .annotate(.label("Save", at: DisplayPoint(x: 720, y: 450)), on: laptop.display),
            .hideBuddy, .showNotch(.closing)
        ])
        clock.set(1_540)
        #expect(engine.handle(.interrupted) == [.clearAnnotations, .showNotch(.idle)])
        #expect(engine.handle(.interrupted) == [])
        clock.set(1_700)
        #expect(engine.handle(.pushToTalkPressed) == [
            .resetProvider,
            .saveHistory(ConversationHistory(conversations: [Conversation(
                turns: [TurnRecord(transcript: "help", reply: "Click Save.")],
                lastActivity: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_700)
            )])),
            .showNotch(.listening(heard: "")), .startListening,
            .writeSummary(SummaryRequest(id: 1, conversation: 0, summary: nil, turns: [TurnRecord(transcript: "help", reply: "Click Save.")]))
        ])
    }

    @Test func providerFailureAndItsNoticeLeaveTheMarksUp() {
        var engine = replyingEngine()
        #expect(engine.handle(.provider(.textDelta("[RING:600,380,680,420] Click Save.\n"))) == [.speak("Click Save.", voice: .apple)])
        #expect(engine.handle(.lineStarted) == [.showNotch(.line("Click Save.")), ringAroundSave])
        #expect(engine.handle(.provider(.failed(.error("API Error: 529 Overloaded"))))
            == [.stopSpeaking, .showNotch(.notice("Claude Code failed: API Error: 529 Overloaded"))])
        #expect(engine.handle(.noticeExpired) == [.hideBuddy, .showNotch(.idle)])
        #expect(engine.handle(.interrupted) == [.clearAnnotations])
    }

    @Test func everyTagInThePromptsExamplesFiresAndNoneIsSpoken() {
        let examples = TalkInstructions.system.components(separatedBy: "Examples:\n")[1]
        let replies = examples.split(separator: "\n").reduce(into: [[Substring]]()) { replies, line in
            if line.hasSuffix(" ->") { replies.append([]) } else { replies[replies.count - 1].append(line) }
        }
        #expect(!replies.isEmpty)
        for reply in replies {
            let text = reply.joined(separator: "\n")
            var engine = replyingEngine(screens: [laptop, leftMonitor], profile: Profile(notes: ["Lives in Oslo."]))
            _ = engine.handle(.permissionsObserved(PermissionSnapshot(accessibility: .granted)))
            var effects = engine.handle(.provider(.textDelta(text))) + engine.handle(.provider(.completed))
            for _ in reply {
                effects += engine.handle(.lineStarted) + engine.handle(.lineFinished)
                let target = effects.last { effect in
                    if case .annotate(.shape(.ring, _, _), _) = effect { true } else { false }
                }
                if case .annotate(.shape(.ring, let from, let to), _) = target {
                    effects += engine.handle(.clicked(DisplayPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)))
                }
            }
            let spoken = effects.compactMap { effect -> String? in
                guard case .speak(let line, _, _) = effect else { return nil }
                return line
            }
            let fired = effects.filter { effect in
                switch effect {
                case .point, .annotate, .type, .saveProfile: true
                default: false
                }
            }
            #expect(spoken.count == reply.count, "\(text)")
            #expect(!spoken.contains { $0.contains("[") }, "\(text)")
            let offers = text.ranges(of: "[RUN:").count
            #expect(fired.count + offers == text.count(where: { $0 == "[" }), "\(text)")
            #expect((engine.state.runOffer != nil) == (offers > 0), "\(text)")
        }
    }

    @Test(arguments: [1, 2, 3, 5, 8, 21, 1_000])
    func annotationTagsSplitAcrossDeltasProduceTheSameEffects(chunkSize: Int) {
        let text = "[RING:72,0,112,24] Open the [POINT:92,11:File menu] File menu.\r\n[ARROW:300, 100, 200, 60]\n"
            + "Pick [TARGET:1,2] New Folder [LABEL:140,58: New Folder :screen2].\n"
            + "  [UNDERLINE:120,200,360,224] [HIGHLIGHT:0,0,1280,40] That's it.  "
        let reply = Array(text.unicodeScalars)
        let deltas = stride(from: 0, to: reply.count, by: chunkSize).map { start in
            reply[start..<min(start + chunkSize, reply.count)].reduce(into: "") { $0.unicodeScalars.append($1) }
        }
        var engine = replyingEngine(screens: [laptop, leftMonitor])
        #expect(deltas.flatMap { engine.handle(.provider(.textDelta($0))) } == [.speak("Open the File menu.", voice: .apple)])
        let rest: [BuddyEngine.Event] = [.provider(.completed)] + Array(repeating: [.lineStarted, .lineFinished], count: 3).flatMap { $0 }
        #expect(rest.flatMap { engine.handle($0) } == [
            savedTurn(transcript: "help", reply: "Open the File menu.\nPick New Folder.\nThat's it."),
            .showNotch(.line("Open the File menu.")),
            .point(DisplayPoint(x: 103.5, y: 887.625), on: laptop.display, label: "File menu"),
            .annotate(.shape(.ring, from: DisplayPoint(x: 81, y: 900), to: DisplayPoint(x: 126, y: 873)), on: laptop.display),
            .speak("Pick New Folder.", voice: .apple),
            .showNotch(.line("Pick New Folder.")),
            .annotate(.label("New Folder", at: DisplayPoint(x: -1710, y: 1173)), on: leftMonitor.display),
            .speak("That's it.", voice: .apple),
            .showNotch(.line("That's it.")),
            .annotate(.shape(.underline, from: DisplayPoint(x: 135, y: 675), to: DisplayPoint(x: 405, y: 648)), on: laptop.display),
            .annotate(.shape(.highlight, from: DisplayPoint(x: 0, y: 900), to: DisplayPoint(x: 1440, y: 855)), on: laptop.display),
            .hideBuddy, .showNotch(.closing)
        ])
    }
}
