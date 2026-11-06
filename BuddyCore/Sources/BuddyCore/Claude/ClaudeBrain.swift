import Foundation

/// Buddy's brain on the owner's Claude Code: one long-lived `claude -p` stream-json process, started again
/// for the next turn after it ends.
@MainActor
public final class ClaudeBrain {
    private struct Running {
        let id: Int
        let process: ChildProcess
        var hasSentTurn = false
    }

    private let launch: () -> ProcessLaunch?
    private var running: Running?
    private var launches = 0
    private var stream = ClaudeStream()
    private var onEvent: (ProviderEvent) -> Void = { _ in }
    /// Every usage report the process makes, whichever turn it arrives in.
    public var onUsage: (ProviderUsage) -> Void = { _ in }

    /// `launch` runs before each process starts, so a `claude` installed while Buddy runs is found.
    public init(launch: @escaping () -> ProcessLaunch?) {
        self.launch = launch
    }

    /// Starts the process ahead of the first turn, so that turn finds it warm.
    public func start() {
        _ = startProcess()
    }

    /// Events always arrive after `send` returns, so the caller never handles one in the middle of its own work.
    public func send(_ turn: TurnRequest, onEvent: @escaping (ProviderEvent) -> Void) {
        self.onEvent = onEvent
        if let failure = startProcess() {
            Task { onEvent(.failed(failure)) }
            return
        }
        let request = running?.hasSentTurn == true ? turn.withoutPriming : turn
        running?.hasSentTurn = true
        perform(stream.send(request))
    }

    public func cancelReply() {
        perform(stream.cancel())
    }

    /// The next turn starts a fresh process, which the conversation's recent turns prime.
    public func endConversation() {
        stop()
    }

    public func stop() {
        guard let running else { return }
        self.running = nil
        running.process.terminate()
    }

    private func startProcess() -> ProviderFailure? {
        if let running, running.process.isRunning { return nil }
        guard let launch = launch() else { return .notInstalled }
        let id = launches + 1
        let process: ChildProcess
        do {
            process = try ChildProcess(
                launch,
                onOutput: { [weak self] chunk in self?.received(chunk, from: id) },
                onEnd: { [weak self] stderr in self?.ended(id, stderr: stderr) }
            )
        } catch {
            return .error("it couldn't start. \(error.localizedDescription)")
        }
        launches = id
        running = Running(id: id, process: process)
        stream = ClaudeStream()
        return nil
    }

    private func received(_ chunk: Data, from id: Int) {
        guard running?.id == id else { return }
        perform(stream.received(chunk))
    }

    private func ended(_ id: Int, stderr: String) {
        guard running?.id == id else { return }
        running = nil
        perform(stream.ended(stderr: stderr))
    }

    private func perform(_ outputs: [ClaudeStream.Output]) {
        for output in outputs {
            switch output {
            case .write(let line):
                running?.process.write(line)
            case .event(let event):
                if case .usage(let usage) = event { onUsage(usage) }
                onEvent(event)
            case .endProcess:
                stop()
            }
        }
    }
}
