import AVFoundation
import BuddyCore
import QuartzCore
import os

/// A paper scratch synthesized for Buddy from filtered noise. No recordings or borrowed sound assets.
final class PenSounds {
    let audio = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var scratch: [Float] = {
        var seed: UInt32 = 33
        var previous: Float = 0
        return (0..<26_460).map { index in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(seed >> 8) / Float(0xFF_FFFF) * 2 - 1
            let grain = noise - previous * 0.85
            previous = noise
            let pressure = 0.7 + 0.3 * sin(Float(index) * 0.0023)
            return grain * pressure * 0.055
        }
    }()

    func prepare(_ cues: [PenSoundCue]) -> AVAudioPCMBuffer? {
        guard let end = cues.map({ $0.offset + $0.duration }).max(), end > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(end * format.sampleRate))),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = buffer.frameCapacity
        samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        for cue in cues {
            let start = Int((cue.offset * format.sampleRate).rounded())
            let count = min(Int((cue.duration * format.sampleRate).rounded()), Int(buffer.frameLength) - start)
            for index in 0..<count {
                let fade = min(1, Float(index) / 110, Float(count - 1 - index) / 220)
                samples[start + index] += scratch[index % scratch.count] * fade
            }
        }
        let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
        if peak > 0.1 {
            let gain = 0.1 / peak
            for index in 0..<Int(buffer.frameLength) { samples[index] *= gain }
        }
        do {
            if !audio.isRunning {
                _ = audio.mainMixerNode
                audio.prepare()
                try audio.start()
            }
            return buffer
        } catch {
            Logger.turnTiming.error("Pen sounds couldn't start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func play(_ buffer: AVAudioPCMBuffer, startingAt time: CFTimeInterval) {
        let id = UUID()
        let player = AVAudioPlayerNode()
        audio.attach(player)
        audio.connect(player, to: audio.mainMixerNode, format: format)
        players[id] = player
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(id) }
        }
        player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: time)))
    }

    func stop() {
        for id in Array(players.keys) { finish(id) }
    }

    private func finish(_ id: UUID) {
        guard let player = players.removeValue(forKey: id) else { return }
        player.stop()
        audio.detach(player)
    }
}
