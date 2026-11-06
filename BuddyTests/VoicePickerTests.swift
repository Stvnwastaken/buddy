import AppKit
import BuddyCore
import BuddyVoice
import SwiftUI
import Testing
@testable import Buddy

@MainActor
struct VoicePickerAdapterTests {
    @Test func settingsPersistThroughANewManager() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "voice-picker-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "dev.steven.buddy.tests.voice.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func manager() -> CompanionManager {
            CompanionManager(historyURL: root.appending(path: "history.json"), profileURL: root.appending(path: "profile.md"),
                             preferences: preferences, codexScreenshotRoot: root.appending(path: "screenshots"))
        }
        let first = manager()
        first.send(.speechSettingsChanged(SpeechSettings(voice: .apple, speed: 1.5)))
        #expect(preferences.data(forKey: "speechSettingsV1") == Data(#"{"speed":1.5,"voice":{"apple":{}}}"#.utf8))
        let reopened = manager()
        #expect(reopened.state.speechSettings == SpeechSettings(voice: .apple, speed: 1.5))
    }

    @Test func onlyLocalKnownPacksAreListedAndRemovalIsObserved() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "voice-packs-\(UUID())")
        let packs = root.appending(path: "kokoro-82m-coreml/ANE")
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["af_heart", "am_adam", "unknown"] { try Data([1]).write(to: packs.appending(path: "\(name).bin")) }
        #expect(NeuralVoice.installedVoices(in: root) == [.neural, .kokoro("am_adam")])
        try FileManager.default.removeItem(at: packs.appending(path: "am_adam.bin"))
        #expect(NeuralVoice.installedVoices(in: root) == [.neural])
    }

    @Test func missingVoiceFilesFailBeforeSynthesis() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "voice-missing-\(UUID())")
        #expect(NeuralVoice.installedVoices(in: root) == [])
        let voice = NeuralVoice(folder: root)
        await #expect(throws: NeuralVoice.LoadError.notInstalled) { try await voice.load() }
        await #expect(throws: NeuralVoice.LoadError.notInstalled) { try await voice.wav(for: "Hello.", voice: "am_adam") }
        #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_VOICE_EVIDENCE"] != nil))
    func renderOwnedSettingsAndWriteLocalPreviewsWithoutPlayback() async throws {
        let root = URL(filePath: try #require(ProcessInfo.processInfo.environment["BUDDY_VOICE_EVIDENCE"]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "dev.steven.buddy.tests.voice.render.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let manager = CompanionManager(historyURL: root.appending(path: "history.json"), profileURL: root.appending(path: "profile.md"),
                                       preferences: preferences, codexScreenshotRoot: root.appending(path: "screenshots"))
        manager.send(.voicesObserved([.neural, .kokoro("am_adam")]))
        manager.send(.neuralVoiceObserved(.ready))
        manager.send(.speechSettingsChanged(SpeechSettings(voice: .apple, speed: 1.5)))
        for width in [336, 380] {
            let host = NSHostingView(rootView: CompanionPanelView(manager: manager).voiceSettings.padding(16).background(DS.Colors.background))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appending(path: "settings-\(width).png"))
            window.close()
        }
        let voices = NeuralVoice.installedVoices()
        guard !voices.isEmpty else {
            print("VOICE_EVIDENCE no installed Kokoro packs; rendered fixture only")
            return
        }
        let voice = NeuralVoice()
        try await voice.load()
        for choice in voices {
            for speed in [0.75, 1.5] {
                let wav = try await voice.wav(for: "Hello. I'm Buddy, your buddy on your Mac.", voice: try #require(choice.kokoroID), speed: speed)
                #expect(wav.count > 44)
                try wav.write(to: root.appending(path: "\(try #require(choice.kokoroID))-\(speed).wav"))
            }
        }
        print("VOICE_EVIDENCE rendered widths 336,380; synthesized \(voices.count) installed voices at 0.75,1.5; no playback")
    }
}
