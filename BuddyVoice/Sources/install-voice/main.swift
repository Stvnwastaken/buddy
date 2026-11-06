import BuddyVoice
import Foundation

print("Installing the neural voice in \(NeuralVoice.folder.path)")
try await NeuralVoice().install()

let voice = NeuralVoice()
let clock = ContinuousClock()
var started = clock.now
try await voice.load()
print("Loaded it the way Buddy does, without the network, in \(started.duration(to: clock.now).formatted(.units(allowed: [.milliseconds])))")

let line = "Open the File menu, then choose New Folder."
started = clock.now
_ = try await voice.wav(for: line)
print("Synthesized one line in \(started.duration(to: clock.now).formatted(.units(allowed: [.milliseconds]))). Quit and reopen Buddy to use it.")
