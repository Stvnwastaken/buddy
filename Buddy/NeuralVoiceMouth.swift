import AVFoundation
import BuddyCore
import BuddyVoice
import os

/// Speaks with the neural voice. A line is synthesized whole before it plays, so its start is reported when its sound
/// starts, and a line that can't be synthesized or played is reported as failed instead.
final class NeuralVoiceMouth: NSObject, Mouth, AVAudioPlayerDelegate {
    private struct Line {
        let id: Int
        let onStarted: () -> Void
        let onFinished: () -> Void
        let onFailed: () -> Void
        let synthesis: Task<Void, Never>
        var player: AVAudioPlayer?
    }

    private enum PlaybackError: Error { case didNotStart }

    private let voice: NeuralVoice

    init(voice: NeuralVoice = NeuralVoice()) {
        self.voice = voice
        super.init()
    }
    private var current: Line?
    private var lastLineID = 0

    /// Loads the model in the background and reports whether the neural voice can speak.
    func prepare(onStatus: @escaping (NeuralVoiceStatus) -> Void) {
        Task { [voice] in
            do {
                try await voice.load()
                onStatus(.ready)
            } catch NeuralVoice.LoadError.notInstalled {
                onStatus(.notInstalled)
            } catch {
                onStatus(.failed(error.localizedDescription))
            }
        }
    }

    func speak(
        _ line: String,
        voice: Voice = .neural,
        speed: Double = 1,
        onStarted: @escaping () -> Void,
        onFinished: @escaping () -> Void,
        onFailed: @escaping () -> Void
    ) {
        stopSpeaking()
        lastLineID += 1
        let id = lastLineID
        let selectedVoice = voice.kokoroID ?? "af_heart"
        let synthesis = Task { [weak self, voice = self.voice] in
            do {
                self?.play(try await voice.wav(for: line, voice: selectedVoice, speed: speed), line: id)
            } catch {
                self?.fail(line: id, because: error)
            }
        }
        current = Line(id: id, onStarted: onStarted, onFinished: onFinished, onFailed: onFailed, synthesis: synthesis)
    }

    func stopSpeaking() {
        current?.synthesis.cancel()
        current?.player?.stop()
        current = nil
    }

    private func play(_ wav: Data, line id: Int) {
        guard var line = current, line.id == id else { return }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: wav)
        } catch {
            return fail(line: id, because: error)
        }
        player.delegate = self
        guard player.play() else { return fail(line: id, because: PlaybackError.didNotStart) }
        line.player = player
        current = line
        line.onStarted()
    }

    private func fail(line id: Int, because error: any Error) {
        guard let line = current, line.id == id else { return }
        Logger.turnTiming.debug("neural voice failed a line: \(Self.kind(of: error), privacy: .public)")
        current = nil
        line.onFailed()
    }

    /// The error's type and case, or its domain and code, never its message, because FluidAudio's errors can quote
    /// the line.
    private static func kind(of error: any Error) -> String {
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else {
            let error = error as NSError
            return "\(error.domain) \(error.code)"
        }
        return "\(type(of: error)).\(mirror.children.first?.label ?? String(describing: error))"
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishOnMain(player)
    }

    /// A line that breaks off while playing has already started, so it ends rather than fails.
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        finishOnMain(player)
    }

    private nonisolated func finishOnMain(_ player: AVAudioPlayer) {
        nonisolated(unsafe) let player = player
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(player) } }
    }

    private func finished(_ player: AVAudioPlayer) {
        guard let line = current, line.player === player else { return }
        current = nil
        line.onFinished()
    }
}
