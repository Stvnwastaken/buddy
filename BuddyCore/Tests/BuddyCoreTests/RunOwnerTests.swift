import Foundation
import Testing
import BuddyCore

private let folder = "/Users/owner/Library/Application Support/Buddy/Runs/1"
private let sendLunchEmail = #"osascript -e 'tell application "Mail" to send (make new outgoing message with properties {subject:"Lunch", content:"Noon?", visible:false})'"#
private let sendLunchEmailAsk = OwnerAsk.approval(
    id: "r1", action: sendLunchEmail, reason: "AppleScript `send` isn't on Buddy's read-only list."
)
private let confirmation = "On it. I'll work on that in the background."
private let passedOn = "Thanks, I'll pass that on to agent run 1."

private func runningEngine() -> BuddyEngine {
    var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) }, home: "/Users/owner")
    for event: BuddyEngine.Event in [
        .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("agent, email Sam about lunch"), .screensCaptured([]),
        .lineStarted, .lineFinished, .run(RunID(1), .started(folder: folder))
    ] { _ = engine.handle(event) }
    return engine
}

private func approval(_ id: String, _ command: String) -> BuddyEngine.Event {
    .run(RunID(1), .approvalRequested(id: id, .command(command)))
}

private func ask(_ call: Int, _ question: String, choices: [String] = []) -> BuddyEngine.Event {
    .run(RunID(1), .toolCalled(ToolCallID(call), .askOwner(question, choices: choices)))
}

private func answered(_ call: Int, _ text: String) -> BuddyEngine.Effect {
    .answerTool(ToolCallID(call), ToolAnswer(content: [.text(text)]))
}

private func passedOnSpoken(_ transcript: String) -> [BuddyEngine.Effect] {
    [.saveHistory(ConversationHistory(conversations: [Conversation(
        turns: [
            TurnRecord(transcript: "agent, email Sam about lunch", reply: confirmation),
            TurnRecord(transcript: transcript, reply: passedOn)
        ],
        lastActivity: Date(timeIntervalSince1970: 1_000)
    )])), .speak(passedOn, voice: .apple)]
}

struct RunOwnerTests {
    @Test func aRunThatWantsToSendAnEmailWaitsForTheOwnersApproval() {
        var engine = runningEngine()
        #expect(engine.handle(approval("r1", sendLunchEmail)) == [.playCue(.needsOwner)])
        #expect(engine.state.runs.first?.status == .needsOwner)
        #expect(engine.state.runs.first?.asks == [sendLunchEmailAsk])
        #expect(engine.handle(.runApprovalAnswered(RunID(1), request: "r1", approved: true)) == [
            .answerApproval(RunID(1), id: "r1", .allow)
        ])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.state.runs.first?.asks == [])
        #expect(engine.state.runs.first?.denials == [])
    }

    @Test func aDeniedRequestIsRecordedInTheRunNoteAndTheRunIsToldNotToRetry() {
        var engine = runningEngine()
        _ = engine.handle(.run(RunID(1), .toolCalled(ToolCallID(1), .updateRunNote("- [ ] Email Sam"))))
        _ = engine.handle(approval("r1", sendLunchEmail))
        #expect(engine.handle(.runApprovalAnswered(RunID(1), request: "r1", approved: false)) == [
            .saveRunNote(RunID(1), "- [ ] Email Sam\n\n## Denied\n- `\(sendLunchEmail)`: You said no.\n"),
            .answerApproval(RunID(1), id: "r1", .deny("Your owner said no. Don't retry it or work around it."))
        ])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.state.runs.first?.denials == [Denial(action: sendLunchEmail, reason: "You said no.")])
    }

    @Test func theCuePlaysOnceWhenTheRunStartsWaitingAndTheRunWaitsUntilEveryAskIsAnswered() {
        var engine = runningEngine()
        #expect(engine.handle(approval("r1", sendLunchEmail)) == [.playCue(.needsOwner)])
        #expect(engine.handle(ask(1, "Which address should I use for Sam?", choices: ["Work", "Home"])) == [])
        #expect(engine.state.runs.first?.asks == [
            sendLunchEmailAsk,
            .question(ToolCallID(1), "Which address should I use for Sam?", choices: ["Work", "Home"])
        ])
        #expect(engine.handle(.runQuestionAnswered(RunID(1), ToolCallID(1), "Work")) == [
            answered(1, "Your owner answered: Work")
        ])
        #expect(engine.state.runs.first?.status == .needsOwner)
        #expect(engine.state.runs.first?.asks == [sendLunchEmailAsk])
        #expect(engine.handle(.runApprovalAnswered(RunID(1), request: "r1", approved: true)) == [
            .answerApproval(RunID(1), id: "r1", .allow)
        ])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.handle(approval("r2", "curl -X POST https://api.example.com/posts")) == [.playCue(.needsOwner)])
        #expect(engine.state.runs.first?.status == .needsOwner)
    }

    @Test func aQuestionOffersItsChoicesTrimmedAndWithoutRepeats() {
        var engine = runningEngine()
        #expect(engine.handle(ask(1, "  Which Sam?\n", choices: [" Sam Lee ", "", "Sam Lee", "Sam Ortiz"])) == [.playCue(.needsOwner)])
        #expect(engine.state.runs.first?.asks == [.question(ToolCallID(1), "Which Sam?", choices: ["Sam Lee", "Sam Ortiz"])])
    }

    @Test func anEmptyQuestionIsAnErrorAndTheRunKeepsWorking() {
        var engine = runningEngine()
        #expect(engine.handle(ask(1, " \n ")) == [
            .answerTool(ToolCallID(1), ToolAnswer(content: [.text("There was no question to ask.")], isError: true))
        ])
        #expect(engine.state.runs.first?.status == .running)
        #expect(engine.state.runs.first?.asks == [])
    }

    @Test func theNextSpokenTurnAnswersTheOldestQuestionWithoutAskingTheProvider() {
        var engine = runningEngine()
        _ = engine.handle(approval("r1", sendLunchEmail))
        _ = engine.handle(ask(1, "What should the email say?"))
        _ = engine.handle(ask(2, "Should I copy Alex?", choices: ["Yes", "No"]))
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished("Ask if noon works for lunch.")) == [
            answered(1, "Your owner answered: Ask if noon works for lunch.")
        ] + passedOnSpoken("Ask if noon works for lunch."))
        #expect(engine.state.runs.first?.asks == [sendLunchEmailAsk, .question(ToolCallID(2), "Should I copy Alex?", choices: ["Yes", "No"])])
        #expect(engine.state.runs.first?.status == .needsOwner)
    }

    @Test func aTypedTurnAnswersTheQuestionToo() {
        var engine = runningEngine()
        _ = engine.handle(ask(1, "What should the email say?"))
        for event in controlDoubleTap { _ = engine.handle(event) }
        #expect(engine.handle(.textBoxSubmitted("Noon works?")) == [
            .hideTextBox, .showBuddy, .showNotch(.thinking), answered(1, "Your owner answered: Noon works?")
        ] + passedOnSpoken("Noon works?"))
        #expect(engine.state.runs.first?.status == .running)
    }

    @Test func aWaitingQuestionTakesTheYesBeforeARunOfferAndTheOfferIsUsedUp() {
        var engine = runningEngine()
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("rename my screenshots"))
        _ = engine.handle(.screensCaptured([]))
        _ = engine.handle(.provider(.textDelta("[RUN:Rename the screenshots by date] Want me to do that as an agent run?")))
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        #expect(engine.state.runOffer == RunBrief(request: "Rename the screenshots by date", captures: []))
        _ = engine.handle(ask(1, "Should I copy Alex?", choices: ["Yes", "No"]))
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        let effects = engine.handle(.transcriptFinished("yes"))
        #expect(effects.first == answered(1, "Your owner answered: yes"))
        #expect(effects.contains(.speak(passedOn, voice: .apple)))
        #expect(engine.state.runOffer == nil)
        #expect(engine.state.runs.first?.id == RunID(1))
        #expect(engine.state.runs.first?.status == .running)
    }

    @Test func aTurnWhileOnlyAnApprovalWaitsIsAnOrdinaryQuestion() {
        var engine = runningEngine()
        _ = engine.handle(approval("r1", sendLunchEmail))
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished("yes")) == [.captureScreens])
        #expect(engine.state.runs.first?.asks == [sendLunchEmailAsk])
    }

    @Test func stoppingAWaitingRunClearsWhatItAskedAndLateAnswersDoNothing() {
        var engine = runningEngine()
        _ = engine.handle(approval("r1", sendLunchEmail))
        _ = engine.handle(ask(1, "Which Sam?", choices: ["Sam Lee", "Sam Ortiz"]))
        #expect(engine.handle(.runStopRequested(RunID(1))) == [
            .stopRun(RunID(1)), .saveRunReport(RunID(1), "Asked: email Sam about lunch\n\nStopped by the owner.\n")
        ])
        #expect(engine.state.runs.first?.status == .stopped(.owner))
        #expect(engine.state.runs.first?.asks == [])
        #expect(engine.handle(.runApprovalAnswered(RunID(1), request: "r1", approved: true)) == [])
        #expect(engine.handle(.runQuestionAnswered(RunID(1), ToolCallID(1), "Sam Lee")) == [])
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        #expect(engine.handle(.transcriptFinished("Sam Lee")) == [.captureScreens])
    }

    @Test func aWaitingRunStillStopsAtItsTimeCap() {
        var engine = runningEngine()
        _ = engine.handle(ask(1, "Which Sam?"))
        #expect(engine.handle(.runTimeUp(RunID(1))) == [
            .stopRun(RunID(1)), .saveRunReport(RunID(1), "Asked: email Sam about lunch\n\nStopped at its time cap of 20 minutes.\n"),
            .playCue(.done)
        ])
        #expect(engine.state.runs.first?.asks == [])
    }

    @Test func answersForAnotherRunOrAnUnknownAskDoNothing() {
        var engine = runningEngine()
        _ = engine.handle(approval("r1", sendLunchEmail))
        _ = engine.handle(ask(1, "Which Sam?"))
        #expect(engine.handle(.runApprovalAnswered(RunID(2), request: "r1", approved: true)) == [])
        #expect(engine.handle(.runApprovalAnswered(RunID(1), request: "r9", approved: true)) == [])
        #expect(engine.handle(.runQuestionAnswered(RunID(1), ToolCallID(9), "Sam Lee")) == [])
        #expect(engine.handle(.runApprovalAnswered(RunID(1), request: "r1", approved: true)) == [
            .answerApproval(RunID(1), id: "r1", .allow)
        ])
        #expect(engine.handle(.runApprovalAnswered(RunID(1), request: "r1", approved: false)) == [])
        #expect(engine.state.runs.first?.asks == [.question(ToolCallID(1), "Which Sam?", choices: [])])
    }

    @Test func aWaitingRunCannotBeClosedAndASecondRunStartsBesideIt() {
        var engine = runningEngine()
        _ = engine.handle(ask(1, "Which Sam?"))
        _ = engine.handle(.runDismissed(RunID(1)))
        #expect(engine.state.runs.first?.status == .needsOwner)
        _ = engine.handle(.runQuestionAnswered(RunID(1), ToolCallID(1), "Sam Lee"))
        _ = engine.handle(approval("r1", sendLunchEmail))
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("agent, open Safari"))
        let effects = engine.handle(.screensCaptured([]))
        #expect(effects.contains(.startRun(RunID(2), RunBrief(request: "open Safari", captures: []), .claudeCode, .auto)))
        #expect(engine.state.runs.map(\.id) == [RunID(1), RunID(2)])
        #expect(engine.state.runs.map(\.status) == [.needsOwner, .running])
    }

    @Test func theBriefTellsTheRunToGetApprovalBeforeIrreversibleActionsAndHowToAsk() {
        #expect(RunInstructions.system(for: .auto).contains("Get your owner's approval before anything irreversible."))
        #expect(RunInstructions.system(for: .auto).contains("ask_owner asks your owner a question and waits for the answer."))
        #expect(!RunInstructions.system(for: .auto).contains("You can't ask your owner questions yet."))
    }

    @Test(arguments: ApprovalMode.allCases)
    func theBriefTellsTheRunToPreferScriptsAndToTakeOverTheScreenOnlyWithConsent(mode: ApprovalMode) {
        let instructions = RunInstructions.system(for: mode)
        #expect(!instructions.contains("You can't click or type in apps."))
        #expect(instructions.contains("Only for an app you can't drive that way, take over the screen."))
        #expect(instructions.contains("Call begin_takeover with a reason your owner can judge"))
        #expect(instructions.contains("Nothing moves until your owner allows it on your card."))
        #expect(instructions.contains("Capture the screen again after each action to check it worked."))
        #expect(instructions.contains("Call end_takeover as soon as you're done."))
    }
}
