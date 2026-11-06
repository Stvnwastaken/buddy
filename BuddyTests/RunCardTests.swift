import AppKit
import BuddyCore
import Foundation
import Testing
@testable import Buddy

@MainActor
struct RunCardTests {
    private static let sendEmail = #"osascript -e 'tell application "Mail" to send (make new outgoing message with properties {subject:"Lunch", content:"Noon?", visible:false})'"#

    @Test func theCardsApproveDenyAndChoiceControlsSendTheOwnersAnswers() throws {
        var engine = BuddyEngine(providerConnected: true, home: "/Users/owner")
        for event: BuddyEngine.Event in [
            .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("agent, email Sam about lunch"), .screensCaptured([]),
            .run(RunID(1), .started(folder: "/tmp/buddy-run-card")),
            .run(RunID(1), .approvalRequested(id: "r1", .command(Self.sendEmail))),
            .run(RunID(1), .toolCalled(ToolCallID(4), .askOwner("Which Sam?", choices: ["Sam Lee", "Sam Ortiz"])))
        ] { _ = engine.handle(event) }
        let run = try #require(engine.state.runs.first)
        #expect(run.look == StatusLook(mark: .needsOwner, words: "Needs you", ending: nil))
        var sent: [BuddyEngine.Event] = []
        let card = DockPanel { sent.append($0) }.card(for: run)

        card.onApproval("r1", true)
        card.onApproval("r1", false)
        card.onChoice(ToolCallID(4), "Sam Ortiz")

        #expect(sent.map(String.init(describing:)) == [
            BuddyEngine.Event.runApprovalAnswered(RunID(1), request: "r1", approved: true),
            .runApprovalAnswered(RunID(1), request: "r1", approved: false),
            .runQuestionAnswered(RunID(1), ToolCallID(4), "Sam Ortiz")
        ].map(String.init(describing:)))
    }

    @Test func theCardsTakeoverControlsSendTheOwnersAnswer() throws {
        var engine = BuddyEngine(providerConnected: true, home: "/Users/owner")
        for event: BuddyEngine.Event in [
            .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("agent, rename the photos in Photo Booth"), .screensCaptured([]),
            .run(RunID(1), .started(folder: "/tmp/buddy-run-card")),
            .run(RunID(1), .toolCalled(ToolCallID(5), .beginTakeover(reason: "Photo Booth has no AppleScript.")))
        ] { _ = engine.handle(event) }
        let run = try #require(engine.state.runs.first)
        #expect(run.asks == [.takeover(ToolCallID(5), reason: "Photo Booth has no AppleScript.")])
        var sent: [BuddyEngine.Event] = []
        let card = DockPanel { sent.append($0) }.card(for: run)

        card.onTakeover(ToolCallID(5), false)
        card.onTakeover(ToolCallID(5), true)

        #expect(sent.map(String.init(describing:)) == [
            BuddyEngine.Event.runTakeoverAnswered(RunID(1), ToolCallID(5), approved: false),
            .runTakeoverAnswered(RunID(1), ToolCallID(5), approved: true)
        ].map(String.init(describing:)))
    }

    @Test func aRunHoldingTheScreenSaysSoOnItsCard() throws {
        var engine = BuddyEngine(providerConnected: true, home: "/Users/owner")
        for event: BuddyEngine.Event in [
            .permissionsObserved(PermissionSnapshot(accessibility: .granted)),
            .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("agent, rename the photos in Photo Booth"), .screensCaptured([]),
            .run(RunID(1), .started(folder: "/tmp/buddy-run-card")),
            .run(RunID(1), .toolCalled(ToolCallID(5), .beginTakeover(reason: "Photo Booth has no AppleScript."))),
            .runTakeoverAnswered(RunID(1), ToolCallID(5), approved: true)
        ] { _ = engine.handle(event) }
        let run = try #require(engine.state.runs.first)
        #expect(run.look == StatusLook(mark: .takingOver, words: "Using your screen", ending: nil))
    }

    @Test func eachCardInTheDockStopsOnlyItsOwnRun() throws {
        var engine = BuddyEngine(providerConnected: true, home: "/Users/owner")
        for request in ["agent, email Sam about lunch", "agent, rename the screenshots on my Desktop"] {
            for event: BuddyEngine.Event in [
                .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished(request), .screensCaptured([]),
                .lineStarted, .lineFinished
            ] { _ = engine.handle(event) }
        }
        _ = engine.handle(.run(RunID(2), .toolCalled(ToolCallID(1), .updateRunNote("# Rename screenshots\n- [ ] Find them"))))
        var sent: [BuddyEngine.Event] = []
        let dock = DockPanel { sent.append($0) }
        let cards = engine.state.runs.map { dock.card(for: $0, among: engine.state.runs.count) }
        #expect(cards.map(\.run.name) == ["Email Sam about lunch", "Rename screenshots"])
        #expect(cards.map(\.noteHeight) == [180, 180])

        cards[1].onStop()
        for event in sent { _ = engine.handle(event) }

        #expect(sent.map(String.init(describing:)) == [String(describing: BuddyEngine.Event.runStopRequested(RunID(2)))])
        #expect(engine.state.runs.map(\.status) == [.running, .stopped(.owner)])
        #expect(dock.card(for: try #require(engine.state.runs.first)).noteHeight == 320)
    }

    @Test func onlyTheCardWhoseQuestionTakesTheNextTurnInvitesASpokenAnswer() throws {
        var engine = BuddyEngine(providerConnected: true, home: "/Users/owner")
        for request in ["agent, email Sam about lunch", "agent, rename the screenshots on my Desktop"] {
            for event: BuddyEngine.Event in [
                .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished(request), .screensCaptured([]),
                .lineStarted, .lineFinished
            ] { _ = engine.handle(event) }
        }
        _ = engine.handle(.run(RunID(2), .toolCalled(ToolCallID(3), .askOwner("Should the date go first?", choices: []))))
        _ = engine.handle(.run(RunID(1), .toolCalled(ToolCallID(4), .askOwner("Which Sam?", choices: ["Sam Lee", "Sam Ortiz"]))))
        let next = try #require(engine.state.questionTakingNextTurn)
        let dock = DockPanel { _ in }
        let cards = engine.state.runs.map { dock.card(for: $0, among: 2, questionTakingNextTurn: next) }

        #expect(next == ToolCallID(3))
        #expect(cards[1].answerHint(for: ToolCallID(3), hasChoices: false)
            == "Answer out loud: hold control + option, or double-tap Control to type.")
        #expect(cards[0].answerHint(for: ToolCallID(4), hasChoices: true)
            == "Click a choice. An earlier question takes your next spoken or typed answer.")
        #expect(cards[0].answerHint(for: ToolCallID(5), hasChoices: false)
            == "An earlier question takes your next spoken or typed answer. Answer this one after it.")
        #expect(dock.card(for: engine.state.runs[0]).answerHint(for: ToolCallID(4), hasChoices: true)
            == "Or answer out loud: hold control + option, or double-tap Control to type.")
    }

    @Test func aScrollingDockMakesRoomForAScrollBarThatTakesSpace() {
        #expect(DockPanel.scrollerWidth(scrolls: true, style: .legacy) == 17)
        #expect(DockPanel.scrollerWidth(scrolls: true, style: .overlay) == 0)
        #expect(DockPanel.scrollerWidth(scrolls: false, style: .legacy) == 0)
    }

    @Test(arguments: [(RunCue.launch, 0.27), (.needsOwner, 0.43), (.done, 0.68)])
    func eachRunCueIsItsOwnShortWaveThatNeverClips(cue: RunCue, seconds: Double) {
        let wave = RunCues.wave(cue)
        let samples = wave.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(wave.prefix(4) == Data("RIFF".utf8))
        #expect(abs(Double(samples.count) / 44_100 - seconds) < 0.001)
        #expect(samples.allSatisfy { $0 > Int16.min + 1 && $0 < Int16.max })
    }
}
