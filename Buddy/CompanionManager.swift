import AppKit
import AVFoundation
import BuddyCore
import BuddyVoice
import Combine
import os
import QuartzCore
import ServiceManagement

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var state = BuddyEngine().state
    @Published private(set) var permissionInFlight: Permission?
    @Published private(set) var voicePreviewError: String?
    @Published private(set) var speechModel = SpeechModelStatus.checking
    let connections: TalkConnections

    private lazy var claudeBrain = ClaudeBrain(launch: { [weak self] in self?.claudeLaunch(forUtility: false) })
    private let codexBrain: CodexBrain
    private let codexScreenshots: CodexScreenshotDirectory
    /// The brain the latest turn went to, which a cancel has to reach even after the provider changes.
    private var answering: (any Brain)?
    /// Through CLIProxy, Claude Code's transport answers for both providers.
    private var talkBrains: [any Brain] {
        if case .proxied = engine.state.talkSetup { [claudeBrain] } else { [claudeBrain, codexBrain] }
    }
    private lazy var claudeUtility = UtilityModel(ClaudeBrain(launch: { [weak self] in self?.claudeLaunch(forUtility: true) }))
    private let codexUtility: UtilityModel
    /// The utility model follows the CLI of the provider talk is on. It changes when a summary is asked or the
    /// selection changes, never under a summary in flight.
    private lazy var utility = chosenUtility
    private var chosenUtility: UtilityModel {
        engine.state.talkSetup.cli(for: engine.state.provider) == .codex ? codexUtility : claudeUtility
    }
    private static let usageKey = "usageSnapshotsV1"
    private static let shortcutsKey = "shortcutsV1"
    private let ears: any Ears
    private let neuralVoice = NeuralVoice()
    private lazy var previewNeuralMouth = NeuralVoiceMouth(voice: neuralVoice)
    private let previewAppleMouth = AppleVoiceMouth()
    private lazy var neuralMouth = NeuralVoiceMouth(voice: neuralVoice)
    private let appleMouth: any Mouth = AppleVoiceMouth()
    private let screen: any Screen
    private let suppliedBrain: (any Brain)?
    private let overlay = OverlayWindowManager()
    private let notch: any NotchDisplay
    private let inserter: any Inserter = PasteInserter()
    private let takeover = ScreenTakeover()
    private let store: any Store
    private let profileStore: ProfileStore
    private let agents: any AgentHost = AgentRunHost()
    private lazy var dock = DockPanel { [weak self] in self?.send($0) }
    private let runCues = RunCues()
    private let penSounds = PenSounds()
    private let preferences: UserDefaults
    private var engine: BuddyEngine
    private let permissions = PermissionAdapter()
    private let shortcutMonitor = GlobalPushToTalkShortcutMonitor()
    private var shortcutSubscription: AnyCancellable?
    private var permissionTimer: Timer?
    private var noticeTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var turnGeneration = 0
    private var runTimers: [RunID: Task<Void, Never>] = [:]
    private var speechGeneration = 0
    private var readingGeneration = 0
    private var readingTask: Task<Void, Never>?

    init(
        historyURL: URL = HistoryStore.defaultURL,
        profileURL: URL = ProfileStore.defaultURL,
        preferences: UserDefaults = .standard,
        codexScreenshotRoot: URL = FileManager.default.temporaryDirectory.appending(path: "Buddy Codex screenshots", directoryHint: .isDirectory),
        ears: (any Ears)? = nil,
        screen: any Screen = DisplayCapture(),
        notch: (any NotchDisplay)? = nil,
        brain: (any Brain)? = nil,
        connections: TalkConnections? = nil
    ) {
        self.preferences = preferences
        self.screen = screen
        suppliedBrain = brain
        let connections = connections ?? TalkConnections()
        self.connections = connections
        let codexScreenshots = CodexScreenshotDirectory(root: codexScreenshotRoot)
        self.codexScreenshots = codexScreenshots
        codexBrain = CodexBrain(imageFolder: codexScreenshots.url.path, launch: Self.codexTalkLaunch)
        codexUtility = UtilityModel(CodexBrain(
            imageFolder: codexScreenshots.url.path,
            thread: CodexThread(instructions: UtilityInstructions.system, preferredModels: Provider.codex.utilityModels),
            launch: Self.codexUtilityLaunch
        ))
        let spokenReplies = preferences.object(forKey: "spokenReplies") as? Bool ?? true
        let microphone = MicrophoneLevel()
        self.ears = ears ?? OnDeviceEars(level: microphone)
        self.notch = notch ?? NotchPanel(microphone: microphone)
        let store = HistoryStore(url: historyURL)
        self.store = store
        let profileStore = ProfileStore(url: profileURL)
        self.profileStore = profileStore
        var loadFailures: [BuddyEngine.Event] = []
        let history: ConversationHistory
        do {
            history = try store.load()
        } catch {
            history = ConversationHistory()
            loadFailures.append(.historyFailed("History couldn't be loaded. \(error.localizedDescription)"))
        }
        let profile: Profile
        do {
            profile = try profileStore.load()
        } catch {
            profile = Profile()
            loadFailures.append(.profileFailed("Profile couldn't be loaded. \(error.localizedDescription)"))
        }
        engine = BuddyEngine(
            providerConnected: true,
            history: history,
            profile: profile,
            spokenReplies: spokenReplies,
            speechSettingsData: preferences.data(forKey: "speechSettingsV1"),
            shortcutData: preferences.data(forKey: Self.shortcutsKey),
            penSounds: preferences.object(forKey: "penSounds") as? Bool ?? true,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            talkSetup: connections.setup,
            usage: preferences.data(forKey: Self.usageKey).flatMap { try? JSONDecoder().decode(UsageSnapshots.self, from: $0) } ?? .init(),
            runProviderChoice: preferences.string(forKey: "runProvider").flatMap(ProviderChoice.init) ?? .auto,
            approvalMode: preferences.string(forKey: "runApprovalMode").flatMap(ApprovalMode.init) ?? .auto,
            timeZone: .autoupdatingCurrent,
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        _ = engine.handle(.voicesObserved(NeuralVoice.installedVoices()))
        for failure in loadFailures { _ = engine.handle(failure) }
        state = engine.state
        overlay.onPaperEvent = { [weak self] in self?.send($0) }
        codexBrain.onUsage = { [weak self] in self?.send(.usageReported(.codex, $0)) }
        claudeBrain.onUsage = { [weak self] in self?.send(.usageReported(.claude, $0)) }
        connections.onChange = { [weak self] in
            guard let self else { return }
            send(.interrupted)
            claudeBrain.stop()
            codexBrain.stop()
            send(.talkSetupChosen(connections.setup))
            useChosenUtility()
            Task { [weak self] in
                guard let self else { return }
                for brain in talkBrains { brain.start() }
                utility.refresh()
                send(.providerChanged)
            }
        }
    }

    private func brain(for provider: Provider) -> any Brain {
        suppliedBrain ?? (engine.state.talkSetup.cli(for: provider) == .codex ? codexBrain : claudeBrain)
    }

    /// The owner's Claude Code for talk or the utility model, started in an empty folder of Buddy's own.
    private func claudeLaunch(forUtility: Bool) -> ProcessLaunch? {
        guard connections.unavailableReason == nil else { return nil }
        let proxy = forUtility ? connections.utilityProxy : connections.proxy
        // Without its proxy, proxy mode would quietly fall back to the CLI's own login.
        if connections.selection.useProxy && proxy == nil { return nil }
        let environment = ProcessInfo.processInfo.environment
        let folder = Self.workingFolder("Claude").path
        let isExecutable = FileManager.default.isExecutableFile
        return forUtility
            ? ClaudeLaunch.utility(environment: environment, workingDirectory: folder, proxy: proxy, isExecutable: isExecutable)
            : ClaudeLaunch.talk(environment: environment, workingDirectory: folder, proxy: proxy, isExecutable: isExecutable)
    }

    /// The owner's Codex app server for talk, started in an empty folder of Buddy's own. It never goes through CLIProxy.
    private static func codexTalkLaunch() -> ProcessLaunch? {
        CodexLaunch.talk(
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: workingFolder("Codex").path,
            isExecutable: FileManager.default.isExecutableFile
        )
    }

    /// The owner's Codex app server for the utility model, in the same folder as talk but with no web search.
    private static func codexUtilityLaunch() -> ProcessLaunch? {
        CodexLaunch.utility(
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: workingFolder("Codex").path,
            isExecutable: FileManager.default.isExecutableFile
        )
    }

    private static func workingFolder(_ name: String) -> URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Buddy/\(name)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Swaps in the utility model of the provider answering talk, stopping the one it replaces.
    private func useChosenUtility() {
        guard utility !== chosenUtility else { return }
        utility.stop()
        utility = chosenUtility
    }

    func start() {
        shortcutSubscription = shortcutMonitor.eventPublisher.sink { [weak self] in self?.send($0) }
        refreshSystemState()
        notch.start { [weak self] in self?.send($0) }
        notch.update(state.notchConversation)
        for brain in talkBrains { brain.start() }
        utility.start()
        if connections.selection.useProxy { Task { [weak self] in await self?.connections.refresh() } }
        ears.prepare { [weak self] in self?.speechModel = $0 }
        neuralMouth.prepare { [weak self] in self?.send(.neuralVoiceObserved($0)) }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSystemState() }
        }
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        shortcutSubscription = nil
        shortcutMonitor.stop()
        send(.interrupted)
        for run in state.runs where run.isActive { send(.runStopRequested(run.id)) }
        takeover.end()
        captureTask?.cancel()
        noticeTask?.cancel()
        notch.stop()
        dock.show([])
        claudeBrain.stop()
        codexBrain.stop()
        claudeUtility.stop()
        codexUtility.stop()
        for timer in runTimers.values { timer.cancel() }
        runTimers = [:]
        agents.stopAll()
        penSounds.stop()
        penSounds.audio.stop()
    }

    func refreshSystemState() {
        send(.reduceMotionChanged(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        send(.clockTick)
        send(.permissionsObserved(permissions.snapshot()))
        send(.loginItemObserved(loginItemStatus))
        if state.permissions.inputMonitoring == .granted {
            shortcutMonitor.start()
        } else {
            shortcutMonitor.stop()
        }
    }

    func send(_ event: BuddyEngine.Event) {
        switch event {
        case .interrupted, .pushToTalkPressed, .textBoxSubmitted:
            previewNeuralMouth.stopSpeaking()
            previewAppleMouth.stopSpeaking()
        default: break
        }
        switch event {
        case .spokenRepliesChanged(let enabled):
            preferences.set(enabled, forKey: "spokenReplies")
        case .penSoundsChanged(let enabled):
            preferences.set(enabled, forKey: "penSounds")
        case .runCLIChosen(let cli):
            preferences.set(cli == .codex ? "codex" : "claude", forKey: "runProvider")
        case .runProviderChosen(let choice):
            preferences.set(choice.rawValue, forKey: "runProvider")
        case .approvalModeChosen(let mode):
            preferences.set(mode.rawValue, forKey: "runApprovalMode")
        case .interrupted, .clearHistoryRequested, .newConversationRequested:
            turnGeneration += 1
            captureTask?.cancel()
            inserter.cancelPending()
        default:
            break
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let motionEffects = engine.state.reduceMotion == reduced ? [] : engine.handle(.reduceMotionChanged(reduced))
        let effects = motionEffects + engine.handle(event)
        if !effects.isEmpty || !event.isGlobalInput {
            Logger.turnTiming.debug("\(event.logName, privacy: .public) -> \(effects.map(\.logName).joined(separator: ", "), privacy: .public)")
        }
        if state != engine.state { state = engine.state }
        notch.update(state.notchConversation)
        dock.show(state.runs, questionTakingNextTurn: state.questionTakingNextTurn, shortcuts: state.shortcuts)
        let cues = effects.compactMap { effect -> [PenSoundCue]? in
            if case .playPenSounds(let cues) = effect { return cues }
            return nil
        }.first
        let penBuffer = cues.flatMap { penSounds.prepare($0) }
        let drawingStart = CACurrentMediaTime() + 0.05
        for effect in effects {
            switch effect {
            case .showBuddy:
                overlay.showBuddy()
            case .hideBuddy:
                overlay.hideBuddy()
            case .showNotch(let shown):
                noticeTask?.cancel()
                notch.show(shown)
                guard case .notice = shown else { continue }
                noticeTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    self?.send(.noticeExpired)
                }
            case .showTextBox:
                if state.turn == .typing {
                    turnGeneration += 1
                    captureTask?.cancel()
                    inserter.cancelPending()
                }
                notch.focusTextBox()
            case .hideTextBox:
                notch.releaseTextBox()
            case .point(let point, let display, let label):
                overlay.point(at: point, on: display, label: label)
            case .annotate(let annotation, let display):
                overlay.annotate(annotation, on: display)
            case .draw(let marks, let display):
                overlay.draw(marks, on: display, startingAt: drawingStart)
            case .playPenSounds:
                if let penBuffer { penSounds.play(penBuffer, startingAt: drawingStart) }
            case .stopPenSounds:
                penSounds.stop()
            case .updatePaper(let paper):
                overlay.updatePaper(paper)
            case .removePaper(let id):
                overlay.removePaper(id)
            case .clearAnnotations:
                overlay.clearAnnotations()
            case .type(let text, let spot):
                let generation = turnGeneration
                inserter.type(text, at: spot) { [weak self] in
                    guard let self, turnGeneration == generation else { return }
                    send(.typingRefused)
                }
            case .startListening:
                turnGeneration += 1
                captureTask?.cancel()
                inserter.cancelPending()
                let generation = turnGeneration
                ears.startListening(
                    onHeard: { [weak self] text in
                        guard let self, turnGeneration == generation else { return }
                        send(.transcriptUpdated(text))
                    },
                    onTranscript: { [weak self] text in
                        guard let self, turnGeneration == generation else { return }
                        send(.transcriptFinished(text))
                    },
                    onFailure: { [weak self] error in
                        guard let self, turnGeneration == generation else { return }
                        send(.listeningFailed(error))
                    }
                )
            case .stopListening:
                ears.stopListening()
            case .captureScreens:
                turnGeneration += 1
                inserter.cancelPending()
                captureTask?.cancel()
                let generation = turnGeneration
                captureTask = Task { [weak self] in
                    guard let self else { return }
                    let result: BuddyEngine.Event
                    do {
                        result = .screensCaptured(try await screen.captureAll())
                    } catch {
                        result = .captureFailed(error.localizedDescription)
                    }
                    guard !Task.isCancelled, turnGeneration == generation else { return }
                    send(result)
                }
            case .sendTurn(let turn):
                let generation = turnGeneration
                if let reason = connections.unavailableReason {
                    Task { [weak self] in
                        guard let self, turnGeneration == generation else { return }
                        send(.provider(.failed(.error(reason))))
                    }
                    continue
                }
                let brain = brain(for: engine.state.provider)
                answering = brain
                brain.send(turn) { [weak self] event in
                    guard let self, turnGeneration == generation else { return }
                    send(.provider(event))
                }
            case .cancelReply:
                turnGeneration += 1
                answering?.cancelReply()
            case .leaveProvider(let provider):
                // The brain left behind may still report on its last turn, which must not reach the next one.
                turnGeneration += 1
                let left = brain(for: provider)
                left.endConversation()
                left.start()
            case .saveUsage(let usage):
                preferences.set(try? JSONEncoder().encode(usage), forKey: Self.usageKey)
            case .saveShortcuts(let data):
                preferences.set(data, forKey: Self.shortcutsKey)
            case .saveSpeechSettings(let data):
                preferences.set(data, forKey: "speechSettingsV1")
            case .previewVoice(let line, let voice, let speed):
                voicePreviewError = nil
                previewNeuralMouth.stopSpeaking()
                previewAppleMouth.stopSpeaking()
                let mouth: any Mouth = voice == .apple ? previewAppleMouth : previewNeuralMouth
                mouth.speak(line, voice: voice, speed: speed, onStarted: {}, onFinished: {}, onFailed: { [weak self] in
                    self?.voicePreviewError = "That voice could not play a preview. Try the Apple voice."
                })
            case .speak(let line, let voice, let speed):
                let generation = turnGeneration
                speechGeneration += 1
                let speech = speechGeneration
                let mouth: any Mouth = voice == .apple ? appleMouth : neuralMouth
                mouth.speak(
                    line, voice: voice, speed: speed,
                    onStarted: { [weak self] in
                        guard let self, turnGeneration == generation, speechGeneration == speech else { return }
                        send(.lineStarted)
                    },
                    onFinished: { [weak self] in
                        guard let self, turnGeneration == generation, speechGeneration == speech else { return }
                        send(.lineFinished)
                    },
                    onFailed: { [weak self] in
                        guard let self, turnGeneration == generation, speechGeneration == speech else { return }
                        send(.lineFailed)
                    }
                )
            case .stopSpeaking:
                speechGeneration += 1
                previewNeuralMouth.stopSpeaking()
                previewAppleMouth.stopSpeaking()
                neuralMouth.stopSpeaking()
                appleMouth.stopSpeaking()
            case .waitForReading(let duration):
                readingTask?.cancel()
                readingGeneration += 1
                let reading = readingGeneration
                let generation = turnGeneration
                readingTask = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    guard let self, !Task.isCancelled, turnGeneration == generation,
                          readingGeneration == reading else { return }
                    readingTask = nil
                    send(.replyLineRead)
                }
            case .cancelReading:
                readingGeneration += 1
                readingTask?.cancel()
                readingTask = nil
            case .saveHistory(let history):
                do {
                    try store.save(history)
                    send(.historySaved)
                } catch {
                    send(.historyFailed("History couldn't be saved. \(error.localizedDescription)"))
                }
            case .clearHistory:
                do {
                    try store.clear()
                    send(.historyCleared(error: nil))
                } catch {
                    send(.historyCleared(error: "History couldn't be cleared. \(error.localizedDescription)"))
                }
            case .saveProfile(let profile):
                do {
                    try profileStore.save(profile)
                    send(.profileSaved)
                } catch {
                    send(.profileFailed("Profile couldn't be saved. \(error.localizedDescription)"))
                }
            case .clearProfile:
                do {
                    try profileStore.clear()
                    send(.profileCleared(error: nil))
                } catch {
                    send(.profileCleared(error: "Profile couldn't be cleared. \(error.localizedDescription)"))
                }
            case .resetProvider:
                turnGeneration += 1
                inserter.cancelPending()
                for brain in talkBrains { brain.endConversation() }
            case .writeSummary(let request):
                // The engine asks for one summary at a time, so the utility being replaced has nothing in flight.
                useChosenUtility()
                utility.ask(request.prompt) { [weak self] result in
                    switch result {
                    case .success(let summary): self?.send(.summaryWritten(id: request.id, summary))
                    case .failure: self?.send(.summaryFailed(id: request.id))
                    }
                }
            case .cancelSummary:
                utility.cancel()
            case .cancelCapture:
                captureTask?.cancel()
                captureTask = nil
            case .requestPermission(let permission):
                permissionInFlight = permission
                Task { [weak self] in
                    guard let self else { return }
                    await permissions.request(permission)
                    permissionInFlight = nil
                    refreshSystemState()
                }
            case .openPermissionSettings(let permission):
                permissions.openSettings(for: permission)
            case .setLaunchAtLogin(let enabled):
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try await SMAppService.mainApp.unregister()
                        }
                        send(.loginItemChangeFinished(loginItemStatus, error: nil))
                    } catch {
                        send(.loginItemChangeFinished(loginItemStatus, error: "Launch at login: \(error.localizedDescription)"))
                    }
                }
            case .openLoginItemSettings:
                SMAppService.openSystemSettingsLoginItems()
            case .startRun(let id, let brief, let cli, let mode):
                agents.start(id, brief, on: cli, approving: mode) { [weak self] in self?.send(.run(id, $0)) }
            case .pauseRun(let id):
                agents.stop(id)
            case .resumeRun(let id, let brief, let cli, let mode):
                agents.resume(id, brief, on: cli, approving: mode) { [weak self] in self?.send(.run(id, $0)) }
            case .stopRun(let id):
                runTimers.removeValue(forKey: id)?.cancel()
                agents.stop(id)
            case .scheduleRunTimeUp(let id, let seconds):
                runTimers[id]?.cancel()
                runTimers[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                    self?.send(.runTimeUp(id))
                }
            case .answerApproval(let id, let requestID, let approval):
                agents.answerApproval(id, request: requestID, approval)
            case .captureScreensForTool(let id, let call):
                Task { [weak self] in
                    guard let self else { return }
                    let result: RunEvent
                    do {
                        result = .screensCaptured(call, try await screen.captureAll())
                    } catch {
                        result = .captureFailed(call, error.localizedDescription)
                    }
                    guard agents.isWaiting(call, for: id) else { return }
                    send(.run(id, result))
                }
            case .answerTool(let call, let answer):
                agents.answerTool(call, answer)
            case .saveRunNote(let id, let text):
                agents.saveNote(id, text)
            case .saveRunReport(let id, let text):
                agents.saveReport(id, text)
            case .playCue(let cue):
                runCues.play(cue)
            case .beginTakeover(let id):
                overlay.takeover(true)
                if !takeover.begin() {
                    Task { [weak self] in
                        self?.send(.run(id, .takeoverFailed("Buddy couldn't block your keyboard and mouse, so it gave the screen back.")))
                    }
                }
            case .act(let id, let call, let action):
                takeover.perform(action) { [weak self] failure in
                    guard let self, agents.isWaiting(call, for: id) else { return }
                    send(.run(id, .acted(call, failure: failure)))
                }
            case .endTakeover:
                takeover.end()
                overlay.takeover(false)
            }
        }
    }

    private var loginItemStatus: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .notRegistered: .off
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
}
