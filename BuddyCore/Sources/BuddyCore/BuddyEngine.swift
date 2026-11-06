import Foundation

public enum Permission: String, CaseIterable, Sendable {
    case microphone, speechRecognition, screenCapture, accessibility, inputMonitoring

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        case .screenCapture: "Screen Recording"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }
}

public enum PermissionStatus: Equatable, Sendable {
    case unknown, notDetermined, notGranted, denied, restricted, granted
}

public struct PermissionSnapshot: Equatable, Sendable {
    public let microphone: PermissionStatus
    public let speechRecognition: PermissionStatus
    public let screenCapture: PermissionStatus
    public let accessibility: PermissionStatus
    public let inputMonitoring: PermissionStatus

    public init(
        microphone: PermissionStatus = .unknown,
        speechRecognition: PermissionStatus = .unknown,
        screenCapture: PermissionStatus = .unknown,
        accessibility: PermissionStatus = .unknown,
        inputMonitoring: PermissionStatus = .unknown
    ) {
        self.microphone = microphone
        self.speechRecognition = speechRecognition
        self.screenCapture = screenCapture
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    public subscript(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone: microphone
        case .speechRecognition: speechRecognition
        case .screenCapture: screenCapture
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        }
    }
}

public enum LoginItemStatus: Equatable, Sendable { case off, on, requiresApproval, unavailable }

/// The voice a line is spoken in.
public enum Voice: Equatable, Sendable, Codable, Hashable {
    case neural, apple, kokoro(String)

    public var kokoroID: String? {
        switch self {
        case .neural: "af_heart"
        case .apple: nil
        case .kokoro(let id): id
        }
    }

    public var title: String {
        switch self {
        case .apple: "Apple (system voice)"
        case .neural: "Kokoro · af_heart"
        case .kokoro(let id): "Kokoro · \(id)"
        }
    }
}

public struct SpeechSettings: Equatable, Sendable, Codable {
    public let voice: Voice
    public let speed: Double

    public init(voice: Voice = .neural, speed: Double = 1) {
        self.voice = voice
        self.speed = speed
    }

    public var isValid: Bool { speed.isFinite && (0.5...2).contains(speed) }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try! encoder.encode(self)
    }
}

/// Whether the neural voice can speak. Whenever it can't, the Apple voice speaks instead.
public enum NeuralVoiceStatus: Equatable, Sendable {
    case loading
    case ready
    case notInstalled
    case failed(String)
}

public struct BuddyEngine: Sendable {
    public enum TurnPhase: Equatable, Sendable {
        case idle
        /// The text box is open for a typed question.
        case typing
        case held
        case transcribing
        case capturing(transcript: String)
        case replying(Reply)
    }
    /// A reply in progress. Finished lines are presented in order while the provider streams the rest.
    public struct Reply: Equatable, Sendable {
        enum Presentation: Equatable, Sendable {
            case ready
            /// The mouth was given this beat's line and hasn't started it yet.
            case starting(Beat)
            case speaking(Beat)
            case reading(Beat)
            /// The line with this target has been presented, and later lines wait for a click inside it.
            case waiting(TargetArea, since: Date)
        }
        enum TargetProgress: Equatable, Sendable {
            case armed(TargetArea)
            /// The owner clicked the target while its line was still being presented.
            case clicked
        }
        let request: TurnRequest
        /// Only the provider's replies offer agent runs, never Buddy's own lines or a run's beats.
        var offersRuns = false
        var reader = ReplyReader()
        var streaming = true
        var finishedLines: [String] = []
        var pending: [Beat] = []
        var presentation = Presentation.ready
        var presentedLines: [String] = []
        var threadLines = 0
        /// The target of the line being presented.
        var target: TargetProgress?
        /// The owner clicked a target with no lines after it yet. If none follow, the reply ends by asking again.
        var asksAgainAtEnd = false
        /// Kept for the reply unless synthesis fails or the owner chooses a different voice.
        var voice: Voice?
        var speechSettings: SpeechSettings?

        mutating func add(_ beats: [Beat]) {
            finishedLines += beats.map(\.words)
            pending += beats
            if !beats.isEmpty { asksAgainAtEnd = false }
        }
    }
    public struct State: Equatable, Sendable {
        public fileprivate(set) var turn: TurnPhase = .idle
        public fileprivate(set) var notice: String?
        public fileprivate(set) var notchConversation = NotchConversation()
        public fileprivate(set) var permissions = PermissionSnapshot()
        public fileprivate(set) var loginItem: LoginItemStatus = .off
        public fileprivate(set) var loginChangePending = false
        public fileprivate(set) var speechSettings = SpeechSettings()
        public fileprivate(set) var availableVoices: [Voice] = [.apple]
        public fileprivate(set) var neuralVoice = NeuralVoiceStatus.loading
        public fileprivate(set) var spokenReplies = true
        public fileprivate(set) var shortcuts = Shortcuts()
        public fileprivate(set) var shortcutError: String?
        public fileprivate(set) var penSounds = true
        public fileprivate(set) var reduceMotion = false
        public fileprivate(set) var talkSetup = TalkSetup.direct(.auto)
        /// The provider the next turn goes to unless the router moves it.
        public fileprivate(set) var provider = Provider.claude
        public fileprivate(set) var usage = UsageSnapshots()
        /// The CLI the next agent run starts on.
        public fileprivate(set) var runCLI = ProviderCLI.claudeCode
        public fileprivate(set) var runProviderChoice = ProviderChoice.auto
        /// How the next agent run's requests are approved.
        public fileprivate(set) var approvalMode = ApprovalMode.auto
        public fileprivate(set) var history = ConversationHistory()
        public fileprivate(set) var historyError: String?
        public fileprivate(set) var historyClearPending = false
        public fileprivate(set) var historyCleared = false
        public fileprivate(set) var profile = Profile()
        public fileprivate(set) var profileError: String?
        public fileprivate(set) var profileClearPending = false
        public fileprivate(set) var profileCleared = false
        fileprivate(set) var annotationsShown = false
        public fileprivate(set) var papers: [PlacedPaper] = []
        /// The dock's agent runs, one card each, oldest first. A run's card stays until the owner closes it after the
        /// run ends.
        public fileprivate(set) var runs: [AgentRun] = []
        /// The question the owner's next spoken or typed turn answers: the one that has waited longest across the dock.
        /// The MCP server numbers every run's calls in one sequence.
        public var questionTakingNextTurn: ToolCallID? {
            runs.compactMap(\.waitingQuestion).min { $0.number < $1.number }
        }
        /// The agent run Buddy last asked to start, held from the moment its line starts or is shown. The next asked
        /// turn within ten minutes accepts it with a yes and drops it otherwise. Esc, a failed reply and the turn a
        /// click on a walkthrough's last target asks drop it too.
        public fileprivate(set) var runOffer: RunBrief?
    }
    public enum Event: Sendable {
        case paperClosed(Int)
        case paperPinToggled(Int)
        case paperMoved(Int, to: DisplayPoint)
        case pushToTalkPressed, pushToTalkReleased, interrupted, noticeExpired
        /// The modifiers and other input held after one went down or up, timed from a fixed moment such as system startup.
        case modifiersChanged(ModifierKeys, at: Duration, otherInputHeld: Bool = false, tapsAllowed: Bool = true)
        /// A key that isn't a modifier, or a mouse button, went down anywhere.
        case keyOrButtonPressed
        /// The left mouse button went down at this spot, anywhere on screen.
        case clicked(DisplayPoint)
        /// Typing was refused because secure input was on, as in a password field.
        case typingRefused
        case textBoxSubmitted(String)
        /// The owner closed the text box without asking, or clicked away from it.
        case textBoxDismissed
        case notchPointerChanged(Bool)
        case notchHoverElapsed
        case textBoxFocused
        case textBoxChanged(String)
        case newConversationRequested
        case conversationsRequested
        case conversationThreadRequested
        case conversationOpened(Int)
        case conversationDeleted(Int)
        case transcriptUpdated(String)
        case transcriptFinished(String)
        case screensCaptured([ScreenCapture])
        case provider(ProviderEvent)
        case lineStarted, lineFinished
        case replyLineRead
        case spokenRepliesChanged(Bool)
        case shortcutChosen(ShortcutSlot, ShortcutTrigger)
        case penSoundsChanged(Bool)
        case reduceMotionChanged(Bool)
        /// The owner changed how talk reaches the providers, and the app restarted its provider processes.
        case talkSetupChosen(TalkSetup)
        /// A provider reported its usage, during a turn or, for Codex, at any time.
        case usageReported(Provider, ProviderUsage)
        /// The owner chose the CLI for agent runs started from now on.
        case runCLIChosen(ProviderCLI)
        case runProviderChosen(ProviderChoice)
        /// The owner chose how agent runs started from now on are approved.
        case approvalModeChosen(ApprovalMode)
        /// The mouth couldn't speak the line it was given, and will report nothing else for it.
        case lineFailed
        case neuralVoiceObserved(NeuralVoiceStatus)
        case voicesObserved([Voice])
        case speechSettingsChanged(SpeechSettings)
        case voicePreviewRequested(Voice)
        case listeningFailed(String)
        case captureFailed(String)
        case permissionsObserved(PermissionSnapshot)
        case permissionRequested(Permission)
        case loginItemObserved(LoginItemStatus)
        case launchAtLoginRequested(Bool)
        case loginItemChangeFinished(LoginItemStatus, error: String?)
        case clockTick, clearHistoryRequested
        case historyCleared(error: String?)
        case historyFailed(String)
        case historySaved
        /// The utility model's answer to the `writeSummary` request with this id.
        case summaryWritten(id: Int, String)
        case summaryFailed(id: Int)
        /// The provider selection or its connection changed, and the app restarted its provider processes.
        case providerChanged
        case clearProfileRequested
        case profileCleared(error: String?)
        case profileFailed(String)
        case profileSaved
        case run(RunID, RunEvent)
        case runStopRequested(RunID)
        /// The owner clicked approve or deny for the run's permission prompt with this id.
        case runApprovalAnswered(RunID, request: String, approved: Bool)
        /// The owner clicked one of the choices of the run's question.
        case runQuestionAnswered(RunID, ToolCallID, String)
        /// The owner allowed or refused the run's request for the screen.
        case runTakeoverAnswered(RunID, ToolCallID, approved: Bool)
        case runDismissed(RunID)
        case runTimeUp(RunID)
    }
    public enum Effect: Equatable, Sendable {
        /// Shows the buddy beside the cursor, where it rests between points.
        case showBuddy
        /// Hides the buddy beside the cursor. Annotations stay up.
        case hideBuddy
        /// Changes what the notch shows. The app ends a `closing` strip a few seconds later on its own, and sends
        /// `noticeExpired` a few seconds after a notice.
        case showNotch(Notch)
        /// Gives the notch's inline text box the keyboard. This remains the text-trigger shortcut slot.
        case showTextBox
        case hideTextBox
        case point(DisplayPoint, on: DisplayRect, label: String?)
        case annotate(Annotation<DisplayPoint>, on: DisplayRect)
        /// Draws one line's draw program marks, one after another, starting now. Draw marks are annotations too.
        case draw([DrawMark<DisplayPoint>], on: DisplayRect)
        case updatePaper(PlacedPaper)
        case removePaper(Int)
        /// Pen scratches timed from the same instant as this line's `draw` effect.
        case playPenSounds([PenSoundCue])
        case stopPenSounds
        case clearAnnotations
        /// Clicks into the field at the spot and pastes the text there. The app sends `typingRefused` instead while
        /// secure input is on.
        case type(String, at: DisplayPoint)
        case startListening
        case stopListening
        case captureScreens
        /// Sends the turn to `state.provider`.
        case sendTurn(TurnRequest)
        /// Later turns go to the other provider. The one left behind starts its next conversation fresh, so a turn that
        /// comes back to it primes it with the turns it missed.
        case leaveProvider(Provider)
        case saveUsage(UsageSnapshots)
        case saveShortcuts(Data)
        case cancelReply
        /// Speaks one line of the reply. The mouth reports `lineStarted` and then `lineFinished` for it, or `lineFailed`
        /// before it starts.
        case speak(String, voice: Voice, speed: Double = 1)
        case saveSpeechSettings(Data)
        case previewVoice(String, voice: Voice, speed: Double)
        case stopSpeaking
        case waitForReading(Duration)
        case cancelReading
        case saveHistory(ConversationHistory)
        case clearHistory
        case saveProfile(Profile)
        case clearProfile
        case resetProvider
        /// Asks the utility model to write a conversation summary, which it reports with `summaryWritten` or
        /// `summaryFailed`.
        case writeSummary(SummaryRequest)
        case cancelSummary
        case cancelCapture
        case requestPermission(Permission)
        case openPermissionSettings(Permission)
        case setLaunchAtLogin(Bool)
        case openLoginItemSettings
        /// Makes the run's folder, writes its brief and starts its provider process on this CLI, which reports
        /// `started`.
        case startRun(RunID, RunBrief, ProviderCLI, ApprovalMode)
        /// Stops the old process and its tools while retaining the run's folder and wall-clock timer.
        case pauseRun(RunID)
        case resumeRun(RunID, RunBrief, ProviderCLI, ApprovalMode)
        /// Ends the run's process at once and stops serving its tools.
        case stopRun(RunID)
        /// Sends `runTimeUp` for the run after this many seconds.
        case scheduleRunTimeUp(RunID, seconds: Int)
        case answerApproval(RunID, id: String, Approval)
        case captureScreensForTool(RunID, ToolCallID)
        case answerTool(ToolCallID, ToolAnswer)
        /// Writes the run's `note.md`.
        case saveRunNote(RunID, String)
        /// Writes the run's `report.md`.
        case saveRunReport(RunID, String)
        /// One of Buddy's own sounds for a run's moments.
        case playCue(RunCue)
        /// Blocks the owner's keyboard and mouse, except Esc and push-to-talk, and shows the buddy acting. The app sends
        /// `takeoverFailed` when it can't block them.
        case beginTakeover(RunID)
        /// Performs the action with the mouse or keyboard, then reports `acted` for the call.
        case act(RunID, ToolCallID, ScreenAction<DisplayPoint>)
        /// Gives the owner back their keyboard and mouse and stops showing the buddy acting.
        case endTakeover(RunID)
    }
    public private(set) var state = State()
    private let providerConnected: Bool
    private let runLimits: RunLimits
    private let home: String
    private let fileExists: @Sendable (String) -> Bool
    private let resolvePath: @Sendable (String) -> String?
    private let drawSandbox: DrawSandbox
    private var attemptedPrompts: Set<Permission> = []
    private var shortcutMatcher = ShortcutMatcher(shortcuts: Shortcuts())
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone?
    private var eventTime: Date

    private var runsStarted = 0
    private var penSoundsScheduled = false
    /// The run whose lines and marks are on screen, until the owner's next turn replaces them.
    private var runOnScreen: RunID?
    /// A walkthrough that was waiting on its target with lines still to come when the owner began a new turn. Saying
    /// "continue" in that turn resumes it.
    private var heldWalkthrough: Reply?
    /// What the last `showNotch` effect showed.
    private var notch = Notch.idle

    /// How long a walkthrough waits for a click on its target.
    static let targetWait: TimeInterval = 60
    static let continuationQuestion = "I clicked it."
    static let walkthroughTimeout = "I'll stop here. Ask me again whenever you want to keep going."
    static let searchCue = "Let me look that up."
    private var summariesRequested = 0
    private var summaryInFlight: SummaryRequest?
    /// Set when a summary fails, so it isn't retried on every event. A turn, a conversation end or a provider
    /// change tries again.
    private var summaryFailed = false
    /// Set when the provider changed while a summary was in flight, so its failure is retried on the new provider.
    private var providerChangedDuringSummary = false
    /// The earlier summaries the warm provider process was primed with, or nil when the next turn starts a fresh one.
    private var primedSummaries: [String]?
    /// When `state.runOffer` was held. Like a conversation, an offer goes stale after `idleLimit`.
    private var runOfferHeldAt: Date?
    private var nextPaperID = 1
    /// How long a conversation or a run offer lasts with nothing asked.
    private static let idleLimit: TimeInterval = 600

    public init(
        providerConnected: Bool = false,
        history: ConversationHistory = .init(),
        profile: Profile = .init(),
        spokenReplies: Bool = true,
        speechSettingsData: Data? = nil,
        shortcutData: Data? = nil,
        penSounds: Bool = true,
        reduceMotion: Bool = false,
        talkSetup: TalkSetup = .direct(.auto),
        usage: UsageSnapshots = .init(),
        runCLI: ProviderCLI? = nil,
        runProviderChoice: ProviderChoice = .auto,
        approvalMode: ApprovalMode = .auto,
        now: @escaping @Sendable () -> Date = Date.init,
        timeZone: TimeZone? = nil,
        runLimits: RunLimits = .standard,
        home: String = "",
        fileExists: @escaping @Sendable (String) -> Bool = { _ in true },
        resolvePath: @escaping @Sendable (String) -> String? = RunPath.resolve,
        drawTimeLimit: Duration = .milliseconds(500)
    ) {
        self.providerConnected = providerConnected
        self.now = now
        self.timeZone = timeZone
        eventTime = now()
        state.history = history
        state.notchConversation.entries = history.active?.turns.flatMap { turn in
            [.owner(turn.transcript)] + turn.reply.split(separator: "\n").map { .buddy(String($0)) }
        } ?? []
        state.profile = profile
        self.runLimits = runLimits
        self.home = home
        self.fileExists = fileExists
        self.resolvePath = resolvePath
        drawSandbox = DrawSandbox(timeLimit: drawTimeLimit)
        state.spokenReplies = spokenReplies
        if let speechSettingsData,
           let settings = try? JSONDecoder().decode(SpeechSettings.self, from: speechSettingsData), settings.isValid {
            state.speechSettings = settings
        }
        if let shortcutData {
            if let shortcuts = try? JSONDecoder().decode(Shortcuts.self, from: shortcutData), shortcuts.isValid {
                state.shortcuts = shortcuts
            } else {
                state.shortcutError = "Saved shortcuts couldn't be loaded. Using the defaults."
            }
        }
        shortcutMatcher = ShortcutMatcher(shortcuts: state.shortcuts)
        state.penSounds = penSounds
        state.reduceMotion = reduceMotion
        state.talkSetup = talkSetup
        state.usage = usage
        state.provider = ProviderRouter.route(from: .claude, choice: talkSetup.choice, usage: usage, at: eventTime)
        state.runProviderChoice = runProviderChoice
        if let runCLI {
            state.runCLI = runCLI
            state.runProviderChoice = runCLI == .codex ? .codex : .claude
        }
        state.approvalMode = approvalMode
    }

    /// Every event ends by asking for the next summary that is behind, so none waits on a particular event.
    public mutating func handle(_ event: Event) -> [Effect] {
        eventTime = now()
        let progress = state.history.progress
        let effects = respond(to: event)
        state.notchConversation.pastConversations = state.history.conversations.compactMap { conversation in
            guard let question = conversation.turns.first?.transcript else { return nil }
            return NotchConversation.HistoryItem(id: conversation.id, question: question, startedAt: conversation.startedAt,
                                                 lastActivity: conversation.lastActivity)
        }.sorted { $0.lastActivity == $1.lastActivity ? $0.id > $1.id : $0.lastActivity > $1.lastActivity }
        return effects + summarize(retrying: state.history.progress != progress)
    }

    private mutating func respond(to event: Event) -> [Effect] {
        switch event {
        case .conversationDeleted(let id):
            guard !state.historyClearPending, runHoldingScreen == nil,
                  state.history.conversations.contains(where: { $0.id == id }) else { return [] }
            var stopping = stopEffects() + clearAnnotations() + [.cancelCapture]
            state.turn = .idle
            state.notice = nil
            heldWalkthrough = nil
            runOnScreen = nil
            state.runOffer = nil
            state.notchConversation.focused = false
            if state.history.active?.id == id {
                state.notchConversation.entries = []
                state.notchConversation.draft = ""
            }
            if summaryInFlight?.conversation == id {
                summaryInFlight = nil
                stopping.append(.cancelSummary)
            }
            state.history.delete(id)
            return stopping + resetProvider() + [.saveHistory(state.history), .hideBuddy] + showNotch(.idle)
        case .conversationThreadRequested:
            state.notchConversation.page = .thread
            return []
        case .conversationOpened(let id):
            guard !state.historyClearPending, runHoldingScreen == nil,
                  state.history.conversations.contains(where: { $0.id == id }) else { return [] }
            state.notchConversation.page = .thread
            state.notchConversation.isOpen = true
            guard state.history.active?.id != id else { return [] }
            let stopping = stopEffects() + clearAnnotations() + [.cancelCapture]
            state.turn = .idle
            state.notice = nil
            heldWalkthrough = nil
            runOnScreen = nil
            state.runOffer = nil
            state.notchConversation.draft = ""
            state.notchConversation.focused = false
            _ = state.history.reopen(id, at: eventTime)
            state.notchConversation.entries = state.history.active?.turns.flatMap { turn in
                [.owner(turn.transcript)] + turn.reply.split(separator: "\n").map { .buddy(String($0)) }
            } ?? []
            return stopping + resetProvider() + [.saveHistory(state.history), .hideBuddy] + showNotch(.idle)
        case .conversationsRequested:
            guard !state.historyClearPending, runHoldingScreen == nil else { return [] }
            let effects = state.turn == .typing ? stopTurn(becoming: .idle)
                : state.notchConversation.focused ? [.hideTextBox] : []
            state.notchConversation.focused = false
            state.notchConversation.page = .history
            state.notchConversation.isOpen = true
            return effects
        case .textBoxFocused:
            guard runHoldingScreen == nil, !state.historyClearPending else { return [] }
            guard !state.notchConversation.focused else { return [] }
            let effects: [Effect]
            switch state.turn {
            case .capturing, .replying:
                effects = [.showTextBox]
            default:
                effects = beginTurn(as: .typing) + [.hideBuddy] + showNotch(.idle) + [.showTextBox]
            }
            state.notchConversation.isOpen = true
            state.notchConversation.page = .thread
            state.notchConversation.focused = true
            return effects
        case .textBoxChanged(let text):
            state.notchConversation.draft = text
            state.notchConversation.closeIfUnused()
            return []
        case .newConversationRequested:
            guard !state.historyClearPending else { return [] }
            let stopping = stopEffects() + clearAnnotations() + [.cancelCapture]
            state.turn = .idle
            state.notice = nil
            heldWalkthrough = nil
            runOnScreen = nil
            state.runOffer = nil
            state.notchConversation.draft = ""
            state.notchConversation.page = .thread
            state.notchConversation.focused = false
            state.notchConversation.closeIfUnused()
            return stopping + endConversation() + showNotch(.idle)
        case .notchPointerChanged(let inside):
            state.notchConversation.pointerInside = inside
            state.notchConversation.hoverBegan = inside ? eventTime : nil
            state.notchConversation.closeIfUnused()
            return []
        case .notchHoverElapsed:
            if let began = state.notchConversation.hoverBegan,
               eventTime >= began.addingTimeInterval(0.3) {
                state.notchConversation.isOpen = true
            }
            return []
        case .paperClosed(let id):
            guard state.papers.contains(where: { $0.paper.id == id }) else { return [] }
            state.papers.removeAll { $0.paper.id == id }
            return [.removePaper(id)]
        case .paperPinToggled(let id):
            guard let index = state.papers.firstIndex(where: { $0.paper.id == id }) else { return [] }
            state.papers[index].pinned.toggle()
            return [.updatePaper(state.papers[index])]
        case .paperMoved(let id, let point):
            guard point.x.isFinite, point.y.isFinite,
                  let index = state.papers.firstIndex(where: { $0.paper.id == id }) else { return [] }
            state.papers[index].paper.at = point
            return [.updatePaper(state.papers[index])]
        case .pushToTalkPressed:
            // No reminder cue here: the microphone is about to open.
            let released = takeScreenBack(remindingOfWaitingRuns: false)
            guard state.turn != .held, !state.historyClearPending else { return released }
            return released + beginTurn(as: .held) + showNotch(.listening(heard: ""))
                + (providerConnected ? [.startListening] : [])
        case .pushToTalkReleased:
            guard state.turn == .held else { return [] }
            guard providerConnected else { return endTurn(notice: "No provider connected.") }
            state.turn = .transcribing
            return [.stopListening, .showBuddy] + showNotch(.thinking)
        case .transcriptUpdated(let text):
            guard state.turn == .held else { return [] }
            return showNotch(.listening(heard: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .transcriptFinished(let text):
            guard state.turn == .transcribing else { return [] }
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                state.turn = .idle
                return activity() + [.hideBuddy] + showNotch(.idle)
            }
            return ask(transcript)
        case .screensCaptured(let captures):
            guard case .capturing(let transcript) = state.turn else { return [] }
            let request = TurnRequest(
                transcript: transcript, captures: captures, earlierSummaries: state.history.earlierSummaries,
                summary: state.history.active?.summary?.text, recentTurns: state.history.recentTurns, profile: state.profile,
                runs: state.runs, today: today
            )
            if let runRequest = Self.runRequest(in: transcript) {
                guard !runRequest.isEmpty else {
                    return say("Tell me what the agent should do right after the word agent.", for: request)
                }
                return startRun(RunBrief(request: runRequest, captures: captures), answering: request)
            }
            state.turn = .replying(Reply(request: request, offersRuns: true))
            let stale = primedSummaries.map { $0 != request.earlierSummaries } ?? false
            primedSummaries = request.earlierSummaries
            let moving = route()
            return (stale ? [.resetProvider] : moving) + [.sendTurn(request)]
        case .provider(let providerEvent):
            guard case .replying(var reply) = state.turn, reply.streaming else { return [] }
            switch providerEvent {
            case .textDelta(let text):
                let read = reply.reader.feed(text)
                switch beats(of: read, answering: reply.request) {
                case .success(let beats): reply.add(beats)
                case .failure(let failure):
                    return applyProfileEdits(read.lines.profileEdits) + [.cancelReply] + endReply(reply, notice: failure.notice)
                }
                return applyProfileEdits(read.lines.profileEdits) + advance(reply)
            case .searching:
                // The line written before the search plays now rather than after it. With nothing said yet, Buddy's
                // own cue plays, so the search isn't silent. The cue isn't saved in history.
                let lines = reply.reader.endLine()
                reply.add(lines.beats)
                if reply.presentedLines.isEmpty && reply.pending.isEmpty {
                    reply.pending.append(Beat(words: Self.searchCue, point: nil, annotations: []))
                }
                return applyProfileEdits(lines.profileEdits) + advance(reply)
            case .usage:
                return []
            case .completed:
                let read = reply.reader.finish()
                switch beats(of: read, answering: reply.request) {
                case .success(let beats): reply.add(beats)
                case .failure(let failure):
                    return applyProfileEdits(read.lines.profileEdits) + endReply(reply, notice: failure.notice)
                }
                reply.streaming = false
                let record = TurnRecord(transcript: reply.request.transcript, reply: reply.finishedLines.joined(separator: "\n"))
                state.history.append(record, at: eventTime)
                return applyProfileEdits(read.lines.profileEdits) + [.saveHistory(state.history)] + advance(reply)
            case .failed(let failure):
                let failed = state.provider
                var saving: [Effect] = []
                if failure == .limitReached, case .direct = state.talkSetup {
                    state.usage[failed] = (state.usage[failed] ?? ProviderUsage(fiveHour: nil, sevenDay: nil)).reachingLimit(at: eventTime)
                    saving = [.saveUsage(state.usage)]
                    // Nothing of the reply has been heard, so the other provider can answer the turn in its place.
                    if reply.finishedLines.isEmpty {
                        let moving = route()
                        if !moving.isEmpty {
                            state.turn = .replying(Reply(request: reply.request, offersRuns: reply.offersRuns))
                            return saving + moving + [.sendTurn(reply.request)]
                        }
                    }
                }
                return saving + endReply(reply, notice: state.talkSetup.cli(for: failed).notice(for: failure))
            }
        case .lineStarted:
            guard case .replying(var reply) = state.turn, case .starting(let beat) = reply.presentation else { return [] }
            reply.presentation = .speaking(beat)
            presentInThread(beat, in: &reply)
            let effects = showNotch(.line(beat.words))
                + (beat.point.flatMap { point($0, on: reply.request.captures) }.map { [$0] } ?? [])
                + gestures(of: beat, in: &reply)
            state.turn = .replying(reply)
            holdOffer(of: beat, in: reply)
            return effects
        case .lineFinished:
            guard case .replying(let reply) = state.turn else { return [] }
            switch reply.presentation {
            case .starting, .speaking: return finishLine(reply)
            case .ready, .reading, .waiting: return []
            }
        case .replyLineRead:
            guard case .replying(let reply) = state.turn, case .reading = reply.presentation else { return [] }
            return finishLine(reply)
        case .talkSetupChosen(let setup):
            // The app restarts both brains on this change, so nothing warm is left behind.
            state.talkSetup = setup
            state.provider = ProviderRouter.route(from: state.provider, choice: setup.choice, usage: state.usage, at: eventTime)
            return []
        case .usageReported(let provider, let usage):
            guard case .direct = state.talkSetup, state.usage[provider] != usage else { return [] }
            state.usage[provider] = usage
            return [.saveUsage(state.usage)] + routeWhileIdle()
        case .runCLIChosen(let cli):
            state.runCLI = cli
            state.runProviderChoice = cli == .codex ? .codex : .claude
            return []
        case .runProviderChosen(let choice):
            state.runProviderChoice = choice
            if let forced = choice.forced { state.runCLI = ProviderCLI(forced) }
            return []
        case .approvalModeChosen(let mode):
            state.approvalMode = mode
            return []
        case .penSoundsChanged(let enabled):
            guard enabled != state.penSounds else { return [] }
            state.penSounds = enabled
            guard !enabled else { return [] }
            penSoundsScheduled = false
            return [.stopPenSounds]
        case .reduceMotionChanged(let reduced):
            state.reduceMotion = reduced
            return []
        case .spokenRepliesChanged(let enabled):
            guard enabled != state.spokenReplies else { return [] }
            state.spokenReplies = enabled
            guard !enabled, case .replying(var reply) = state.turn else { return [] }
            let beat: Beat
            let annotationsPending: Bool
            switch reply.presentation {
            case .starting(let current):
                beat = current
                annotationsPending = true
            case .speaking(let current):
                beat = current
                annotationsPending = false
            case .ready, .waiting, .reading: return []
            }
            reply.presentation = .reading(beat)
            let effects = [.stopSpeaking] + readingEffects(for: beat, in: &reply, gesturesPending: annotationsPending)
            state.turn = .replying(reply)
            return effects
        case .shortcutChosen(let slot, let trigger):
            guard trigger.isValid else {
                state.shortcutError = "Choose one or more of Control, Option, Shift, Command or fn."
                return []
            }
            if let conflict = state.shortcuts.conflict(with: trigger, for: slot) {
                state.shortcutError = "That shortcut conflicts with \(conflict.title). Choose different modifiers."
                return []
            }
            state.shortcutError = nil
            guard state.shortcuts[slot] != trigger else { return [] }
            let stopping = state.turn == .held ? respond(to: .interrupted) : []
            state.shortcuts.set(trigger, for: slot)
            shortcutMatcher = ShortcutMatcher(shortcuts: state.shortcuts, modifiersHeld: shortcutMatcher.modifiersHeld)
            return stopping + [.saveShortcuts(state.shortcuts.encoded())]
        case .lineFailed:
            guard case .replying(var reply) = state.turn, case .starting(let beat) = reply.presentation else { return [] }
            guard reply.voice?.kokoroID != nil else {
                // Nothing falls back from the Apple voice, so its failed line is skipped.
                reply.presentation = .ready
                return advance(reply)
            }
            reply.voice = .apple
            state.turn = .replying(reply)
            return [.speak(beat.words, voice: .apple, speed: reply.speechSettings?.speed ?? state.speechSettings.speed)]
        case .voicesObserved(let voices):
            state.availableVoices = [.apple] + voices.filter { $0 != .apple }.reduce(into: [Voice]()) { result, voice in
                if !result.contains(voice) { result.append(voice) }
            }
            return []
        case .speechSettingsChanged(let settings):
            guard settings.isValid, settings != state.speechSettings else { return [] }
            state.speechSettings = settings
            return [.saveSpeechSettings(settings.encoded())]
        case .voicePreviewRequested(let voice):
            guard state.availableVoices.contains(voice), voice == .apple || state.neuralVoice == .ready else { return [] }
            return [.previewVoice("Hello. I'm Buddy, your buddy on your Mac.", voice: voice, speed: state.speechSettings.speed)]
        case .neuralVoiceObserved(let status):
            state.neuralVoice = status
            return []
        case .listeningFailed(let message):
            guard state.turn == .held else { return [] }
            return endTurn(notice: message)
        case .captureFailed(let message):
            guard case .capturing = state.turn else { return [] }
            return endTurn(notice: message)
        case .permissionsObserved(let snapshot):
            let lostInputMonitoring = state.permissions.inputMonitoring == .granted
                && snapshot.inputMonitoring != .granted
            state.permissions = snapshot
            if lostInputMonitoring { shortcutMatcher.cancel() }
            if lostInputMonitoring && state.turn == .held {
                return stopTurn(becoming: .idle) + [.hideBuddy] + showNotch(.idle)
            }
            return []
        case .permissionRequested(let permission):
            switch state.permissions[permission] {
            case .unknown, .granted:
                return []
            case .restricted:
                let message = "\(permission.title) access is restricted by macOS."
                state.notice = message
                return showNotch(.notice(message))
            case .denied:
                return [.openPermissionSettings(permission)]
            case .notDetermined, .notGranted:
                guard attemptedPrompts.insert(permission).inserted else {
                    return [.openPermissionSettings(permission)]
                }
                return [.requestPermission(permission)]
            }
        case .loginItemObserved(let status):
            state.loginItem = status
            return []
        case .launchAtLoginRequested(let enabled):
            guard !state.loginChangePending else { return [] }
            if enabled && state.loginItem == .requiresApproval {
                return [.openLoginItemSettings]
            }
            guard enabled != (state.loginItem == .on)
                || (!enabled && state.loginItem == .requiresApproval) else { return [] }
            state.loginChangePending = true
            return [.setLaunchAtLogin(enabled)]
        case .loginItemChangeFinished(let status, let error):
            state.loginChangePending = false
            state.loginItem = status
            guard let error else { return [] }
            state.notice = error
            return showNotch(.notice(error))
        case .modifiersChanged(let held, let time, let otherInputHeld, let tapsAllowed):
            let matches = shortcutMatcher.modifiersChanged(held, at: time, otherInputHeld: otherInputHeld, tapsAllowed: tapsAllowed)
            return matches.flatMap { match in
                switch match {
                case .began(.talk): return respond(to: .pushToTalkPressed)
                case .ended(.talk): return respond(to: .pushToTalkReleased)
                case .tapped(.talk): return respond(to: state.turn == .held ? .pushToTalkReleased : .pushToTalkPressed)
                case .began(.textBox), .tapped(.textBox): return toggleTextBox()
                case .cancelled(.talk): return respond(to: .interrupted)
                case .ended(.textBox), .cancelled(.textBox): return []
                }
            }
        case .keyOrButtonPressed:
            return shortcutMatcher.keyOrButtonPressed() ? respond(to: .interrupted) : []
        case .clicked(let spot):
            let stopping = shortcutMatcher.keyOrButtonPressed() ? respond(to: .interrupted) : []
            return stopping + click(at: spot)
        case .typingRefused:
            let message = "I didn't type that, because secure input is on, as in a password field."
            if state.turn == .idle { state.notice = message }
            return showNotch(.notice(message))
        case .textBoxSubmitted(let text):
            guard state.turn == .typing || state.notchConversation.focused else { return [] }
            let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return [] }
            let starting = state.turn == .typing ? [] : beginTurn(as: .typing)
            state.notchConversation.draft = ""
            state.notchConversation.focused = false
            state.notchConversation.closeIfUnused()
            let closing = starting + expireConversation() + [.hideTextBox]
            guard providerConnected else { return closing + endTurn(notice: "No provider connected.") }
            return closing + [.showBuddy] + showNotch(.thinking) + ask(question)
        case .textBoxDismissed:
            guard state.notchConversation.focused else { return [] }
            state.notchConversation.focused = false
            state.notchConversation.closeIfUnused()
            guard state.turn == .typing else { return [] }
            return stopTurn(becoming: .idle)
        case .interrupted:
            shortcutMatcher.cancel()
            state.notchConversation.isOpen = false
            state.notchConversation.focused = false
            state.notchConversation.hoverBegan = nil
            let released = takeScreenBack(remindingOfWaitingRuns: true)
            let papers = clearPapers(keepingPinned: false)
            state.runOffer = nil
            if state.turn == .idle, state.notice == nil { return released + papers + clearAnnotations() + showNotch(.idle) }
            return released + papers + stopTurn(becoming: .idle) + [.hideBuddy] + showNotch(.idle)
        case .noticeExpired:
            guard case .notice = notch, state.turn == .idle || state.turn == .typing else { return [] }
            state.notice = nil
            return (state.turn == .idle ? [.hideBuddy] : []) + showNotch(.idle)
        case .clockTick:
            if !offerIsFresh { state.runOffer = nil }
            if case .replying(var reply) = state.turn, case .waiting(_, let since) = reply.presentation,
               eventTime.timeIntervalSince(since) >= Self.targetWait {
                let cancelling: [Effect] = reply.streaming ? [.cancelReply] : []
                reply.streaming = false
                reply.presentation = .ready
                // Only a click asks again. The timeout stops the walkthrough.
                reply.asksAgainAtEnd = false
                reply.pending = [Beat(words: Self.walkthroughTimeout, point: nil, annotations: [])]
                return cancelling + clearAnnotations() + advance(reply)
            }
            return expireConversation() + routeWhileIdle()
        case .clearHistoryRequested:
            guard !state.historyClearPending else { return [] }
            let stopping = stopEffects() + clearPapers(keepingPinned: false) + clearAnnotations() + (summaryInFlight == nil ? [] : [.cancelSummary])
            summaryInFlight = nil
            summaryFailed = false
            state.turn = .idle
            state.notice = nil
            heldWalkthrough = nil
            state.history = ConversationHistory()
            state.notchConversation.entries = []
            state.notchConversation.draft = ""
            state.notchConversation.focused = false
            state.notchConversation.isOpen = false
            state.notchConversation.hoverBegan = nil
            state.runOffer = nil
            state.historyClearPending = true
            state.historyCleared = false
            return stopping + [.cancelCapture] + resetProvider() + [.hideBuddy] + showNotch(.idle) + [.clearHistory]
        case .historyCleared(let error):
            guard state.historyClearPending else { return [] }
            state.historyClearPending = false
            state.historyError = error
            state.historyCleared = error == nil
            guard let error else { return [] }
            state.notice = error
            return showNotch(.notice(error))
        case .historyFailed(let error):
            state.historyError = error
            state.notice = error
            return showNotch(.notice(error))
        case .historySaved:
            state.historyError = nil
            return []
        case .summaryWritten(let id, let text):
            guard let request = summaryInFlight, request.id == id else { return [] }
            summaryInFlight = nil
            let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else {
                summaryFailed = !providerChangedDuringSummary
                return []
            }
            state.history.summarize(request.conversation, as: summary, adding: request.turns.count)
            return [.saveHistory(state.history)]
        case .summaryFailed(let id):
            guard summaryInFlight?.id == id else { return [] }
            summaryInFlight = nil
            summaryFailed = !providerChangedDuringSummary
            return []
        case .providerChanged:
            primedSummaries = nil
            if summaryInFlight != nil { providerChangedDuringSummary = true }
            return summarize(retrying: true)
        case .clearProfileRequested:
            guard !state.profileClearPending else { return [] }
            state.profile = Profile()
            state.profileClearPending = true
            state.profileCleared = false
            return [.clearProfile]
        case .profileCleared(let error):
            guard state.profileClearPending else { return [] }
            state.profileClearPending = false
            state.profileError = error
            state.profileCleared = error == nil
            guard let error else { return [] }
            state.notice = error
            return showNotch(.notice(error))
        case .profileFailed(let error):
            state.profileError = error
            state.notice = error
            return showNotch(.notice(error))
        case .profileSaved:
            state.profileError = nil
            return []
        case .run(let id, let event):
            return handle(event, of: id)
        case .runStopRequested(let id):
            return stop(id, .owner)
        case .runApprovalAnswered(let id, let requestID, let approved):
            return answerApproval(requestID, approved: approved, of: id)
        case .runQuestionAnswered(let id, let call, let answer):
            return answerQuestion(call, with: answer, of: id)
        case .runTakeoverAnswered(let id, let call, let approved):
            return answerTakeover(call, approved: approved, of: id)
        case .runTimeUp(let id):
            return stop(id, .timeCap)
        case .runDismissed(let id):
            state.runs.removeAll { $0.id == id && !$0.isActive }
            return []
        }
    }

    /// A finished question, spoken or typed. A continue phrase resumes a held walkthrough, checked first so "okay"
    /// continues it rather than answering a run's question or accepting a run offer. "New conversation" ends the
    /// conversation, the oldest question a run is waiting on takes the turn as its answer, and a yes to a run offer starts
    /// the offered run. Anything else is asked with a capture of the screens. Either way the offer is used up.
    private mutating func ask(_ question: String) -> [Effect] {
        let offer = offerIsFresh ? state.runOffer : nil
        state.runOffer = nil
        let walkthrough = heldWalkthrough
        heldWalkthrough = nil
        if var walkthrough, Self.saysContinue(question) {
            walkthrough.presentation = .ready
            return advance(walkthrough)
        }
        if question.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?"))).lowercased() == "new conversation" {
            state.turn = .idle
            let ending = endConversation()
            state.notice = "Started a new conversation."
            let effects = ending + showNotch(.notice("Started a new conversation."))
            state.notchConversation.entries = []
            return effects
        }
        state.notchConversation.entries.append(.owner(question))
        if let call = state.questionTakingNextTurn, let run = state.runs.first(where: { $0.waitingQuestion == call }) {
            return answerQuestion(call, with: question, of: run.id)
                + say("Thanks, I'll pass that on to agent run \(run.id.number).", for: TurnRequest(transcript: question, captures: []))
        }
        if let offer, Self.accepts(question) {
            return startRun(offer, answering: TurnRequest(transcript: question, captures: offer.captures))
        }
        state.turn = .capturing(transcript: question)
        return [.captureScreens]
    }

    /// The beats read, followed by those of the draw program read with them.
    private func beats(of read: ReplyReader.Read, answering request: TurnRequest) -> Result<[Beat], DrawFailure> {
        guard let source = read.program else { return .success(read.lines.beats) }
        guard let canvas = request.captures.drawCanvas else { return .failure(.noScreen) }
        return drawSandbox.run(source, width: canvas.pixelWidth, height: canvas.pixelHeight).map { read.lines.beats + $0 }
    }

    /// Applies a talk reply's REMEMBER and FORGET tags. Agent runs never change the profile.
    private mutating func applyProfileEdits(_ edits: [ProfileEdit]) -> [Effect] {
        let before = state.profile
        for profileEdit in edits { state.profile.apply(profileEdit) }
        guard state.profile != before else { return [] }
        state.profileCleared = false
        return [.saveProfile(state.profile)]
    }

    /// Whether the whole answer is a yes, such as "yes", "yeah, go ahead" or "OK, do it". A yes with conditions, a
    /// number or a question mark is not.
    private static func accepts(_ answer: String) -> Bool {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") else { return false }
        let words = answer.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.joined(separator: " ")
        let yes = /(?:(?:yes|yeah|yep|yup|sure|ok|okay|do it|please do|go ahead|go for it|sounds good)(?: please)?(?: |$))+/
        return words.wholeMatch(of: yes) != nil
    }

    private mutating func advance(_ reply: Reply) -> [Effect] {
        var reply = reply
        if reply.presentation == .ready, !reply.pending.isEmpty {
            let beat = reply.pending.removeFirst()
            reply.presentedLines.append(beat.words)
            if !state.spokenReplies {
                reply.presentation = .reading(beat)
                let effects = readingEffects(for: beat, in: &reply)
                state.turn = .replying(reply)
                return effects
            }
            if let settings = reply.speechSettings, settings.voice != state.speechSettings.voice { reply.voice = nil }
            reply.speechSettings = state.speechSettings
            let voice = reply.voice ?? (state.neuralVoice == .ready ? state.speechSettings.voice : .apple)
            reply.voice = voice
            reply.presentation = .starting(beat)
            state.turn = .replying(reply)
            return [.speak(beat.words, voice: voice, speed: state.speechSettings.speed)]
        }
        guard reply.presentation != .ready || reply.streaming else {
            if reply.asksAgainAtEnd {
                // This new turn doesn't go through `ask`, so it uses up the offer here, as any next turn does.
                state.runOffer = nil
                state.turn = .capturing(transcript: Self.continuationQuestion)
                return showNotch(.thinking) + [.captureScreens]
            }
            state.turn = .idle
            let closing = notch == .thinking && reply.threadLines > 0 ? showNotch(.closing) : closeNotch()
            if let id = runOnScreen, !(runInDock(id)?.isActive ?? false) {
                return activity() + clearRunFromScreen() + [.hideBuddy] + closing
            }
            return activity() + [.hideBuddy] + closing
        }
        state.turn = .replying(reply)
        return reply.presentation == .ready && !reply.asksAgainAtEnd ? showNotch(.thinking) : []
    }

    /// Ends the presentation of the current line. A line whose target is still unclicked holds the lines after it.
    private mutating func finishLine(_ reply: Reply) -> [Effect] {
        var reply = reply
        let target = reply.target
        reply.target = nil
        switch target {
        case .armed(let area):
            reply.presentation = .waiting(area, since: eventTime)
            state.turn = .replying(reply)
            return []
        case .clicked:
            return continueWalkthrough(reply)
        case nil:
            reply.presentation = .ready
            return advance(reply)
        }
    }

    private mutating func click(at spot: DisplayPoint) -> [Effect] {
        guard case .replying(var reply) = state.turn else { return [] }
        if case .waiting(let area, _) = reply.presentation {
            guard area.contains(spot) else { return [] }
            return clearAnnotations() + continueWalkthrough(reply)
        }
        guard case .armed(let area) = reply.target, area.contains(spot) else { return [] }
        reply.target = .clicked
        state.turn = .replying(reply)
        return clearAnnotations()
    }

    /// After a click on a target, the next line plays. When the target was the reply's last line, the next step can
    /// only be seen on the screen as it is now, so the reply ends by asking again with a fresh capture.
    private mutating func continueWalkthrough(_ reply: Reply) -> [Effect] {
        var reply = reply
        reply.presentation = .ready
        reply.asksAgainAtEnd = reply.pending.isEmpty
        return advance(reply)
    }

    private static func saysContinue(_ question: String) -> Bool {
        let words = question.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).joined(separator: " ")
        return ["continue", "go on", "keep going", "next", "next step", "ok", "okay", "done", "got it", "i did it",
                "i clicked it"].contains(words)
    }

    private static func runRequest(in transcript: String) -> String? {
        guard let match = transcript.prefixMatch(of: /(?i)\s*agent\b[\s\p{P}]*/) else { return nil }
        return String(transcript[match.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Each run gets its own card at the end of the dock and its own provider process, alongside any already going.
    private mutating func startRun(_ brief: RunBrief, answering turn: TurnRequest) -> [Effect] {
        runsStarted += 1
        let id = RunID(runsStarted)
        state.runCLI = ProviderCLI(ProviderRouter.route(
            from: state.runCLI.provider, choice: state.runProviderChoice, usage: state.usage, at: eventTime
        ))
        state.runs.append(AgentRun(
            id: id, brief: brief, cli: state.runCLI, approvalMode: state.approvalMode,
            limits: runLimits, allowsFallback: state.runProviderChoice == .auto
        ))
        return [.startRun(id, brief, state.runCLI, state.approvalMode), .scheduleRunTimeUp(id, seconds: runLimits.seconds), .playCue(.launch)]
            + say("On it. I'll work on that in the background.", for: turn)
    }

    /// The run with this id while its card is in the dock.
    private func runInDock(_ id: RunID) -> AgentRun? {
        state.runs.first { $0.id == id }
    }

    /// Replaces the run's card in the dock with this version of it.
    private mutating func put(_ run: AgentRun) {
        guard let index = state.runs.firstIndex(where: { $0.id == run.id }) else { return }
        state.runs[index] = run
    }

    private mutating func say(_ line: String, for turn: TurnRequest) -> [Effect] {
        state.history.append(TurnRecord(transcript: turn.transcript, reply: line), at: eventTime)
        return [.saveHistory(state.history)] + play([Beat(words: line)], answering: turn)
    }

    private mutating func play(_ beats: [Beat], answering request: TurnRequest) -> [Effect] {
        var reply = Reply(request: request, streaming: false)
        reply.add(beats)
        return advance(reply)
    }

    private mutating func handle(_ event: RunEvent, of id: RunID) -> [Effect] {
        guard var run = runInDock(id), run.isActive else {
            return event.toolCall.map { [.answerTool($0, .error("This run has ended."))] } ?? []
        }
        if run.continuation != nil {
            switch event {
            case .started, .failed: break
            default:
                return event.toolCall.map { [.answerTool($0, .error("This run is switching providers."))] } ?? []
            }
        }
        switch event {
        case .started(let folder):
            run.folder = folder
            if run.resuming {
                run.continuation = nil
                run.resuming = false
                run.giveBackScreen(nil)
            }
            put(run)
            return []
        case .approvalRequested(let requestID, let request):
            guard let folder = run.folder else { return [] }
            let verdict = ApprovalPolicy(
                folder: resolvePath(folder) ?? "", home: resolvePath(home) ?? "", fileExists: fileExists, resolvePath: resolvePath
            ).decide(request, in: run.approvalMode)
            switch verdict {
            case .allow:
                return [.answerApproval(id, id: requestID, .allow)]
            case .deny(let reason):
                return deny(requestID, action: request.action, note: reason, answer: reason, in: run)
            case .askOwner(let reason):
                return wait(for: .approval(id: requestID, action: request.action, reason: reason), in: run)
            }
        case .toolUsed:
            run.countStep()
            return update(run)
        case .toolCalled(let call, .captureScreen):
            return [.captureScreensForTool(id, call)]
        case .screensCaptured(let call, let captures):
            run.captures = captures
            put(run)
            return [.answerTool(call, ToolAnswer(content: captures.labeled))]
        case .captureFailed(let call, let message):
            return [.answerTool(call, .error(message))]
        case .toolCalled(let call, .updateRunNote(let note)):
            run.note = note
            put(run)
            return [.saveRunNote(id, run.noteDocument), .answerTool(call, .text("Saved the run note."))]
        case .toolCalled(let call, .showBeats(let lines)):
            return show(lines, of: run, answering: call)
        case .toolCalled(let call, .askOwner(let question, let choices)):
            let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return [.answerTool(call, .error("There was no question to ask."))] }
            var offered: [String] = []
            for choice in choices.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            where !choice.isEmpty && !offered.contains(choice) {
                offered.append(choice)
            }
            return wait(for: .question(call, question, choices: offered), in: run)
        case .toolCalled(let call, .beginTakeover(let reason)):
            let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else {
                return [.answerTool(call, .error("Say why you need the screen, so your owner can decide."))]
            }
            guard run.status != .takingOver else {
                return [.answerTool(call, .text("You already have the mouse and keyboard."))]
            }
            guard !run.awaitsTakeover else {
                return [.answerTool(call, .error("Your owner hasn't answered your last request for the screen yet."))]
            }
            return wait(for: .takeover(call, reason: reason), in: run)
        case .toolCalled(let call, .screen(let action)):
            guard run.status == .takingOver else {
                return [.answerTool(call, .error(run.screenReturn ?? "You don't have the screen. Ask for it with begin_takeover first."))]
            }
            if case .type("") = action { return [.answerTool(call, .error("There was no text to type."))] }
            do {
                return [.act(id, call, try action.map(run.captures.displayPoint(for:)))]
            } catch {
                return [.answerTool(call, .error(error.message))]
            }
        case .acted(let call, let failure):
            return [.answerTool(call, failure.map(ToolAnswer.error) ?? .text("Done. Check the result with capture_screen before you go on."))]
        case .toolCalled(let call, .endTakeover):
            guard run.status == .takingOver else { return [.answerTool(call, .text("You didn't have the screen."))] }
            run.giveBackScreen(nil)
            put(run)
            return screenReturned(by: id) + [.answerTool(call, .text("You gave the screen back to your owner."))]
        case .takeoverFailed(let message):
            guard run.status == .takingOver else { return [] }
            run.giveBackScreen(message)
            put(run)
            return screenReturned(by: id) + notify(message)
        case .finished(let report):
            run.end(.done)
            run.report = report
            return update(run)
        case .failed(let failure):
            if failure == .limitReached { return reachedLimit(in: run, partialReport: "") }
            run.end(.failed(run.cli.notice(for: failure)))
            return update(run)
        case .limitReached(let report):
            return reachedLimit(in: run, partialReport: report)
        }
    }

    private mutating func reachedLimit(in run: AgentRun, partialReport: String) -> [Effect] {
        guard run.continuation == nil else { return [] }
        var run = run
        let provider = run.cli.provider
        state.usage[provider] = (state.usage[provider] ?? ProviderUsage(fiveHour: nil, sevenDay: nil)).reachingLimit(at: eventTime)
        let saved: [Effect] = [.saveUsage(state.usage)]
        let next = ProviderRouter.route(from: provider, choice: .auto, usage: state.usage, at: eventTime)
        guard run.allowsFallback, next != provider, !run.attemptedProviders.contains(next) else {
            run.end(.failed(run.cli.notice(for: .limitReached)))
            return saved + update(run)
        }
        let heldScreen = run.status == .takingOver
        run.cli = ProviderCLI(next)
        run.attemptedProviders.insert(next)
        run.switchNotes.append("\(provider.title) reached its limit. Switched to \(next.title); continuing from the saved progress.")
        run.continuation = RunContinuation(note: run.noteDocument, partialReport: partialReport)
        run.resuming = false
        run.statusForHandoff()
        put(run)
        return saved + (heldScreen ? [.endTakeover(run.id)] : [])
            + [.pauseRun(run.id), .saveRunNote(run.id, run.noteDocument), .saveRunReport(run.id, partialReport)]
            + resumeIfReady(run)
    }

    private mutating func resumeIfReady(_ run: AgentRun) -> [Effect] {
        guard let continuation = run.continuation, run.asks.isEmpty, !run.resuming else { return [] }
        var run = run
        run.statusForHandoff()
        run.resuming = true
        put(run)
        let brief = RunBrief(request: run.brief.request, captures: run.brief.captures, continuation: RunContinuation(
            note: run.noteDocument, partialReport: continuation.partialReport
        ))
        return [.resumeRun(run.id, brief, run.cli, run.approvalMode)]
    }

    private mutating func answerQuestion(_ call: ToolCallID, with answer: String, of id: RunID) -> [Effect] {
        guard var run = runInDock(id),
              let ask = run.asks.first(where: { if case .question(call, _, _) = $0 { true } else { false } }),
              case .question(_, let question, _) = ask, run.takeQuestion(call) != nil else { return [] }
        if run.continuation != nil {
            run.switchNotes.append("Your owner answered \"\(question)\": \(answer)")
            put(run)
            return [.saveRunNote(id, run.noteDocument)] + resumeIfReady(run)
        }
        put(run)
        return [Self.answer(call, with: answer)]
    }

    private mutating func stop(_ id: RunID, _ reason: RunStop) -> [Effect] {
        guard var run = runInDock(id), run.isActive else { return [] }
        run.end(.stopped(reason))
        return update(run)
    }

    /// The run waits for the owner, and Buddy plays its cue when the run starts waiting. A run holding the screen gives
    /// it back first, so the owner can answer.
    private mutating func wait(for ask: OwnerAsk, in run: AgentRun) -> [Effect] {
        var run = run
        var released: [Effect] = []
        if run.status == .takingOver {
            run.giveBackScreen(
                "Buddy gave your owner the screen back so they could answer you. Ask again with begin_takeover if you still need it."
            )
            released = [.endTakeover(run.id)]
        }
        let alreadyWaiting = run.status == .needsOwner
        run.wait(for: ask)
        put(run)
        return released + (alreadyWaiting ? [] : [.playCue(.needsOwner)])
    }

    /// The run holding the screen, if one does. Only one run at a time can.
    private var runHoldingScreen: AgentRun? {
        state.runs.first { $0.status == .takingOver }
    }

    /// The owner's Esc or push-to-talk takes the screen back from the run holding it.
    private mutating func takeScreenBack(remindingOfWaitingRuns remind: Bool) -> [Effect] {
        guard var run = runHoldingScreen else { return [] }
        run.giveBackScreen("Your owner took back the screen. Ask again with begin_takeover only if you still need it.")
        put(run)
        return remind ? screenReturned(by: run.id) : [.endTakeover(run.id)]
    }

    /// Ends the takeover of a run that keeps going. The owner couldn't answer other runs' cards while their input was
    /// blocked, so the needs-owner cue plays again when another run is waiting. A run that ends plays its own done cue
    /// instead.
    private func screenReturned(by id: RunID) -> [Effect] {
        let othersWait = state.runs.contains { $0.id != id && $0.status == .needsOwner }
        return [.endTakeover(id)] + (othersWait ? [.playCue(.needsOwner)] : [])
    }

    /// The owner's answer to a run's request for the screen. While another run holds the screen, Allow leaves the
    /// request waiting on the card, so the run stays in needs-owner until the owner allows it again.
    private mutating func answerTakeover(_ call: ToolCallID, approved: Bool, of id: RunID) -> [Effect] {
        guard var run = runInDock(id), let reason = run.takeTakeover(call) else { return [] }
        if run.continuation != nil {
            if approved {
                run.switchNotes.append("Your owner allowed the old request for the screen: \(reason). Ask for fresh screen consent after the switch.")
            } else {
                run.denials.append(Denial(action: "Take over the screen: \(reason)", reason: "You said no."))
            }
            put(run)
            return [.saveRunNote(id, run.noteDocument)] + resumeIfReady(run)
        }
        if approved, let holder = runHoldingScreen {
            return notify("“\(holder.name)” is using the screen. Allow this run after it gives the screen back.")
        }
        put(run)
        guard approved else {
            run.denials.append(Denial(action: "Take over the screen: \(reason)", reason: "You said no."))
            put(run)
            return [
                .saveRunNote(id, run.noteDocument),
                .answerTool(call, .text("Your owner said no. Don't take over the screen; finish another way or explain in your report."))
            ]
        }
        guard run.asks.isEmpty else {
            return [.answerTool(call, .error(
                "Your owner allowed it, but they still have to answer your other request. Ask again with begin_takeover after that."
            ))]
        }
        guard state.permissions.accessibility == .granted else {
            return notify("Buddy needs Accessibility permission to use the mouse and keyboard.") + [.answerTool(call, .error(
                "Buddy needs Accessibility permission to use the mouse and keyboard, so you don't have the screen. Finish another way or explain in your report."
            ))]
        }
        run.takeOver()
        put(run)
        return [
            .beginTakeover(id),
            .answerTool(call, .text(
                "You have the mouse and keyboard now. Your owner's own input is blocked until you call end_takeover, and they can take back control at any time."
            ))
        ]
    }

    private mutating func notify(_ message: String) -> [Effect] {
        if state.turn == .idle { state.notice = message }
        return showNotch(.notice(message))
    }

    private mutating func answerApproval(_ requestID: String, approved: Bool, of id: RunID) -> [Effect] {
        guard var run = runInDock(id), let action = run.takeApproval(requestID) else { return [] }
        if run.continuation != nil {
            if approved {
                run.switchNotes.append("Your owner approved `\(action)` for the stopped process. Request fresh approval before acting after the switch.")
            } else {
                run.denials.append(Denial(action: action, reason: "You said no."))
            }
            put(run)
            return [.saveRunNote(id, run.noteDocument)] + resumeIfReady(run)
        }
        guard !approved else {
            put(run)
            return [.answerApproval(id, id: requestID, .allow)]
        }
        return deny(requestID, action: action, note: "You said no.", answer: "Your owner said no. Don't retry it or work around it.", in: run)
    }

    /// Records the denial in the run note with `note`, then answers the run with `answer`, so the note is current when
    /// the run reads the answer.
    private mutating func deny(
        _ requestID: String, action: String, note: String, answer: String, in run: AgentRun
    ) -> [Effect] {
        var run = run
        run.denials.append(Denial(action: action, reason: note))
        put(run)
        return [.saveRunNote(run.id, run.noteDocument), .answerApproval(run.id, id: requestID, .deny(answer))]
    }

    private static func answer(_ call: ToolCallID, with answer: String) -> Effect {
        .answerTool(call, .text("Your owner answered: \(answer)"))
    }

    /// Saves the run, and once it has ended stops its process and saves its report, after giving back the screen if it
    /// held it. A run that ends by itself, rather than by the owner's Stop, plays the done cue.
    private mutating func update(_ run: AgentRun) -> [Effect] {
        let releases = runInDock(run.id)?.status == .takingOver && !run.isActive
        put(run)
        let released: [Effect] = releases ? [.endTakeover(run.id)] : []
        guard let report = run.reportDocument else { return released }
        let cue: [Effect] = run.status == .stopped(.owner) ? [] : [.playCue(.done)]
        return released + [.stopRun(run.id), .saveRunReport(run.id, report)] + cue + leaveScreen(of: run.id)
    }

    /// A run that ends takes its lines and marks off the screen. A line still playing finishes first.
    private mutating func leaveScreen(of id: RunID) -> [Effect] {
        guard runOnScreen == id, state.turn == .idle else { return [] }
        return clearRunFromScreen()
    }

    private mutating func clearRunFromScreen() -> [Effect] {
        runOnScreen = nil
        return clearAnnotations()
    }

    private mutating func show(_ lines: String, of run: AgentRun, answering call: ToolCallID) -> [Effect] {
        var parser = BeatParser()
        let beats = (parser.feed(lines) + parser.finish()).beats.map(\.shownOnly)
        guard !beats.isEmpty else { return [.answerTool(call, .error("There were no lines to show."))] }
        guard state.turn == .idle else {
            return [.answerTool(call, .error("Buddy is talking right now, so nothing was shown."))]
        }
        state.notice = nil
        state.runOffer = nil
        runOnScreen = run.id
        let showing = beats.count == 1 ? "Showing 1 line." : "Showing \(beats.count) lines."
        return [.showBuddy] + play(beats, answering: TurnRequest(transcript: run.brief.request, captures: run.captures))
            + [.answerTool(call, .text(showing))]
    }

    private mutating func readingEffects(for beat: Beat, in reply: inout Reply, gesturesPending: Bool = true) -> [Effect] {
        presentInThread(beat, in: &reply)
        let marks = gesturesPending ? gestures(of: beat, in: &reply) : []
        holdOffer(of: beat, in: reply)
        let seconds = min(20, max(3, Double(beat.words.split(whereSeparator: \.isWhitespace).count) / 3 + 1))
        return showNotch(.line(beat.words))
            + (beat.point.flatMap { point($0, on: reply.request.captures) }.map { [$0] } ?? [])
            + marks + [.waitForReading(.seconds(seconds))]
    }

    private mutating func presentInThread(_ beat: Beat, in reply: inout Reply) {
        guard reply.threadLines < reply.presentedLines.count else { return }
        state.notchConversation.entries.append(.buddy(beat.words))
        reply.threadLines = reply.presentedLines.count
    }

    /// The date where the owner is, such as "Sunday, November 1, 2026", or nil without their time zone.
    private var today: String? {
        timeZone.map { eventTime.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: Locale(identifier: "en_US"), timeZone: $0)) }
    }

    private var offerIsFresh: Bool {
        runOfferHeldAt.map { eventTime.timeIntervalSince($0) < Self.idleLimit } ?? false
    }

    /// A yes answers the last question Buddy asked. A line offers a run only when it asks a question, and a later
    /// question in the same reply drops the offer.
    private mutating func holdOffer(of beat: Beat, in reply: Reply) {
        guard reply.offersRuns, beat.words.hasSuffix("?") else { return }
        state.runOffer = beat.offeredBrief.map { RunBrief(request: $0, captures: reply.request.captures) }
        runOfferHeldAt = eventTime
    }

    /// The annotations, the draw program's marks, the target's ring and the typing that fire as a line starts. The target is armed for the line.
    private mutating func gestures(of beat: Beat, in reply: inout Reply) -> [Effect] {
        let captures = reply.request.captures
        var marks = beat.annotations.compactMap { annotate($0, on: captures) } + draw(beat.drawMarks, on: captures)
        if let tag = beat.target, let capture = captures.capture(for: tag.screen) {
            let from = capture.displayPoint(tag.gesture.from)
            let to = capture.displayPoint(tag.gesture.to)
            marks.append(.annotate(.shape(.ring, from: from, to: to), on: capture.display))
            reply.target = .armed(TargetArea(from, to))
        }
        if !marks.isEmpty { state.annotationsShown = true }
        guard let tag = beat.typing, let capture = captures.capture(for: tag.screen) else { return marks }
        guard state.permissions.accessibility == .granted else {
            return marks + showNotch(.notice("Buddy needs Accessibility permission to type for you."))
        }
        return marks + [.type(tag.gesture.text, at: capture.displayPoint(tag.gesture.pixel))]
    }

    private func stopPresentation(_ reply: Reply) -> [Effect] {
        switch reply.presentation {
        case .ready, .waiting: []
        case .starting, .speaking: [.stopSpeaking]
        case .reading: [.cancelReading]
        }
    }

    private func point(_ tag: Tag<PointGesture>, on captures: [ScreenCapture]) -> Effect? {
        guard let capture = captures.capture(for: tag.screen) else { return nil }
        return .point(capture.displayPoint(tag.gesture.pixel), on: capture.display, label: tag.gesture.label)
    }

    private func annotate(_ tag: Tag<Annotation<PixelPoint>>, on captures: [ScreenCapture]) -> Effect? {
        guard let capture = captures.capture(for: tag.screen) else { return nil }
        return .annotate(tag.gesture.map(capture.displayPoint), on: capture.display)
    }

    private mutating func draw(_ marks: [DrawMark<PixelPoint>], on captures: [ScreenCapture]) -> [Effect] {
        guard !marks.isEmpty, let canvas = captures.drawCanvas else { return [] }
        let scale = canvas.display.height / Double(canvas.pixelHeight)
        let mapped = marks.map { mark -> DrawMark<DisplayPoint> in
            let mapped = mark.map(scale: scale, canvas.displayPoint)
            guard case .paper(var paper) = mapped else { return mapped }
            paper.id = nextPaperID
            nextPaperID += 1
            state.papers.append(PlacedPaper(paper: paper, display: canvas.display))
            return .paper(paper)
        }
        let drawing: [Effect] = [.draw(mapped, on: canvas.display)]
        guard state.penSounds else { return drawing }
        var offset = 0.0
        var cues: [PenSoundCue] = []
        for mark in mapped {
            let duration = mark.revealDuration
            switch mark {
            case .text, .paper: break
            case .stroke, .arrow, .ring, .handwriting:
                cues.append(PenSoundCue(offset: state.reduceMotion ? 0 : offset, duration: state.reduceMotion ? 0.08 : duration))
            }
            offset += duration
        }
        if !cues.isEmpty { penSoundsScheduled = true }
        return drawing + (cues.isEmpty ? [] : [.playPenSounds(cues)])
    }

    /// A reply that failed, or whose draw program failed, stops at once and drops any run it offered.
    private mutating func endReply(_ reply: Reply, notice: String) -> [Effect] {
        state.runOffer = nil
        return stopPresentation(reply) + endTurn(notice: notice)
    }

    private mutating func endTurn(notice: String) -> [Effect] {
        state.turn = .idle
        state.notice = notice
        return activity() + showNotch(.notice(notice))
    }

    private mutating func showNotch(_ next: Notch) -> [Effect] {
        guard next != notch else { return [] }
        notch = next
        if case .notice(let words) = next { state.notchConversation.entries.append(.notice(words)) }
        return [.showNotch(next)]
    }

    /// A strip with a line or a notice stays up a few seconds after the reply, so its end can still be read.
    private mutating func closeNotch() -> [Effect] {
        switch notch {
        case .line, .notice: showNotch(.closing)
        case .idle, .listening, .thinking, .closing: showNotch(.idle)
        }
    }

    private mutating func toggleTextBox() -> [Effect] {
        guard runHoldingScreen == nil else { return [] }
        if state.turn == .typing || state.notchConversation.focused {
            state.notchConversation.isOpen = false
            state.notchConversation.hoverBegan = nil
            if state.turn == .typing { return stopTurn(becoming: .idle) }
            state.notchConversation.focused = false
            return [.hideTextBox]
        }
        return respond(to: .textBoxFocused)
    }

    /// Starts a turn as a press does: a conversation idle for ten minutes ends first, then whatever was running stops.
    private mutating func beginTurn(as phase: TurnPhase) -> [Effect] {
        state.notchConversation.page = .thread
        let boundary = expireConversation()
        state.historyCleared = false
        var walkthrough: Reply?
        if case .replying(let reply) = state.turn, case .waiting = reply.presentation, !reply.streaming,
           !reply.pending.isEmpty {
            walkthrough = reply
        }
        state.profileCleared = false
        let effects = boundary + stopTurn(becoming: phase) + activity()
        heldWalkthrough = walkthrough
        return effects
    }

    private mutating func stopTurn(becoming next: TurnPhase) -> [Effect] {
        heldWalkthrough = nil
        runOnScreen = nil
        let stopping = stopEffects() + clearAnnotations()
        state.notchConversation.focused = false
        state.notchConversation.closeIfUnused()
        state.turn = next
        state.notice = nil
        return stopping + (next == .idle ? activity() : [])
    }

    private mutating func clearAnnotations() -> [Effect] {
        let stopping: [Effect] = penSoundsScheduled ? [.stopPenSounds] : []
        penSoundsScheduled = false
        defer { state.annotationsShown = false }
        return stopping + (state.annotationsShown ? [.clearAnnotations] : []) + clearPapers(keepingPinned: true)
    }

    private mutating func clearPapers(keepingPinned: Bool) -> [Effect] {
        let removed = state.papers.filter { !keepingPinned || !$0.pinned }.map { Effect.removePaper($0.paper.id) }
        state.papers.removeAll { !keepingPinned || !$0.pinned }
        return removed
    }

    private mutating func activity() -> [Effect] {
        state.history.touch(at: eventTime) ? [.saveHistory(state.history)] : []
    }

    /// An open text box with nothing sent is idle time, so a box left open can end the conversation too.
    private mutating func expireConversation() -> [Effect] {
        guard state.turn == .idle || state.turn == .typing, let active = state.history.active,
              eventTime.timeIntervalSince(active.lastActivity) >= Self.idleLimit else { return [] }
        _ = state.history.end(at: eventTime)
        state.notchConversation.entries = []
        state.runOffer = nil
        return resetProvider() + [.saveHistory(state.history)]
    }

    private mutating func endConversation() -> [Effect] {
        let saved = state.history.end(at: eventTime) ? [Effect.saveHistory(state.history)] : []
        state.notchConversation.entries = []
        return resetProvider() + saved
    }

    /// While idle, a new report or a passed reset moves the provider now, so the active one shown is where the next
    /// turn goes. Otherwise the move waits for the next turn to start: a turn in flight or being read out may still
    /// use its provider, and an open text box is about to start a turn.
    private mutating func routeWhileIdle() -> [Effect] {
        state.turn == .idle ? route() : []
    }

    /// Picks the provider for the next turn, and leaves the current one when it changes.
    private mutating func route() -> [Effect] {
        let current = state.provider
        state.provider = ProviderRouter.route(from: current, choice: state.talkSetup.choice, usage: state.usage, at: eventTime)
        return state.provider == current ? [] : [.leaveProvider(current)]
    }

    private mutating func resetProvider() -> [Effect] {
        primedSummaries = nil
        return [.resetProvider]
    }

    /// Asks for the next summary that is behind, one at a time. After a failure it waits for `retrying`.
    private mutating func summarize(retrying: Bool) -> [Effect] {
        if retrying { summaryFailed = false }
        guard summaryInFlight == nil, !summaryFailed, !state.historyClearPending,
              let (conversation, turns) = state.history.unsummarized else { return [] }
        summariesRequested += 1
        let request = SummaryRequest(
            id: summariesRequested, conversation: state.history.conversations[conversation].id,
            summary: state.history.conversations[conversation].summary?.text, turns: turns
        )
        summaryInFlight = request
        providerChangedDuringSummary = false
        return [.writeSummary(request)]
    }

    private func stopEffects() -> [Effect] {
        switch state.turn {
        case .held: providerConnected ? [.stopListening] : []
        case .typing: [.hideTextBox]
        case .replying(let reply): (reply.streaming ? [.cancelReply] : []) + stopPresentation(reply)
        case .idle, .transcribing, .capturing: []
        }
    }
}
