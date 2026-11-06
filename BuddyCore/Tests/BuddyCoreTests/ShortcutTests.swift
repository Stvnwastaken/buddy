import BuddyCore
import Foundation
import Testing

struct ShortcutTests {
    @Test func theDefaultTalkComboListensUntilReleased() {
        var engine = BuddyEngine(providerConnected: true)
        #expect(engine.handle(.modifiersChanged(.control, at: .milliseconds(0))) == [])
        #expect(engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(20))) == [
            .showNotch(.listening(heard: "")), .startListening
        ])
        #expect(engine.state.turn == .held)
        #expect(engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(30))) == [])
        #expect(engine.handle(.modifiersChanged(.control, at: .milliseconds(100))) == [
            .stopListening, .showBuddy, .showNotch(.thinking)
        ])
        #expect(engine.handle(.modifiersChanged([], at: .milliseconds(120))) == [])
        #expect(engine.state.turn == .transcribing)
    }

    @Test func rebindingTalkSavesTheChoiceAndUsesItImmediatelyAndAfterLaunch() {
        var engine = BuddyEngine(providerConnected: true)
        let saved = Data(#"{"talk":{"kind":"held","modifiers":6},"textBox":{"kind":"doubleTap","modifiers":1}}"#.utf8)
        #expect(engine.handle(.shortcutChosen(.talk, .held([.option, .shift]))) == [.saveShortcuts(saved)])
        #expect(engine.state.shortcutError == nil)
        #expect(engine.state.shortcuts[.talk] == .held([.option, .shift]))
        #expect(engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(0))) == [])
        #expect(engine.handle(.modifiersChanged([], at: .milliseconds(100))) == [])
        #expect(engine.handle(.modifiersChanged([.option, .shift], at: .milliseconds(200))) == [
            .showNotch(.listening(heard: "")), .startListening
        ])

        var relaunched = BuddyEngine(providerConnected: true, shortcutData: saved)
        #expect(relaunched.state.shortcuts[.talk] == .held([.option, .shift]))
        #expect(relaunched.handle(.modifiersChanged([.option, .shift], at: .milliseconds(0))) == [
            .showNotch(.listening(heard: "")), .startListening
        ])
    }

    @Test func assigningTheTextBoxModifierToHeldTalkIsRejectedWithoutChangingOrSaving() {
        var engine = BuddyEngine(providerConnected: true)
        #expect(engine.handle(.shortcutChosen(.talk, .held(.control))) == [])
        #expect(engine.state.shortcutError == "That shortcut conflicts with Text box. Choose different modifiers.")
        #expect(engine.state.shortcuts[.talk] == .held([.control, .option]))
        #expect(controlDoubleTap.flatMap { engine.handle($0) } == [.hideBuddy, .showTextBox])
    }

    @Test func bothSlotsCanChangeTriggerKindAndTalkDoubleTapStartsThenSends() {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.shortcutChosen(.textBox, .held([.shift, .command])))
        _ = engine.handle(.shortcutChosen(.talk, .doubleTap(.option)))
        #expect(controlDoubleTap.flatMap { engine.handle($0) } == [])
        let optionTaps: [BuddyEngine.Event] = [
            .modifiersChanged(.option, at: .milliseconds(1000)), .modifiersChanged([], at: .milliseconds(1100)),
            .modifiersChanged(.option, at: .milliseconds(1250)), .modifiersChanged([], at: .milliseconds(1350))
        ]
        #expect(optionTaps.flatMap { engine.handle($0) } == [.showNotch(.listening(heard: "")), .startListening])
        #expect(engine.state.turn == .held)
        let laterOptionTaps: [BuddyEngine.Event] = [
            .modifiersChanged(.option, at: .milliseconds(1500)), .modifiersChanged([], at: .milliseconds(1600)),
            .modifiersChanged(.option, at: .milliseconds(1750)), .modifiersChanged([], at: .milliseconds(1850))
        ]
        #expect(laterOptionTaps.flatMap { engine.handle($0) } == [.stopListening, .showBuddy, .showNotch(.thinking)])
        #expect(engine.state.turn == .transcribing)
        #expect(engine.handle(.modifiersChanged([.shift, .command], at: .milliseconds(2000))) == [
            .hideBuddy, .showNotch(.idle), .showTextBox
        ])
        #expect(engine.handle(.modifiersChanged([], at: .milliseconds(2100))) == [])
        #expect(engine.state.turn == .typing)
        #expect(engine.state.notchConversation.isOpen == true)
        #expect(engine.state.notchConversation.focused == true)
        #expect(engine.handle(.modifiersChanged([.shift, .command], at: .milliseconds(2200))) == [.hideTextBox])
        #expect(engine.state.notchConversation.isOpen == false)
        #expect(engine.state.notchConversation.focused == false)
    }

    @Test(arguments: [ModifierKeys(), ModifierKeys(rawValue: 32), ModifierKeys(rawValue: -1)])
    func invalidHeldCombosAreRejected(keys: ModifierKeys) {
        var engine = BuddyEngine()
        #expect(engine.handle(.shortcutChosen(.talk, .held(keys))) == [])
        #expect(engine.state.shortcutError == "Choose one or more of Control, Option, Shift, Command or fn.")
        #expect(engine.state.shortcuts[.talk] == .held([.control, .option]))
    }

    @Test func rebindingEitherSlotDuringTalkCancelsListeningAndOldReleasesDoNothing() {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(0)))
        let saved = Data(#"{"talk":{"kind":"held","modifiers":3},"textBox":{"kind":"doubleTap","modifiers":8}}"#.utf8)
        #expect(engine.handle(.shortcutChosen(.textBox, .doubleTap(.command))) == [
            .stopListening, .hideBuddy, .showNotch(.idle), .saveShortcuts(saved)
        ])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(.modifiersChanged(.control, at: .milliseconds(100))) == [])
        #expect(engine.handle(.modifiersChanged([], at: .milliseconds(120))) == [])
        #expect(engine.handle(.transcriptFinished("stale words")) == [])
    }

    @Test(arguments: [ModifierKeys.control, [.control, .option], [.control, .option, .shift]])
    func overlappingHeldSlotsAreRejected(keys: ModifierKeys) {
        var engine = BuddyEngine()
        #expect(engine.handle(.shortcutChosen(.textBox, .held(keys))) == [])
        #expect(engine.state.shortcutError == "That shortcut conflicts with Talk. Choose different modifiers.")
        #expect(engine.state.shortcuts[.textBox] == .doubleTap(.control))
    }

    @Test func escapeSeparatesDoubleTaps() {
        var engine = BuddyEngine(providerConnected: true)
        #expect(controlTap(at: 0).flatMap { engine.handle($0) } == [])
        #expect(engine.handle(.interrupted) == [])
        #expect(controlTap(at: 200).flatMap { engine.handle($0) } == [])
        #expect(engine.state.turn == .idle)
    }

    @Test func addingAnUnrelatedModifierCancelsTalkUntilAllKeysAreReleased() {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(0)))
        #expect(engine.handle(.modifiersChanged([.control, .option, .shift], at: .milliseconds(50))) == [
            .stopListening, .hideBuddy, .showNotch(.idle)
        ])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(100))) == [])
        #expect(engine.handle(.modifiersChanged(.control, at: .milliseconds(120))) == [])
        #expect(engine.handle(.modifiersChanged([], at: .milliseconds(150))) == [])
        #expect(engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(200))) == [
            .showNotch(.listening(heard: "")), .startListening
        ])
    }

    @Test(arguments: [
        "invalid JSON",
        #"{"talk":{"kind":"held","modifiers":0},"textBox":{"kind":"doubleTap","modifiers":1}}"#,
        #"{"talk":{"kind":"held","modifiers":32},"textBox":{"kind":"doubleTap","modifiers":1}}"#,
        #"{"talk":{"kind":"held","modifiers":1},"textBox":{"kind":"doubleTap","modifiers":1}}"#
    ])
    func invalidSavedChoicesRestoreDefaultsWithAnExplanation(json: String) {
        let engine = BuddyEngine(shortcutData: Data(json.utf8))
        #expect(engine.state.shortcuts[.talk] == .held([.control, .option]))
        #expect(engine.state.shortcuts[.textBox] == .doubleTap(.control))
        #expect(engine.state.shortcutError == "Saved shortcuts couldn't be loaded. Using the defaults.")
    }

    @Test func permissionLossDiscardsPendingTapsAndRequiresAFreshHeldGesture() {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.permissionsObserved(.init(inputMonitoring: .granted)))
        _ = engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(0)))
        #expect(engine.handle(.permissionsObserved(.init(inputMonitoring: .notGranted))) == [
            .stopListening, .hideBuddy, .showNotch(.idle)
        ])
        _ = engine.handle(.permissionsObserved(.init(inputMonitoring: .granted)))
        #expect(engine.handle(.modifiersChanged([], at: .milliseconds(100))) == [])
        #expect(engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(200))) == [
            .showNotch(.listening(heard: "")), .startListening
        ])

        var taps = BuddyEngine(providerConnected: true)
        _ = taps.handle(.permissionsObserved(.init(inputMonitoring: .granted)))
        _ = controlTap(at: 0).flatMap { taps.handle($0) }
        _ = taps.handle(.permissionsObserved(.init(inputMonitoring: .notGranted)))
        _ = taps.handle(.permissionsObserved(.init(inputMonitoring: .granted)))
        #expect(controlTap(at: 200).flatMap { taps.handle($0) } == [])
    }

    @Test(arguments: [BuddyEngine.Event.keyOrButtonPressed, .clicked(DisplayPoint(x: 10, y: 20))])
    func otherInputDuringAHoldCancelsInsteadOfSendingAndDoesNotRestart(event: BuddyEngine.Event) {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(0)))
        #expect(engine.handle(event) == [.stopListening, .hideBuddy, .showNotch(.idle)])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(.modifiersChanged(.control, at: .milliseconds(100))) == [])
        #expect(engine.handle(.modifiersChanged([], at: .milliseconds(120))) == [])
    }

    @Test func secureInputSpoilsDoubleTapsButStillAllowsHeldTalk() {
        var engine = BuddyEngine(providerConnected: true)
        let taps: [BuddyEngine.Event] = [
            .modifiersChanged(.control, at: .milliseconds(0), tapsAllowed: false),
            .modifiersChanged([], at: .milliseconds(100), tapsAllowed: false),
            .modifiersChanged(.control, at: .milliseconds(250), tapsAllowed: false),
            .modifiersChanged([], at: .milliseconds(350), tapsAllowed: false)
        ]
        #expect(taps.flatMap { engine.handle($0) } == [])
        #expect(engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(500), tapsAllowed: false)) == [
            .showNotch(.listening(heard: "")), .startListening
        ])
        #expect(engine.handle(.modifiersChanged([], at: .milliseconds(700), tapsAllowed: false)) == [
            .stopListening, .showBuddy, .showNotch(.thinking)
        ])
    }

    @Test func theFirstDoubleTapAfterFullyReleasingTalkOpensTheTextBox() {
        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.modifiersChanged(.control, at: .milliseconds(0)))
        _ = engine.handle(.modifiersChanged([.control, .option], at: .milliseconds(30)))
        _ = engine.handle(.modifiersChanged(.control, at: .milliseconds(200)))
        _ = engine.handle(.modifiersChanged([], at: .milliseconds(260)))
        #expect(engine.handle(.transcriptFinished("")) == [.hideBuddy, .showNotch(.idle)])
        #expect(controlTap(at: 1_000).flatMap { engine.handle($0) } == [])
        #expect(controlTap(at: 1_250).flatMap { engine.handle($0) } == [.hideBuddy, .showTextBox])
        #expect(engine.state.turn == .typing)
    }
}
