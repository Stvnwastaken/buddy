import Foundation

/// An agent run, numbered in the order the owner started runs since Buddy launched.
public struct RunID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    public var description: String { "run \(number)" }
}

/// How far a run may go before Buddy stops it.
public struct RunLimits: Equatable, Sendable {
    /// Tool uses, counting Buddy's own tools.
    public let steps: Int
    public let seconds: Int

    public init(steps: Int, seconds: Int) {
        self.steps = steps
        self.seconds = seconds
    }

    public static let standard = RunLimits(steps: 100, seconds: 20 * 60)
}

/// What a run starts from: the owner's request and the screen captures of the turn that asked for it.
public struct RunBrief: Equatable, Sendable {
    public let request: String
    public let captures: [ScreenCapture]
    public let continuation: RunContinuation?

    public init(request: String, captures: [ScreenCapture], continuation: RunContinuation? = nil) {
        self.request = request
        self.captures = captures
        self.continuation = continuation
    }
}

public struct RunContinuation: Equatable, Sendable {
    public let note: String
    public let partialReport: String

    public init(note: String, partialReport: String) {
        self.note = note
        self.partialReport = partialReport
    }
}

public enum RunStatus: Equatable, Sendable {
    case running
    case paused
    /// Waiting for the owner to answer something on the run's card.
    case needsOwner
    /// Controls the mouse and keyboard, after the owner consented.
    case takingOver
    case done
    case failed(String)
    case stopped(RunStop)
}

public enum RunStop: Equatable, Sendable {
    case owner, stepCap, timeCap
}

/// Buddy's own sounds for a run's moments: it launched, it needs the owner, or it ended by itself.
public enum RunCue: Equatable, Sendable {
    case launch, needsOwner, done
}

/// Something a run waits for the owner to answer.
public enum OwnerAsk: Equatable, Sendable {
    /// A tool use the approval policy leaves to the owner, answered by approving or denying it. The id is the
    /// provider's permission prompt.
    case approval(id: String, action: String, reason: String)
    /// A question the run asked with `ask_owner`, answered by clicking a choice or by the owner's next turn.
    case question(ToolCallID, String, choices: [String])
    /// The run's `begin_takeover` call, answered by allowing or refusing it.
    case takeover(ToolCallID, reason: String)
}

/// A tool use Buddy refused, as the run note records it.
public struct Denial: Equatable, Sendable {
    /// The command, or the tool and the path it named.
    public let action: String
    public let reason: String

    public init(action: String, reason: String) {
        self.action = action
        self.reason = reason
    }
}

public struct AgentRun: Equatable, Sendable {
    public let id: RunID
    public let brief: RunBrief
    /// The CLI the run works on.
    public internal(set) var cli: ProviderCLI
    /// How the run's requests are approved.
    public let approvalMode: ApprovalMode
    public private(set) var status = RunStatus.running
    /// What the run waits for the owner to answer, oldest first. Not empty exactly while the status is `needsOwner`.
    public private(set) var asks: [OwnerAsk] = []
    /// The folder the run's process works in, known once it has started.
    public internal(set) var folder: String?
    /// The run note as the run last wrote it.
    public internal(set) var note = ""
    public internal(set) var denials: [Denial] = []
    /// The run's final message, once it is done.
    public internal(set) var report: String?
    public internal(set) var switchNotes: [String] = []
    let allowsFallback: Bool
    var attemptedProviders: Set<Provider>
    var continuation: RunContinuation?
    var resuming = false
    let limits: RunLimits
    var steps = 0
    var captures: [ScreenCapture]
    /// What the run's next takeover tool call is told while it doesn't hold the screen, after it lost the screen.
    var screenReturn: String?

    init(id: RunID, brief: RunBrief, cli: ProviderCLI, approvalMode: ApprovalMode = .auto, limits: RunLimits, allowsFallback: Bool = false) {
        self.id = id
        self.brief = brief
        self.cli = cli
        self.approvalMode = approvalMode
        self.limits = limits
        self.allowsFallback = allowsFallback
        attemptedProviders = [cli.provider]
        captures = brief.captures
    }
}

/// Buddy's own tools, which a run calls through the app's MCP server.
public enum BuddyTool: Equatable, Sendable {
    case captureScreen
    case updateRunNote(String)
    /// Reply-style lines, each with optional leading tags, for the buddy to speak and point with.
    case showBeats(String)
    /// A question for the owner, with the answers they can click. With no choices the owner answers in their words.
    case askOwner(String, choices: [String])
    /// Asks the owner for the mouse and keyboard, saying why.
    case beginTakeover(reason: String)
    /// Only works while the run holds the screen.
    case screen(ScreenAction<ScreenSpot>)
    case endTakeover
}

/// One call to a Buddy tool, numbered by the MCP server that received it.
public struct ToolCallID: Hashable, Sendable {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }
}

public struct ToolAnswer: Equatable, Sendable {
    public let content: [TurnContent]
    public let isError: Bool

    public init(content: [TurnContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

/// What a run's provider process and Buddy's MCP server report about the run.
public enum RunEvent: Equatable, Sendable {
    /// The run's process is working in this folder.
    case started(folder: String)
    /// The run used a tool, which is one step.
    case toolUsed
    /// The provider asks whether the run may use a tool. Buddy answers with `answerApproval` and this id.
    case approvalRequested(id: String, ApprovalRequest)
    case toolCalled(ToolCallID, BuddyTool)
    case screensCaptured(ToolCallID, [ScreenCapture])
    case captureFailed(ToolCallID, String)
    /// The app performed the call's screen action, or couldn't, saying why.
    case acted(ToolCallID, failure: String?)
    /// The app couldn't block the owner's input, so the takeover ended.
    case takeoverFailed(String)
    /// The run ended its work, and this is its final message.
    case finished(report: String)
    case limitReached(partialReport: String)
    case failed(ProviderFailure)
}

extension AgentRun {
    /// The run note as `note.md` holds it: the note the run wrote, then each tool use Buddy denied.
    public var noteDocument: String {
        guard !denials.isEmpty else { return progressNote }
        let written = progressNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let denied = denials.map { "- `\($0.action)`: \($0.reason)\n" }.joined()
        return (written.isEmpty ? "" : written + "\n\n") + "## Denied\n" + denied
    }

    /// The report as `report.md` holds it: the owner's request, then the final message or how else the run ended.
    /// Nil while the run is running.
    public var reportDocument: String? {
        let ending: String
        switch status {
        case .running, .paused, .needsOwner, .takingOver: return nil
        case .done: ending = report ?? ""
        case .failed(let message): ending = message
        case .stopped(.owner): ending = "Stopped by the owner."
        case .stopped(.stepCap): ending = "Stopped at its step cap of \(Self.count(limits.steps, "step"))."
        case .stopped(.timeCap): ending = "Stopped at its time cap of \(Self.duration(limits.seconds))."
        }
        return "Asked: \(brief.request)\n\n\(ending.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// The run's name on its card: the heading its run note starts with, or its request until it writes one.
    public var name: String {
        Self.heading(of: note) ?? request
    }

    /// The owner's request with its first letter capitalized, as the card shows it.
    public var request: String {
        brief.request.prefix(1).uppercased() + brief.request.dropFirst()
    }

    /// Whether the run has named itself with a heading at the top of its run note.
    public var namesItself: Bool {
        Self.heading(of: note) != nil
    }

    /// The run note without the heading that names the run.
    public var noteBody: String {
        let note = progressNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.heading(of: note) != nil else { return note }
        return note.drop { !$0.isNewline }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The question the run has waited on longest, if it waits on one.
    var waitingQuestion: ToolCallID? {
        asks.lazy.compactMap { if case .question(let call, _, _) = $0 { call } else { nil } }.first
    }

    /// Whether the run is still going: working, waiting for the owner or holding the screen.
    public var isActive: Bool {
        status == .running || status == .paused || status == .needsOwner || status == .takingOver
    }

    private var progressNote: String {
        guard !switchNotes.isEmpty else { return note }
        let written = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return (written.isEmpty ? "" : written + "\n\n") + "## Provider switch\n" + switchNotes.joined(separator: "\n")
    }

    mutating func countStep() {
        steps += 1
        if steps > limits.steps { end(.stopped(.stepCap)) }
    }

    mutating func statusForHandoff() {
        status = asks.isEmpty ? .paused : .needsOwner
        screenReturn = nil
    }

    /// Ends the run with a status that isn't active. Nothing is left waiting for the owner.
    mutating func end(_ ending: RunStatus) {
        asks = []
        continuation = nil
        resuming = false
        status = ending
    }

    mutating func wait(for ask: OwnerAsk) {
        asks.append(ask)
        status = .needsOwner
    }

    /// Takes the waiting approval for this permission prompt, giving the action it asked about.
    mutating func takeApproval(_ id: String) -> String? {
        guard let index = asks.firstIndex(where: { if case .approval(id, _, _) = $0 { true } else { false } }),
              case .approval(_, let action, _) = remove(at: index)
        else { return nil }
        return action
    }

    /// Takes the waiting takeover request for this call, giving its reason.
    mutating func takeTakeover(_ call: ToolCallID) -> String? {
        guard let index = asks.firstIndex(where: { if case .takeover(call, _) = $0 { true } else { false } }),
              case .takeover(_, let reason) = remove(at: index)
        else { return nil }
        return reason
    }

    var awaitsTakeover: Bool {
        asks.contains { if case .takeover = $0 { true } else { false } }
    }

    /// The run holds the screen. Only a run with nothing waiting for the owner can.
    mutating func takeOver() {
        status = .takingOver
        screenReturn = nil
    }

    /// The run no longer holds the screen, and its next takeover tool call is told `explanation`.
    mutating func giveBackScreen(_ explanation: String?) {
        status = .running
        screenReturn = explanation
    }

    /// Takes the waiting question for this call, or the oldest waiting question.
    mutating func takeQuestion(_ call: ToolCallID? = nil) -> ToolCallID? {
        guard let index = asks.firstIndex(where: { if case .question(let asked, _, _) = $0 { (call ?? asked) == asked } else { false } }),
              case .question(let asked, _, _) = remove(at: index)
        else { return nil }
        return asked
    }

    private mutating func remove(at index: Int) -> OwnerAsk {
        defer { if asks.isEmpty { status = .running } }
        return asks.remove(at: index)
    }

    private static func heading(of note: String) -> String? {
        let first = note.trimmingCharacters(in: .whitespacesAndNewlines).prefix { !$0.isNewline }
        guard let match = first.wholeMatch(of: /#{1,6}\s+(.*\S)\s*/) else { return nil }
        return String(match.1)
    }

    private static func count(_ number: Int, _ unit: String) -> String {
        number == 1 ? "1 \(unit)" : "\(number) \(unit)s"
    }

    private static func duration(_ seconds: Int) -> String {
        seconds.isMultiple(of: 60) ? count(seconds / 60, "minute") : count(seconds, "second")
    }
}

extension RunEvent {
    /// The call to a Buddy tool this event belongs to. Every call is answered, even after its run ends, so no MCP
    /// request is left waiting.
    var toolCall: ToolCallID? {
        switch self {
        case .toolCalled(let call, _), .screensCaptured(let call, _), .captureFailed(let call, _), .acted(let call, _): call
        case .started, .toolUsed, .approvalRequested, .takeoverFailed, .finished, .limitReached, .failed: nil
        }
    }
}

extension ToolAnswer {
    static func text(_ text: String) -> ToolAnswer {
        ToolAnswer(content: [.text(text)])
    }

    static func error(_ message: String) -> ToolAnswer {
        ToolAnswer(content: [.text(message)], isError: true)
    }
}
