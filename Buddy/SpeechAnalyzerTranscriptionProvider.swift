import AVFoundation
import BuddyCore
import Foundation
import Speech

private struct SpeechModelError: LocalizedError {
    let errorDescription: String?
    /// Whether a later attempt could succeed, as a download can once the network is back.
    let canRetry: Bool

    init(_ message: String, canRetry: Bool = false) {
        errorDescription = message
        self.canRetry = canRetry
    }
}

/// Streaming transcription with SpeechAnalyzer and SpeechTranscriber, fully on this Mac.
final class SpeechAnalyzerTranscriptionProvider: BuddyTranscriptionProvider {
    private var status = SpeechModelStatus.checking
    private var model: (locale: Locale, format: AVAudioFormat)?
    private var preparing: Task<Void, Never>?
    private var canRetry = true

    var isReady: Bool { model != nil }

    /// Finds the model for the owner's language and installs it through the system's asset inventory when it is missing.
    /// A model that failed to download is tried again on a later call. Releases models reserved for other languages,
    /// because the system limits how many one app may hold.
    func prepare(onStatus: @escaping (SpeechModelStatus) -> Void) {
        guard model == nil, preparing == nil, canRetry else { return }
        preparing = Task {
            do {
                model = try await Self.installModel { [weak self] fraction in
                    guard let self, preparing != nil, model == nil else { return }
                    report(.installing(fractionCompleted: fraction), to: onStatus)
                }
                report(.ready, to: onStatus)
            } catch {
                canRetry = (error as? SpeechModelError)?.canRetry ?? true
                report(.unavailable(error.localizedDescription), to: onStatus)
            }
            preparing = nil
        }
    }

    func startStreamingSession(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let model else { throw SpeechModelError("The on-device speech model isn't ready.") }
        return SpeechAnalyzerTranscriptionSession(
            transcriber: Self.transcriber(for: model.locale),
            format: model.format,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    private func report(_ status: SpeechModelStatus, to onStatus: (SpeechModelStatus) -> Void) {
        guard status != self.status else { return }
        self.status = status
        onStatus(status)
    }

    private static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    private static func installModel(onProgress: @escaping (Double) -> Void) async throws -> (locale: Locale, format: AVAudioFormat) {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechModelError("SpeechAnalyzer isn't available on this Mac.")
        }
        let language = Locale.current.localizedString(forIdentifier: Locale.spoken.identifier) ?? Locale.spoken.identifier
        // `supportedLocale(equivalentTo:)` also names languages with no model to download, such as Polish.
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .spoken),
              await SpeechTranscriber.supportedLocales.contains(locale) else {
            throw SpeechModelError("SpeechAnalyzer doesn't support \(language).")
        }
        let modules = [transcriber(for: locale)]
        for reserved in await AssetInventory.reservedLocales where reserved.identifier != locale.identifier {
            await AssetInventory.release(reservedLocale: reserved)
        }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                onProgress(request.progress.fractionCompleted)
                let observation = request.progress.observe(\.fractionCompleted) { progress, _ in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in onProgress(fraction) }
                }
                defer { observation.invalidate() }
                try await request.downloadAndInstall()
            }
        } catch {
            throw SpeechModelError("Couldn't download the on-device speech model for \(language).", canRetry: true)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw SpeechModelError("SpeechAnalyzer has no audio format for \(locale.identifier).")
        }
        return (locale, format)
    }
}

private final class SpeechAnalyzerTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1

    private let analyzer: SpeechAnalyzer
    private nonisolated let input: AsyncStream<AnalyzerInput>.Continuation
    private nonisolated let converter: AnalyzerAudioConverter

    init(
        transcriber: SpeechTranscriber,
        format: AVAudioFormat,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let (audio, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.analyzer = analyzer
        self.input = input
        converter = AnalyzerAudioConverter(to: format)

        Task {
            var heard = HeardSpeech()
            do {
                for try await result in transcriber.results {
                    heard.receive(String(result.text.characters), isFinal: result.isFinal)
                    onTranscriptUpdate(heard.text)
                }
                onFinalTranscriptReady(heard.text)
            } catch {
                onError(error)
            }
        }
        Task {
            do {
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: audio)
            } catch {
                onError(error)
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    nonisolated func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(audioBuffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func requestFinalTranscript() {
        input.finish()
        Task { [analyzer] in try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    func cancel() {
        input.finish()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}

/// Resamples microphone buffers into the analyzer's format. Only the microphone's audio thread calls it, one buffer at a time.
private nonisolated final class AnalyzerAudioConverter: @unchecked Sendable {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to format: AVAudioFormat) {
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        // The resampler can hand back a few frames it held over from the previous buffer.
        let frames = (Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        // The converter calls this block only during `convert`, on this thread.
        nonisolated(unsafe) let source = buffer
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
