import Foundation

/// What a run's stream asks of the process running it.
public enum RunStreamOutput: Equatable, Sendable {
    case write(Data)
    case event(RunEvent)
    /// The run is over, so the process may exit.
    case closeInput
}

/// One provider's exchange with the process of one agent run, without I/O: what to write to the process, and the
/// run events in what it prints back.
public protocol RunStream: Sendable {
    /// The run's first message. The brief's screens are already saved in the folder as `screen-1.jpg` and so on.
    mutating func start(_ brief: RunBrief, folder: String) -> [RunStreamOutput]
    /// Takes whatever the process printed, in chunks split anywhere.
    mutating func received(_ chunk: Data) -> [RunStreamOutput]
    /// Answers the request the run sent as `approvalRequested` with this id. An unknown or already answered id
    /// writes nothing.
    mutating func answer(_ requestID: String, _ approval: Approval) -> [RunStreamOutput]
    /// The process exited. A run that never finished fails with the last line the process wrote to stderr.
    mutating func ended(stderr: String) -> [RunStreamOutput]
}

/// One agent run's provider process, which works in the run folder until it reports.
@MainActor
public final class RunProcess {
    private enum Phase {
        case ready
        case running(ChildProcess)
        case exited
        case stopped
    }

    private let launch: ProcessLaunch
    private let brief: RunBrief
    private let folder: String
    private let onEvent: (RunEvent) -> Void
    private var phase = Phase.ready
    private var stream: any RunStream

    public init(
        launch: ProcessLaunch,
        stream: any RunStream,
        brief: RunBrief,
        folder: String,
        onEvent: @escaping (RunEvent) -> Void
    ) {
        self.launch = launch
        self.stream = stream
        self.brief = brief
        self.folder = folder
        self.onEvent = onEvent
    }

    /// Starts the process and sends it the brief, or says why it couldn't. Events arrive only after this returns.
    public func start() -> ProviderFailure? {
        guard case .ready = phase else { return nil }
        do {
            phase = .running(try ChildProcess(
                launch,
                onOutput: { [weak self] chunk in self?.received(chunk) },
                onEnd: { [weak self] stderr in self?.ended(stderr: stderr) }
            ))
        } catch {
            phase = .exited
            return .error("it couldn't start. \(error.localizedDescription)")
        }
        perform(stream.start(brief, folder: folder))
        return nil
    }

    /// Answers the permission prompt the run sent as `approvalRequested` with this id.
    public func answer(_ requestID: String, _ approval: Approval) {
        perform(stream.answer(requestID, approval))
    }

    /// Ends the process at once. No events arrive after this.
    public func stop() {
        if case .running(let process) = phase { process.killImmediately() }
        phase = .stopped
    }

    private func received(_ chunk: Data) {
        guard case .running = phase else { return }
        perform(stream.received(chunk))
    }

    private func ended(stderr: String) {
        guard case .running = phase else { return }
        phase = .exited
        perform(stream.ended(stderr: stderr))
    }

    private func perform(_ outputs: [RunStreamOutput]) {
        for output in outputs {
            switch (output, phase) {
            case (_, .stopped):
                return
            case (.write(let line), .running(let process)):
                process.write(line)
            case (.closeInput, .running(let process)):
                process.closeInput()
            case (.event(let event), _):
                onEvent(event)
            case (.write, _), (.closeInput, _):
                break
            }
        }
    }
}
