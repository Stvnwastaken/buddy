import AVFoundation
import BuddyCore
import os

/// Buddy's own sounds for agent runs, synthesized here rather than taken from a system or third-party sound. A launch
/// is a quick, quiet rising pair, needing the owner is two soft rising notes, and done is a settling three-note chord.
final class RunCues {
    private struct Note {
        let frequency: Double
        let start: Double
    }

    private struct Cue {
        let notes: [Note]
        let length: Double
        let decay: Double
        let volume: Float
    }

    private static let sampleRate = 44_100

    private static func cue(for cue: RunCue) -> Cue {
        switch cue {
        case .launch:
            Cue(notes: [Note(frequency: 523.25, start: 0), Note(frequency: 783.99, start: 0.07)], length: 0.2, decay: 18, volume: 0.35)
        case .needsOwner:
            Cue(notes: [Note(frequency: 659.25, start: 0), Note(frequency: 987.77, start: 0.11)], length: 0.32, decay: 11, volume: 0.5)
        case .done:
            Cue(
                notes: [Note(frequency: 783.99, start: 0), Note(frequency: 987.77, start: 0.09), Note(frequency: 1174.66, start: 0.18)],
                length: 0.5, decay: 7, volume: 0.4
            )
        }
    }

    private var players: [RunCue: AVAudioPlayer] = [:]

    func play(_ cue: RunCue) {
        do {
            let player = try players[cue] ?? AVAudioPlayer(data: Self.wave(cue))
            player.volume = Self.cue(for: cue).volume
            player.currentTime = 0
            player.play()
            players[cue] = player
        } catch {
            Logger.turnTiming.error("The \(String(describing: cue), privacy: .public) cue couldn't play: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The cue as a 16-bit mono WAV file.
    static func wave(_ cue: RunCue) -> Data {
        let shape = Self.cue(for: cue)
        let length = shape.notes.map(\.start).max()! + shape.length
        let count = Int(length * Double(sampleRate))
        let samples = (0..<count).map { index -> Int16 in
            let time = Double(index) / Double(sampleRate)
            let level = shape.notes.reduce(0.0) { sum, note in
                let elapsed = time - note.start
                guard elapsed >= 0, elapsed < shape.length else { return sum }
                let attack = min(1, elapsed / 0.006)
                let envelope = attack * exp(-elapsed * shape.decay)
                let tone = sin(2 * .pi * note.frequency * elapsed) + 0.18 * sin(4 * .pi * note.frequency * elapsed)
                return sum + 0.42 * envelope * tone
            }
            return Int16(max(-1, min(1, level)) * Double(Int16.max))
        }
        var data = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        for sample in samples { append(sample) }
        return data
    }
}
