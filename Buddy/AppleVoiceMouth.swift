import AVFoundation
import BuddyCore

final class AppleVoiceMouth: NSObject, Mouth, AVSpeechSynthesizerDelegate {
    private struct Line {
        let utterance: AVSpeechUtterance
        let onStarted: () -> Void
        let onFinished: () -> Void
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var current: Line?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The system synthesizer always speaks, so `onFailed` is never called.
    func speak(
        _ line: String,
        voice: Voice = .neural,
        speed: Double = 1,
        onStarted: @escaping () -> Void,
        onFinished: @escaping () -> Void,
        onFailed: @escaping () -> Void
    ) {
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
        current = Line(utterance: utterance, onStarted: onStarted, onFinished: onFinished)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The main queue keeps a line's start ahead of its end, which separate tasks would not promise.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        DispatchQueue.main.async { MainActor.assumeIsolated { self.started(utterance) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(utterance) } }
    }

    /// `stopSpeaking` has already let go of the line it cancels, so this only ends a line the system cut off.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(utterance) } }
    }

    private func started(_ utterance: AVSpeechUtterance) {
        guard let current, current.utterance === utterance else { return }
        current.onStarted()
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        guard let current, current.utterance === utterance else { return }
        self.current = nil
        current.onFinished()
    }
}
