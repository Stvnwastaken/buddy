import BuddyCore
import FluidAudio
import Foundation

/// Kokoro 82M with installed voice packs, run on the Neural Engine through FluidAudio. Buddy loads it only from files
/// already in `folder`, and `install-voice` downloads them.
public actor NeuralVoice {
    public enum LoadError: Error, Equatable {
        case notInstalled
    }

    public enum SpeakError: Error, Equatable {
        case silent
    }

    public struct IncompleteInstall: Error, CustomStringConvertible {
        public let missing: [String]
        public var description: String { "These files didn't download: \(missing.joined(separator: ", "))" }
    }

    public static let folder = URL.applicationSupportDirectory.appending(path: "Buddy/Voice", directoryHint: .isDirectory)

    private let folder: URL
    private let kokoro: KokoroAneManager
    /// The seven model stages, their vocabulary and the voice, then the English G2P model and Misaki lexicon.
    private let requiredFiles: [URL]

    public init(folder: URL = NeuralVoice.folder) {
        self.folder = folder
        kokoro = KokoroAneManager(directory: folder)
        let model = folder.appending(path: Repo.kokoroAne.folderName)
        let frontend = folder.appending(path: Repo.kokoro.folderName)
        requiredFiles = ModelNames.KokoroAne.requiredModels.sorted().map { model.appending(path: $0) }
            + ModelNames.G2P.requiredModels.union([LexiconAssetCache.englishFileName(british: false)]).sorted()
                .map { frontend.appending(path: $0) }
    }

    /// Loads the model only if every file is already installed, because FluidAudio fetches a missing lexicon even
    /// with its downloads switched off. They stay off in case it would repair a model. It then synthesizes one word,
    /// because the first synthesis after loading is several times slower than the rest.
    public func load() async throws {
        guard missingFiles.isEmpty else { throw LoadError.notInstalled }
        ModelHub.offlineMode = true
        do {
            try await kokoro.initialize()
        } catch is DownloadError {
            throw LoadError.notInstalled
        }
        _ = try await kokoro.synthesize(text: "Hi.")
    }

    /// English voice packs `install-voice` adds beside `af_heart`, so the voice picker has several to offer.
    public static let extraVoices = ["af_bella", "af_nicole", "am_adam", "am_michael", "bf_emma", "bm_george"]

    /// Downloads whatever is missing from Hugging Face, then loads it.
    public func install() async throws {
        ModelHub.offlineMode = false
        try await kokoro.initialize()
        let packs = folder.appending(path: Repo.kokoroAne.folderName)
        for id in Self.extraVoices {
            try await KokoroAneResourceDownloader.ensureVoicePack(id, repoDirectory: packs)
        }
        let missing = missingFiles
        guard missing.isEmpty else { throw IncompleteInstall(missing: missing.map(\.path)) }
    }

    public nonisolated static func installedVoices(in folder: URL = NeuralVoice.folder) -> [Voice] {
        KokoroAneConstants.englishVoices.filter { id in
            FileManager.default.fileExists(atPath: folder.appending(path: Repo.kokoroAne.folderName).appending(path: "\(id).bin").path)
        }.map { $0 == "af_heart" ? .neural : .kokoro($0) }
    }

    /// The line as a 24 kHz mono 16-bit WAV, made ready to play by `LineAudio`.
    public func wav(for line: String, voice: String = "af_heart", speed: Double = 1) async throws -> Data {
        guard missingFiles.isEmpty, Self.installedVoices(in: folder).contains(where: { $0.kokoroID == voice }) else {
            throw LoadError.notInstalled
        }
        ModelHub.offlineMode = true
        let result = try await kokoro.synthesizeDetailed(text: line, voice: voice, speed: Float(speed))
        let audio = LineAudio(samples: result.samples, sampleRate: result.sampleRate).readyToPlay()
        guard !audio.samples.isEmpty else { throw SpeakError.silent }
        return try AudioWAV.data(from: audio.samples, sampleRate: Double(audio.sampleRate), normalize: false)
    }

    private var missingFiles: [URL] {
        requiredFiles.filter { !FileManager.default.fileExists(atPath: $0.path) }
    }
}
