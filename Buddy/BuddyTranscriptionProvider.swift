import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    nonisolated func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

extension Locale {
    /// The language the owner speaks, taken from their preferred languages. `Locale.current` follows Buddy's
    /// English-only interface instead, so it would name English whatever the owner speaks.
    static var spoken: Locale {
        Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
    }
}

protocol BuddyTranscriptionProvider {
    func startStreamingSession(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}
