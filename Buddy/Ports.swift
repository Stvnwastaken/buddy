import BuddyCore

/// SpeechAnalyzer's on-device model for the owner's language.
enum SpeechModelStatus: Equatable {
    case checking
    case installing(fractionCompleted: Double)
    case ready
    case unavailable(String)
}

protocol Ears: AnyObject {
    func prepare(onModelStatus: @escaping (SpeechModelStatus) -> Void)
    func startListening(
        onHeard: @escaping (String) -> Void,
        onTranscript: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    )
    func stopListening()
}

/// Speaks one line at a time. It reports the start and then the end of the line it is speaking, or a failure in place
/// of both when it can't speak the line, and nothing more for a line that `stopSpeaking` or a newer `speak` cut off.
protocol Mouth: AnyObject {
    func speak(
        _ line: String,
        voice: Voice,
        speed: Double,
        onStarted: @escaping () -> Void,
        onFinished: @escaping () -> Void,
        onFailed: @escaping () -> Void
    )
    func stopSpeaking()
}

protocol Brain: AnyObject {
    func start()
    func send(_ turn: TurnRequest, onEvent: @escaping (ProviderEvent) -> Void)
    func cancelReply()
    func endConversation()
    func stop()
}

extension ClaudeBrain: Brain {}
extension CodexBrain: Brain {}

protocol Screen {
    func captureAll() async throws -> [ScreenCapture]
}

/// The buddy beside the cursor, which flies to each point, and the annotations it draws.
protocol Overlay: AnyObject {
    func showBuddy()
    /// While active, the buddy stays shown at the cursor and says it is using the mouse and keyboard.
    func takeover(_ active: Bool)
    func point(at point: DisplayPoint, on display: DisplayRect, label: String?)
    func annotate(_ annotation: Annotation<DisplayPoint>, on display: DisplayRect)
    /// Draws one line's draw program marks, one after another, starting now.
    func draw(_ marks: [DrawMark<DisplayPoint>], on display: DisplayRect)
    var onPaperEvent: ((BuddyEngine.Event) -> Void)? { get set }
    func updatePaper(_ paper: PlacedPaper)
    func removePaper(_ id: Int)
    /// Clears the annotations, draw program marks included.
    func clearAnnotations()
    func hideBuddy()
}

/// The notch at the top center of the cursor's screen: the buddy icon, and the strip that drops down during a turn.
protocol NotchDisplay: AnyObject {
    /// Puts the notch up on the cursor's screen and keeps it there.
    func start(onEvent: @escaping (BuddyEngine.Event) -> Void)
    func show(_ notch: Notch)
    func update(_ conversation: NotchConversation)
    func focusTextBox()
    func releaseTextBox()
    func stop()
}

/// Types text into the field at a spot for the owner. It calls `onRefused` instead while secure input is on.
protocol Inserter: AnyObject {
    func type(_ text: String, at spot: DisplayPoint, onRefused: @escaping () -> Void)
    /// Drops typing that hasn't clicked or pasted yet. A paste already made still gets the clipboard put back.
    func cancelPending()
}

protocol Store: AnyObject {
    func load() throws -> ConversationHistory
    func save(_ history: ConversationHistory) throws
    func clear() throws
}

/// Runs agent runs, each in its own folder with its own provider process. Everything a run reports, its calls to
/// Buddy's tools included, reaches `onEvent` on the main queue after the call that caused it has returned.
protocol AgentHost: AnyObject {
    func start(_ run: RunID, _ brief: RunBrief, on cli: ProviderCLI, approving mode: ApprovalMode, onEvent: @escaping (RunEvent) -> Void)
    func resume(_ run: RunID, _ brief: RunBrief, on cli: ProviderCLI, approving mode: ApprovalMode, onEvent: @escaping (RunEvent) -> Void)
    func isWaiting(_ call: ToolCallID, for run: RunID) -> Bool
    func answerApproval(_ run: RunID, request: String, _ approval: Approval)
    func answerTool(_ call: ToolCallID, _ answer: ToolAnswer)
    func saveNote(_ run: RunID, _ text: String)
    func saveReport(_ run: RunID, _ text: String)
    /// Ends the run's process at once and answers its waiting tool calls. A run that has already ended is fine.
    func stop(_ run: RunID)
    func stopAll()
}
