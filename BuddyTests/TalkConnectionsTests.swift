import BuddyCore
import Foundation
import Testing
@testable import Buddy

@MainActor
struct TalkConnectionsTests {
    @Test func directSignInsRouteByTheChoiceAndTheHubServesItsChosenProvider() throws {
        let suite = "dev.steven.buddy.tests.talkConnections.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connections = TalkConnections(defaults: defaults, loadConfiguration: { throw ConnectionError("no hub") })
        var changes = 0
        connections.onChange = { changes += 1 }

        #expect(!connections.selection.useProxy)
        #expect(connections.setup == .direct(.auto))
        connections.choose(.codex)
        #expect(connections.setup == .direct(.codex))
        #expect(connections.unavailableReason == nil)
        connections.useProxy(true)
        connections.chooseProvider(.codex)
        #expect(connections.setup == .proxied(.codex))
        #expect(connections.selection.model == "gpt-6.1-sol")
        connections.useProxy(false)
        #expect(connections.setup == .direct(.codex))
        #expect(changes == 4)

        connections.choose(.auto)
        let reopened = TalkConnections(defaults: defaults, loadConfiguration: { throw ConnectionError("no hub") })
        #expect(reopened.setup == .direct(.auto))
        #expect(reopened.selection.provider == .codex)
    }

    @Test func selectionSavedBeforeTheChoiceExistedStartsOnAuto() throws {
        let suite = "dev.steven.buddy.tests.talkConnections.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = #"{"useProxy":false,"provider":"codex","accountID":"","model":"gpt-6.1-sol"}"#
        defaults.set(Data(saved.utf8), forKey: "talkConnectionV1")

        let connections = TalkConnections(defaults: defaults, loadConfiguration: { throw ConnectionError("no hub") })
        #expect(connections.setup == .direct(.auto))
        #expect(connections.selection.provider == .codex)
    }

    @Test func eachProviderKeepsItsOwnAccountAndModelAcrossSwitchesAndRelaunches() throws {
        let suite = "dev.steven.buddy.tests.talkConnections.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"useProxy":true,"provider":"claude","accountID":"claude-work","model":"claude-opus-5-5"}"#.utf8),
                     forKey: "talkConnectionV1")
        let connections = TalkConnections(defaults: defaults, loadConfiguration: { throw ConnectionError("no hub") })

        connections.chooseProvider(.codex)
        #expect(connections.selection.accountID == "")
        #expect(connections.selection.model == "gpt-6.1-sol")
        connections.chooseProvider(.claude)
        #expect(connections.selection.accountID == "claude-work")
        #expect(connections.selection.model == "claude-opus-5-5")

        connections.chooseProvider(.codex)
        let reopened = TalkConnections(defaults: defaults, loadConfiguration: { throw ConnectionError("no hub") })
        #expect(reopened.selection.provider == .codex)
        reopened.chooseProvider(.claude)
        #expect(reopened.selection.accountID == "claude-work")
        #expect(reopened.selection.model == "claude-opus-5-5")
    }

    @Test func choosingTheProviderAlreadyChosenKeepsItsAccountAndModel() throws {
        let suite = "dev.steven.buddy.tests.talkConnections.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"useProxy":true,"provider":"codex","accountID":"codex-home","model":"gpt-6-luna"}"#.utf8),
                     forKey: "talkConnectionV1")
        let connections = TalkConnections(defaults: defaults, loadConfiguration: { throw ConnectionError("no hub") })
        var changes = 0
        connections.onChange = { changes += 1 }

        connections.chooseProvider(.codex)
        #expect(connections.selection.accountID == "codex-home")
        #expect(connections.selection.model == "gpt-6-luna")
        #expect(changes == 0)
    }
}
