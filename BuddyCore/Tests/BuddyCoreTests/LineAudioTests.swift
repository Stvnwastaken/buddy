import Testing
import BuddyCore

private func silence(_ count: Int) -> [Float] {
    Array(repeating: 0, count: count)
}

struct LineAudioTests {
    @Test func theSilenceAroundTheWordsShrinksToAShortMarginAndAQuietVoiceIsRaised() {
        let synthesized = LineAudio(samples: silence(32) + [0.125, -0.25, 0.0625] + silence(50), sampleRate: 100)
        #expect(synthesized.readyToPlay() == LineAudio(
            samples: silence(4) + [0.375, -0.75, 0.1875] + silence(8),
            sampleRate: 100
        ))
    }

    @Test func aLoudLineIsRaisedOnlyUntilItsPeakReachesTheCeiling() {
        let synthesized = LineAudio(samples: [0.5, -0.25], sampleRate: 100)
        #expect(synthesized.readyToPlay() == LineAudio(samples: [0.9, -0.45], sampleRate: 100))
    }

    @Test func soundBelowTheSilenceThresholdIsTrimmedButSoundAboveItIsKept() {
        let synthesized = LineAudio(
            samples: [0.0078125] + silence(10) + [0.015625, 0.25, 0.0078125, 0.015625] + silence(3) + [0.0078125],
            sampleRate: 100
        )
        #expect(synthesized.readyToPlay() == LineAudio(
            samples: silence(4) + [0.046875, 0.75, 0.0234375, 0.046875] + silence(3) + [0.0234375],
            sampleRate: 100
        ))
    }

    @Test func aLineWithNoSoundAboveTheThresholdBecomesEmpty() {
        #expect(LineAudio(samples: silence(5) + [0.0078125, -0.0078125], sampleRate: 100).readyToPlay()
            == LineAudio(samples: [], sampleRate: 100))
        #expect(LineAudio(samples: [], sampleRate: 24_000).readyToPlay() == LineAudio(samples: [], sampleRate: 24_000))
    }
}
