import AVFoundation
import Observation
import os

/// How loud the microphone is right now, from 0 to 1, for the waveform.
@Observable
final class MicrophoneLevel {
    private(set) var value = 0.0

    func hear(_ loudness: Double) {
        value = max(loudness, value * 0.72)
    }

    func reset() {
        value = 0
    }
}

/// Talk's ears: SpeechAnalyzer once its model is installed, and upstream's Apple Speech recognizer until then or
/// when SpeechAnalyzer can't run on this Mac.
final class OnDeviceEars: Ears {
    private final class Listening {
        let onHeard: (String) -> Void
        let onTranscript: (String) -> Void
        let onFailure: (String) -> Void
        var session: (any BuddyStreamingTranscriptionSession)?
        var heard = ""
        var stopRequested = false
        var ended = false

        init(onHeard: @escaping (String) -> Void, onTranscript: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
            self.onHeard = onHeard
            self.onTranscript = onTranscript
            self.onFailure = onFailure
        }
    }

    private let speechAnalyzer = SpeechAnalyzerTranscriptionProvider()
    private let appleSpeech = AppleSpeechTranscriptionProvider()
    private let level: MicrophoneLevel
    private var onModelStatus: (SpeechModelStatus) -> Void = { _ in }
    private var microphone: AVAudioEngine?
    private var listening: Listening?

    init(level: MicrophoneLevel) {
        self.level = level
    }

    func prepare(onModelStatus: @escaping (SpeechModelStatus) -> Void) {
        self.onModelStatus = onModelStatus
        speechAnalyzer.prepare(onStatus: onModelStatus)
    }

    func startListening(
        onHeard: @escaping (String) -> Void,
        onTranscript: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        if let listening { end(listening) }
        // Levels the last push-to-talk's tap queued can land after its microphone stopped.
        level.reset()
        let listening = Listening(onHeard: onHeard, onTranscript: onTranscript, onFailure: onFailure)
        self.listening = listening
        let (provider, name): (any BuddyTranscriptionProvider, String) = speechAnalyzer.isReady
            ? (speechAnalyzer, "SpeechAnalyzer")
            : (appleSpeech, "Apple Speech")
        Logger.turnTiming.debug("listening with \(name, privacy: .public)")
        speechAnalyzer.prepare(onStatus: onModelStatus)
        Task {
            do {
                let session = try await provider.startStreamingSession(
                    onTranscriptUpdate: { [weak self] text in
                        Task { @MainActor in self?.update(heard: text, in: listening) }
                    },
                    onFinalTranscriptReady: { [weak self] text in
                        Task { @MainActor in self?.finalTranscript(text, in: listening) }
                    },
                    onError: { [weak self] error in
                        Task { @MainActor in self?.failed(error, in: listening) }
                    }
                )
                guard !listening.ended else {
                    session.cancel()
                    return
                }
                listening.session = session
                if listening.stopRequested {
                    requestFinalTranscript(for: listening)
                } else {
                    try startMicrophone(feeding: session)
                }
            } catch {
                failed(error, in: listening)
            }
        }
    }

    func stopListening() {
        guard let listening, !listening.stopRequested else { return }
        listening.stopRequested = true
        stopMicrophone()
        if listening.session != nil { requestFinalTranscript(for: listening) }
    }

    private func requestFinalTranscript(for listening: Listening) {
        guard let session = listening.session else { return }
        session.requestFinalTranscript()
        let fallbackDelay = session.finalTranscriptFallbackDelaySeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(fallbackDelay))
            self?.deliver(listening.heard, from: listening)
        }
    }

    private func update(heard text: String, in listening: Listening) {
        guard !listening.ended else { return }
        listening.heard = text
        listening.onHeard(text)
    }

    private func finalTranscript(_ text: String, in listening: Listening) {
        update(heard: text, in: listening)
        if listening.stopRequested { deliver(text, from: listening) }
    }

    private func failed(_ error: Error, in listening: Listening) {
        guard !listening.ended else { return }
        if listening.stopRequested {
            deliver(listening.heard, from: listening)
        } else {
            end(listening)
            listening.onFailure(error.localizedDescription)
        }
    }

    private func deliver(_ transcript: String, from listening: Listening) {
        guard !listening.ended else { return }
        end(listening)
        listening.onTranscript(transcript)
    }

    private func end(_ listening: Listening) {
        listening.ended = true
        listening.session?.cancel()
        if self.listening === listening {
            stopMicrophone()
            self.listening = nil
        }
    }

    private func startMicrophone(feeding session: any BuddyStreamingTranscriptionSession) throws {
        let microphone = microphone ?? AVAudioEngine()
        self.microphone = microphone
        let input = microphone.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable [level] buffer, _ in
            session.appendAudioBuffer(buffer)
            let loudness = buffer.loudness
            Task { @MainActor in level.hear(loudness) }
        }
        microphone.prepare()
        try microphone.start()
    }

    private func stopMicrophone() {
        guard let microphone else { return }
        microphone.stop()
        microphone.inputNode.removeTap(onBus: 0)
    }
}

private extension AVAudioPCMBuffer {
    /// The first channel's root mean square, scaled so speaking voice fills most of the range.
    nonisolated var loudness: Double {
        guard let samples = floatChannelData?[0], frameLength > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for index in 0..<Int(frameLength) {
            sumOfSquares += samples[index] * samples[index]
        }
        return Double(min(sqrt(sumOfSquares / Float(frameLength)) * 10.2, 1))
    }
}
