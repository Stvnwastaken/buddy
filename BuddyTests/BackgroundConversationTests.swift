import AppKit
import BuddyCore
import Testing
@testable import Buddy

private struct EmptyConversationScreen: Screen {
    func captureAll() async throws -> [ScreenCapture] { [] }
}

@MainActor
private final class DelayedConversationBrain: Brain {
    var request: TurnRequest?
    var cancellations = 0
    private var onEvent: ((ProviderEvent) -> Void)?

    func start() {}
    func send(_ turn: TurnRequest, onEvent: @escaping (ProviderEvent) -> Void) {
        request = turn
        self.onEvent = onEvent
    }
    func emit(_ event: ProviderEvent) { onEvent?(event) }
    func cancelReply() { cancellations += 1 }
    func endConversation() {}
    func stop() {}
}

@MainActor
extension NotchPanelTests {
    @Test(arguments: [false, true])
    func aDelayedReplyFinishesAndSavesAfterLeavingAndReturningToTheNotch(returnToComposer: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buddy-background-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "dev.steven.buddy.tests.background.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        preferences.set(false, forKey: "spokenReplies")
        preferences.set(Data(#"{"useProxy":false,"provider":"codex","accountID":"","model":"","choice":"codex"}"#.utf8),
                        forKey: "talkConnectionV1")
        let connections = TalkConnections(defaults: preferences, loadConfiguration: { throw ConnectionError("No test hub") })
        var strip: NotchStrip?
        let notch = NotchPanel(microphone: MicrophoneLevel(), observesEnvironment: false,
                               onConversationObservation: { strip = $0.strip })
        let brain = DelayedConversationBrain()
        let historyURL = root.appending(path: "history.json")
        let manager = CompanionManager(historyURL: historyURL, profileURL: root.appending(path: "profile.md"),
                                       preferences: preferences, codexScreenshotRoot: root.appending(path: "screens"),
                                       screen: EmptyConversationScreen(), notch: notch, brain: brain, connections: connections)
        notch.start { manager.send($0) }
        defer { manager.stop() }

        manager.send(.notchPointerChanged(true))
        manager.send(.textBoxFocused)
        manager.send(.textBoxSubmitted("What color are the kite's wings?"))
        for _ in 0..<100 where brain.request == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(brain.request?.transcript == "What color are the kite's wings?")
        try #require(brain.request != nil)
        brain.emit(.searching)
        manager.send(.notchPointerChanged(false))
        manager.send(.textBoxDismissed)
        #expect(manager.state.notchConversation.isOpen == false)
        func waitUntilThinking() async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while strip != .thinking && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(strip == .thinking)
        }
        try await waitUntilThinking()
        #expect(brain.cancellations == 0)

        if returnToComposer {
            manager.send(.textBoxFocused)
            manager.send(.textBoxChanged("My next question"))
            manager.send(.conversationsRequested)
            #expect(manager.state.notchConversation.focused == false)
            manager.send(.conversationThreadRequested)
            manager.send(.textBoxDismissed)
        }
        brain.emit(.textDelta("Its wings are gold.\n"))
        try await waitUntilThinking()
        brain.emit(.completed)
        #expect(strip != .thinking)
        #expect(brain.cancellations == 0)
        #expect(manager.state.turn == .idle)
        #expect(manager.state.notchConversation.entries == [
            .owner("What color are the kite's wings?"), .buddy("Let me look that up."), .buddy("Its wings are gold.")
        ])
        #expect(try HistoryStore(url: historyURL).load().conversations.last?.turns == [
            TurnRecord(transcript: "What color are the kite's wings?", reply: "Its wings are gold.")
        ])
        if returnToComposer { #expect(manager.state.notchConversation.draft == "My next question") }
    }
}
