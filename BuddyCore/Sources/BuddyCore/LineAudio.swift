/// The sound of one spoken line: mono samples from -1 to 1.
public struct LineAudio: Equatable, Sendable {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// Kokoro leaves about 0.3 s of silence before a line and 0.5 s after it, which delays the words and stretches
    /// the pause between lines, and it speaks about 10 dB quieter than the Apple voice. This keeps a short margin
    /// around the sound and raises the level by up to three times, stopping short of clipping. A line with no sound
    /// becomes empty.
    public func readyToPlay() -> LineAudio {
        let silence: Float = 0.01, ceiling: Float = 0.9, maximumGain: Float = 3
        let marginBefore = sampleRate * 4 / 100, marginAfter = sampleRate * 8 / 100
        guard let first = samples.firstIndex(where: { abs($0) > silence }),
              let last = samples.lastIndex(where: { abs($0) > silence }) else {
            return LineAudio(samples: [], sampleRate: sampleRate)
        }
        let start = max(first - marginBefore, 0)
        let end = min(last + marginAfter, samples.count - 1)
        let sound = samples[start...end]
        let peak = sound.map(abs).max() ?? 0
        let gain = min(maximumGain, ceiling / peak)
        return LineAudio(samples: sound.map { $0 * gain }, sampleRate: sampleRate)
    }
}
