import Foundation
import Testing
import BuddyCore

private let now = Date(timeIntervalSince1970: 1_793_500_000)
private let inAnHour = now.addingTimeInterval(3_600)
private let aMinuteAgo = now.addingTimeInterval(-60)
private let laptop = ScreenCapture(
    jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
    pixelWidth: 1280, pixelHeight: 800, containsCursor: true
)
private let question = TurnRequest(transcript: "where's save?", captures: [laptop])

private func spent(_ fiveHour: Double?, _ sevenDay: Double?, resetting: Date = inAnHour) -> ProviderUsage {
    ProviderUsage(
        fiveHour: fiveHour.map { UsageWindow(utilization: $0, resetsAt: resetting) },
        sevenDay: sevenDay.map { UsageWindow(utilization: $0, resetsAt: now.addingTimeInterval(86_400)) }
    )
}

private func engine(_ setup: TalkSetup = .direct(.auto), usage: UsageSnapshots = .init()) -> BuddyEngine {
    BuddyEngine(providerConnected: true, talkSetup: setup, usage: usage, now: { now })
}

private func asking(_ transcript: String = "where's save?", on engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
    _ = engine.handle(.pushToTalkPressed)
    _ = engine.handle(.pushToTalkReleased)
    _ = engine.handle(.transcriptFinished(transcript))
    return engine.handle(.screensCaptured([laptop]))
}

private func answering(_ reply: String, on engine: inout BuddyEngine) {
    _ = engine.handle(.provider(.textDelta(reply)))
    _ = engine.handle(.provider(.completed))
    _ = engine.handle(.interrupted)
}

struct HeadroomTests {
    @Test func headroomIsOneMinusTheHigherWindow() {
        #expect(spent(0.30, 0.60).headroom(at: now) == 0.4)
        #expect(spent(0.86, nil).headroom(at: now) == 0.14)
        #expect(spent(nil, nil).headroom(at: now) == nil)
    }

    @Test func turnLeavesOnlyWhenTheOtherProviderLeadsByFifteenPoints() {
        var buddy = engine(usage: UsageSnapshots(claude: spent(0.30, 0.60), codex: spent(0.46, 0.10)))
        #expect(asking(on: &buddy) == [.sendTurn(question)])
        #expect(buddy.state.provider == .claude)

        let leading = spent(0.45, 0.10)
        #expect(buddy.handle(.usageReported(.codex, leading)) == [
            .saveUsage(UsageSnapshots(claude: spent(0.30, 0.60), codex: leading))
        ])
        #expect(buddy.state.provider == .claude)
        _ = buddy.handle(.interrupted)
        #expect(asking(on: &buddy) == [.leaveProvider(.claude), .sendTurn(question)])
        #expect(buddy.state.provider == .codex)
    }

    @Test func tieStaysOnWhicheverProviderIsCurrent() {
        let even = UsageSnapshots(claude: spent(0.50, 0.20), codex: spent(0.20, 0.50))
        var buddy = engine(usage: even)
        #expect(asking(on: &buddy) == [.sendTurn(question)])
        #expect(buddy.state.provider == .claude)

        var onCodex = engine(.direct(.codex), usage: even)
        #expect(onCodex.handle(.talkSetupChosen(.direct(.auto))) == [])
        #expect(asking(on: &onCodex) == [.sendTurn(question)])
        #expect(onCodex.state.provider == .codex)
    }

    @Test func reachedLimitSwitchesAtOnceEvenToAProviderWithLessHeadroom() {
        var buddy = engine(usage: UsageSnapshots(claude: spent(0.97, 0.40), codex: spent(0.90, 0.30)))
        #expect(asking(on: &buddy) == [.sendTurn(question)])

        let limited = spent(1, 0.41)
        #expect(buddy.handle(.usageReported(.claude, limited)) == [
            .saveUsage(UsageSnapshots(claude: limited, codex: spent(0.90, 0.30)))
        ])
        _ = buddy.handle(.interrupted)
        #expect(asking(on: &buddy) == [.leaveProvider(.claude), .sendTurn(question)])
        #expect(buddy.state.provider == .codex)
    }

    @Test func turnRefusedForTheLimitGoesToTheOtherProvider() {
        var buddy = engine(usage: UsageSnapshots(claude: spent(0.50, 0.40), codex: spent(0.60, 0.20)))
        #expect(asking(on: &buddy) == [.sendTurn(question)])

        #expect(buddy.handle(.provider(.failed(.limitReached))) == [
            .saveUsage(UsageSnapshots(claude: spent(1, 0.40), codex: spent(0.60, 0.20))),
            .leaveProvider(.claude),
            .sendTurn(question)
        ])
        #expect(buddy.state.provider == .codex)
        #expect(buddy.handle(.provider(.textDelta("Top right.\n"))) == [.speak("Top right.", voice: .apple)])
    }

    @Test func refusalWithNoLiveWindowCountsTheFiveHourWindowFullForFiveHours() {
        var buddy = engine(usage: UsageSnapshots(codex: spent(0.10, nil)))
        _ = asking(on: &buddy)
        _ = buddy.handle(.provider(.failed(.limitReached)))
        let fiveHoursOut = UsageWindow(utilization: 1, resetsAt: now.addingTimeInterval(18_000))
        #expect(buddy.state.usage.claude == ProviderUsage(fiveHour: fiveHoursOut, sevenDay: nil))
        #expect(buddy.state.provider == .codex)
    }

    @Test func refusalOnBothProvidersEndsTheTurnWithANotice() {
        var buddy = engine(usage: UsageSnapshots(claude: spent(0.50, 0.40), codex: spent(1, 0.20)))
        _ = asking(on: &buddy)
        #expect(buddy.handle(.provider(.failed(.limitReached))) == [
            .saveUsage(UsageSnapshots(claude: spent(1, 0.40), codex: spent(1, 0.20))),
            .showNotch(.notice("Claude Code reached its usage limit. Try again after it resets."))
        ])
        #expect(buddy.state.provider == .claude)
    }

    @Test func refusalAfterTheReplyStartedTalkingIsNotAskedAgain() {
        var buddy = engine(usage: UsageSnapshots(claude: spent(0.50, 0.40), codex: spent(0.60, 0.20)))
        _ = asking(on: &buddy)
        _ = buddy.handle(.provider(.textDelta("Top right.\n")))
        #expect(buddy.handle(.provider(.failed(.limitReached))) == [
            .saveUsage(UsageSnapshots(claude: spent(1, 0.40), codex: spent(0.60, 0.20))),
            .stopSpeaking,
            .showNotch(.notice("Claude Code reached its usage limit. Try again after it resets."))
        ])
        #expect(buddy.state.provider == .claude)
    }

    @Test func forcedProviderAlwaysWins() {
        var buddy = engine(.direct(.claude), usage: UsageSnapshots(claude: spent(0.90, 0.40), codex: spent(0.05, 0.05)))
        #expect(asking(on: &buddy) == [.sendTurn(question)])
        #expect(buddy.handle(.provider(.failed(.limitReached))) == [
            .saveUsage(UsageSnapshots(claude: spent(1, 0.40), codex: spent(0.05, 0.05))),
            .showNotch(.notice("Claude Code reached its usage limit. Try again after it resets."))
        ])
        #expect(buddy.state.provider == .claude)

        #expect(buddy.handle(.talkSetupChosen(.direct(.codex))) == [])
        #expect(buddy.state.provider == .codex)
        #expect(buddy.handle(.talkSetupChosen(.direct(.auto))) == [])
        #expect(buddy.state.provider == .codex)
    }

    @Test func throughTheHubTheChosenProviderAnswersAndNoUsageIsRecorded() {
        var buddy = engine(.proxied(.codex), usage: UsageSnapshots(codex: spent(1, 0.20)))
        #expect(buddy.state.provider == .codex)
        #expect(buddy.handle(.usageReported(.claude, spent(0.10, 0.10))) == [])
        #expect(asking(on: &buddy) == [.sendTurn(question)])
        #expect(buddy.handle(.provider(.failed(.limitReached))) == [
            .showNotch(.notice("Claude Code reached its usage limit. Try again after it resets."))
        ])
        #expect(buddy.state.usage == UsageSnapshots(codex: spent(1, 0.20)))
    }

    @Test func windowWhoseResetHasPassedCountsAsUnused() {
        let stale = spent(0.95, 0.25, resetting: aMinuteAgo)
        #expect(stale.headroom(at: now) == 0.75)
        var buddy = engine(.direct(.codex), usage: UsageSnapshots(claude: stale, codex: spent(0.50, 0.10)))
        #expect(buddy.handle(.talkSetupChosen(.direct(.auto))) == [])
        #expect(buddy.state.provider == .claude)
        #expect(asking(on: &buddy) == [.sendTurn(question)])

        var pastLimit = engine(usage: UsageSnapshots(claude: spent(1, 0.20, resetting: aMinuteAgo), codex: spent(0.10, 0.10)))
        #expect(asking(on: &pastLimit) == [.sendTurn(question)])
        #expect(pastLimit.state.provider == .claude)
    }

    @Test func unknownUsageNeverShowsALead() {
        var neither = engine()
        #expect(asking(on: &neither) == [.sendTurn(question)])
        #expect(neither.state.provider == .claude)

        var codexOnly = engine(usage: UsageSnapshots(codex: spent(0.05, 0.05)))
        #expect(asking(on: &codexOnly) == [.sendTurn(question)])
        #expect(codexOnly.state.provider == .claude)

        var claudeOnly = engine(.direct(.codex), usage: UsageSnapshots(claude: spent(0.05, 0.05)))
        _ = claudeOnly.handle(.talkSetupChosen(.direct(.auto)))
        #expect(asking(on: &claudeOnly) == [.sendTurn(question)])
        #expect(claudeOnly.state.provider == .codex)

        var limitedBesideUnknown = engine(usage: UsageSnapshots(claude: spent(1, 0.30)))
        #expect(limitedBesideUnknown.state.provider == .codex)
        #expect(asking(on: &limitedBesideUnknown) == [.sendTurn(question)])
    }

    @Test func launchAndReportsBetweenTurnsMoveToWhereTheNextTurnGoes() {
        let lowClaude = spent(0.95, 0.40)
        var launched = engine(usage: UsageSnapshots(claude: lowClaude, codex: spent(nil, 0.30)))
        #expect(launched.state.provider == .codex)
        #expect(asking(on: &launched) == [.sendTurn(question)])

        var startup = engine(usage: UsageSnapshots(claude: lowClaude))
        #expect(startup.state.provider == .claude)
        #expect(startup.handle(.usageReported(.codex, spent(nil, 0.30))) == [
            .saveUsage(UsageSnapshots(claude: lowClaude, codex: spent(nil, 0.30))),
            .leaveProvider(.claude)
        ])
        #expect(startup.state.provider == .codex)
        #expect(asking(on: &startup) == [.sendTurn(question)])
    }

    @Test func resetPassingWhileIdleMovesAtOnce() {
        let clock = ConversationClock()
        clock.set(now.timeIntervalSince1970)
        let snapshots = UsageSnapshots(claude: spent(1, 0.20), codex: spent(0.60, 0.10, resetting: now.addingTimeInterval(7_200)))
        var resetting = BuddyEngine(providerConnected: true, usage: snapshots, now: { clock.now })
        #expect(resetting.state.provider == .codex)
        #expect(resetting.handle(.clockTick) == [])
        clock.set(inAnHour.timeIntervalSince1970)
        #expect(resetting.handle(.clockTick) == [.leaveProvider(.codex)])
        #expect(resetting.state.provider == .claude)
    }

    @Test func savedSnapshotsReadBackTheSame() throws {
        let saved = UsageSnapshots(claude: spent(0.30, 0.60), codex: spent(nil, 0.13))
        #expect(try JSONDecoder().decode(UsageSnapshots.self, from: JSONEncoder().encode(saved)) == saved)
    }

    @Test func latestSnapshotIsSavedOnlyWhenItChanges() {
        var buddy = engine()
        #expect(buddy.handle(.usageReported(.codex, spent(0.14, nil))) == [.saveUsage(UsageSnapshots(codex: spent(0.14, nil)))])
        #expect(buddy.handle(.usageReported(.codex, spent(0.14, nil))) == [])
        #expect(buddy.state.usage == UsageSnapshots(codex: spent(0.14, nil)))
    }

    @Test func conversationThatMovesIsPrimedWithItsRecentTurns() {
        var buddy = engine(usage: UsageSnapshots(claude: spent(0.20, 0.20), codex: spent(0.20, 0.20)))
        #expect(asking(on: &buddy) == [.sendTurn(question)])
        answering("Top right.", on: &buddy)
        let first = TurnRecord(transcript: "where's save?", reply: "Top right.")

        #expect(buddy.handle(.usageReported(.claude, spent(0.40, 0.20))) == [
            .saveUsage(UsageSnapshots(claude: spent(0.40, 0.20), codex: spent(0.20, 0.20))),
            .leaveProvider(.claude)
        ])
        #expect(asking("and undo?", on: &buddy) == [
            .sendTurn(TurnRequest(transcript: "and undo?", captures: [laptop], recentTurns: [first]))
        ])
        answering("Edit menu.", on: &buddy)
        let second = TurnRecord(transcript: "and undo?", reply: "Edit menu.")

        #expect(buddy.handle(.usageReported(.codex, spent(0.60, 0.20))) == [
            .saveUsage(UsageSnapshots(claude: spent(0.40, 0.20), codex: spent(0.60, 0.20))),
            .leaveProvider(.codex)
        ])
        #expect(asking("and redo?", on: &buddy) == [
            .sendTurn(TurnRequest(transcript: "and redo?", captures: [laptop], recentTurns: [first, second]))
        ])
        #expect(buddy.state.provider == .claude)
    }
}
