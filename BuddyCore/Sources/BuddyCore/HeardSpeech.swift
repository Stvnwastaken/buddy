/// The words heard so far in one push-to-talk, assembled from SpeechTranscriber's results.
///
/// A final result settles its words for good. Any other result is a guess about the audio after the settled words,
/// and each guess replaces the last. SpeechTranscriber need not repeat a guess as final when finalizing leaves it
/// unchanged, so the latest guess still counts as heard.
public struct HeardSpeech: Equatable, Sendable {
    private var settled = ""
    private var guess = ""

    public init() {}

    public var text: String { settled + guess }

    public mutating func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            settled += text
            guess = ""
        } else {
            guess = text
        }
    }
}
