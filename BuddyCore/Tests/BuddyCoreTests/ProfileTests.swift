import Foundation
import Testing
import BuddyCore

struct ProfileTests {
    @Test func rememberBeatAddsANoteAndSpeaksOnlyItsWords() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        ask("Remember that I like metric units.", on: &engine)
        #expect(engine.handle(.provider(.textDelta("[REMEMBER:Prefers metric units.] Got it, metric from now on.\n"))) == [
            .saveProfile(Profile(notes: ["Prefers metric units."])), .speak("Got it, metric from now on.", voice: .apple)
        ])
        #expect(engine.handle(.provider(.completed)) == [
            savedTurn(transcript: "Remember that I like metric units.", reply: "Got it, metric from now on.")
        ])
        #expect(engine.state.profile.markdown == "# About you\n\n- Prefers metric units.\n")
    }

    @Test func forgetBeatRemovesTheNoteWhateverItsCaseOrFinalPunctuation() {
        var engine = BuddyEngine(
            providerConnected: true, profile: Profile(notes: ["Prefers metric units.", "Has a cat named Miso."])
        )
        ask("Forget that I like metric.", on: &engine)
        #expect(engine.handle(.provider(.textDelta("[FORGET:prefers  metric units] Okay, I forgot that.\n"))) == [
            .saveProfile(Profile(notes: ["Has a cat named Miso."])), .speak("Okay, I forgot that.", voice: .apple)
        ])
    }

    @Test(arguments: [
        ("[REMEMBER:prefers metric units!] I already know that.", "I already know that."),
        ("[FORGET:Owns a boat.] I didn't have that noted.", "I didn't have that noted."),
        ("[REMEMBER:   ] Nothing to note.", "Nothing to note."),
        ("[FORGET:Prefers metric units.] [REMEMBER:Prefers metric units.] Still noted.", "Still noted.")
    ])
    func anEditThatChangesNothingSavesNothing(reply: String, spoken: String) {
        var engine = BuddyEngine(providerConnected: true, profile: Profile(notes: ["Prefers metric units."]))
        ask("Remember that.", on: &engine)
        #expect(engine.handle(.provider(.textDelta(reply + "\n"))) == [.speak(spoken, voice: .apple)])
        #expect(engine.state.profile == Profile(notes: ["Prefers metric units."]))
    }

    @Test func aTagHoldingAnotherTagIsSkipped() {
        var engine = BuddyEngine(providerConnected: true)
        ask("Remember that.", on: &engine)
        #expect(engine.handle(.provider(.textDelta("[REMEMBER:a [FORGET:b] Okay.\n"))) == [.speak("Okay.", voice: .apple)])
        #expect(engine.state.profile == Profile())
    }

    @Test func tagsOnTheirOwnLineOrAfterTheWordsStillEditTheProfile() {
        var engine = BuddyEngine(
            providerConnected: true, profile: Profile(notes: ["Lives in Oslo."]), now: { Date(timeIntervalSince1970: 1_000) }
        )
        ask("I moved to Bergen, and remember my dog is Pixel.", on: &engine)
        #expect(engine.handle(.provider(.textDelta("[FORGET:Lives in Oslo.] [REMEMBER:Lives in Bergen.]\n"))) == [
            .saveProfile(Profile(notes: ["Lives in Bergen."]))
        ])
        #expect(engine.handle(.provider(.textDelta("Noted, and Pixel too. [REMEMBER:Has a dog named Pixel.]"))) == [])
        #expect(engine.handle(.provider(.completed)) == [
            .saveProfile(Profile(notes: ["Lives in Bergen.", "Has a dog named Pixel."])),
            savedTurn(transcript: "I moved to Bergen, and remember my dog is Pixel.", reply: "Noted, and Pixel too."),
            .speak("Noted, and Pixel too.", voice: .apple)
        ])
    }

    @Test func aTagInTheMiddleOfALineEditsTheProfileAndIsNotSpoken() {
        var engine = BuddyEngine(providerConnected: true)
        ask("Remember I wake at 7:30.", on: &engine)
        #expect(engine.handle(.provider(.textDelta("Got it, [REMEMBER:Wakes at 7:30 on weekdays.] I'll keep that in mind.\n"))) == [
            .saveProfile(Profile(notes: ["Wakes at 7:30 on weekdays."])),
            .speak("Got it, I'll keep that in mind.", voice: .apple)
        ])
    }

    @Test func everyTurnCarriesTheProfileIncludingAnEditFromTheTurnBefore() {
        var engine = BuddyEngine(providerConnected: true, now: { Date(timeIntervalSince1970: 1_000) })
        #expect(ask("Hi.", on: &engine).first.flatMap(content(of:)) == [
            .text("Your owner's profile is empty. They haven't asked you to remember anything about them."),
            .text("The dock has no agent runs."),
            .text("Hi.")
        ])
        _ = engine.handle(.provider(.textDelta("[REMEMBER:Goes by Sam.] Hi Sam.")))
        _ = engine.handle(.provider(.completed))
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        #expect(ask("What do you remember about me?", on: &engine).first.flatMap(content(of:)) == [
            .text("Your owner's profile, the notes they asked you to remember about them:\n- Goes by Sam."),
            .text("The dock has no agent runs."),
            .text("Recent exchanges in this conversation (text only):\nOwner: Hi.\nBuddy: Hi Sam."),
            .text("What do you remember about me?")
        ])
    }

    @Test func agentRunBeatsNeverChangeTheProfile() {
        var engine = BuddyEngine(providerConnected: true)
        _ = ask("agent tidy my desktop", on: &engine)
        _ = engine.handle(.lineStarted)
        _ = engine.handle(.lineFinished)
        let call = ToolCallID(1)
        #expect(engine.handle(.run(RunID(1), .toolCalled(call, .showBeats("[REMEMBER:Likes a tidy desktop.] All tidy.")))) == [
            .showBuddy, .speak("All tidy.", voice: .apple), .answerTool(call, ToolAnswer(content: [.text("Showing 1 line.")]))
        ])
        #expect(engine.state.profile == Profile())
    }

    @Test func clearingTheProfileEmptiesItAndReportsTheResult() {
        var engine = BuddyEngine(providerConnected: true, profile: Profile(notes: ["Goes by Sam."]))
        #expect(engine.handle(.clearProfileRequested) == [.clearProfile])
        #expect(engine.state.profile == Profile())
        #expect(engine.handle(.clearProfileRequested) == [])
        #expect(engine.handle(.profileCleared(error: nil)) == [])
        #expect(engine.state.profileCleared)
        #expect(engine.state.profileClearPending == false)

        ask("Remember I go by Sam.", on: &engine)
        #expect(engine.state.profileCleared == false)

        _ = engine.handle(.clearProfileRequested)
        _ = engine.handle(.profileCleared(error: nil))
        #expect(engine.state.profileCleared)
        _ = engine.handle(.provider(.textDelta("[REMEMBER:Goes by Sam.] Got it.\n")))
        #expect(engine.state.profileCleared == false)
        #expect(engine.state.profile == Profile(notes: ["Goes by Sam."]))
    }

    @Test func profileStorageErrorsStayInSettingsUntilASuccessfulClear() {
        var engine = BuddyEngine(providerConnected: true)
        #expect(engine.handle(.profileFailed("Profile couldn't be saved. Disk full.")) == [
            .showNotch(.notice("Profile couldn't be saved. Disk full."))
        ])
        #expect(engine.handle(.noticeExpired) == [.hideBuddy, .showNotch(.idle)])
        #expect(engine.state.profileError == "Profile couldn't be saved. Disk full.")
        _ = engine.handle(.clearProfileRequested)
        #expect(engine.handle(.profileCleared(error: "Profile couldn't be cleared. Locked.")) == [
            .showNotch(.notice("Profile couldn't be cleared. Locked."))
        ])
        #expect(engine.state.profileError == "Profile couldn't be cleared. Locked.")
        #expect(engine.state.profileCleared == false)
        _ = engine.handle(.clearProfileRequested)
        _ = engine.handle(.profileCleared(error: nil))
        #expect(engine.state.profileError == nil)
        #expect(engine.state.profileCleared)
    }

    @Test func theProfileDocumentKeepsOnlyItsBullets() {
        let profile = Profile(markdown: "# About you\n\nSome prose.\n- Prefers metric units.\n* Has a cat named Miso.\n-not a bullet\n- \n")
        #expect(profile == Profile(notes: ["Prefers metric units.", "Has a cat named Miso."]))
        #expect(profile.markdown == "# About you\n\n- Prefers metric units.\n- Has a cat named Miso.\n")
        #expect(Profile(markdown: Profile().markdown) == Profile())
    }
}

@discardableResult
private func ask(_ question: String, on engine: inout BuddyEngine) -> [BuddyEngine.Effect] {
    _ = engine.handle(.pushToTalkPressed)
    _ = engine.handle(.pushToTalkReleased)
    _ = engine.handle(.transcriptFinished(question))
    return engine.handle(.screensCaptured([]))
}

private func content(of effect: BuddyEngine.Effect) -> [TurnContent]? {
    guard case .sendTurn(let request) = effect else { return nil }
    return request.content
}
