import Foundation

/// Buddy's brain on the owner's Codex: one long-lived `codex app-server` process with a thread per conversation,
/// started again for the next turn after it ends.
@MainActor
public final class CodexBrain {
    private struct Running {
        let id: Int
        let process: ChildProcess
    }

    private let imageFolder: String
    private let thread: CodexThread
    private let launch: () -> ProcessLaunch?
    private var running: Running?
    private var launches = 0
    private var stream: CodexStream
    private var onEvent: (ProviderEvent) -> Void = { _ in }
    /// Every usage report the server makes, including the one it answers at startup before any turn.
    public var onUsage: (ProviderUsage) -> Void = { _ in }

    /// Each turn's screenshots are saved in `imageFolder` and deleted when the turn ends. `launch` runs before each
    /// process starts, so a `codex` installed while Buddy runs is found.
    public init(imageFolder: String, thread: CodexThread = .talk, launch: @escaping () -> ProcessLaunch?) {
        self.imageFolder = imageFolder
        self.thread = thread
        self.launch = launch
        stream = CodexStream(imageFolder: imageFolder, thread: thread)
    }

    /// Starts the process ahead of the first turn, so that turn finds it warm.
    public func start() {
        _ = startProcess()
    }

    /// Events always arrive after `send` returns, so the caller never handles one in the middle of its own work.
    public func send(_ turn: TurnRequest, onEvent: @escaping (ProviderEvent) -> Void) {
        if let failure = startProcess() {
            Task { onEvent(.failed(failure)) }
            return
        }
        self.onEvent = onEvent
        perform(stream.send(turn))
    }

    public func cancelReply() {
        perform(stream.cancel())
    }

    /// Keeps the process and starts a fresh thread, whose first turn is primed with the recent turns again.
    public func endConversation() {
        perform(stream.endConversation(), deferringEvents: true)
    }

    /// Ends the process. A turn still waiting for its answer fails, and the files it was given are deleted.
    public func stop() {
        guard let running else { return }
        self.running = nil
        running.process.terminate()
        perform(stream.ended(stderr: "Buddy stopped it."), deferringEvents: true)
    }

    private func startProcess() -> ProviderFailure? {
        if let running, running.process.isRunning { return nil }
        // The process has exited, but its end callback may still be queued behind this call. Retire it here so the
        // old turn fails and its files go before the next process reuses their names.
        if let running {
            self.running = nil
            running.process.closeInput()
            perform(stream.ended(stderr: ""), deferringEvents: true)
        }
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
        stream = CodexStream(imageFolder: imageFolder, thread: thread)
        perform(stream.start())
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

    /// Screenshots are saved and deleted right here, before any later line reaches the process's input queue, so a
    /// file is on disk before the line naming it goes out.
    private func perform(_ outputs: [CodexStream.Output], deferringEvents: Bool = false) {
        let onEvent = onEvent, onUsage = onUsage
        let handler = { (event: ProviderEvent) in
            if case .usage(let usage) = event { onUsage(usage) }
            onEvent(event)
        }
        for output in outputs {
            switch output {
            case .write(let line):
                running?.process.write(line)
            case .event(let event):
                if deferringEvents {
                    Task { handler(event) }
                } else {
                    handler(event)
                }
            case .endProcess:
                stop()
            case .saveFile(let path, let contents):
                let url = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? contents.write(to: url)
            case .deleteFiles(let paths):
                for path in paths { try? FileManager.default.removeItem(atPath: path) }
            }
        }
    }
}
