import Foundation
import Synchronization

@MainActor
final class ChildProcess {
    private let process = Process()
    private let input: FileHandle
    private let writer = DispatchQueue(label: "dev.steven.buddy.child-input")

    init(
        _ launch: ProcessLaunch,
        onOutput: @escaping @MainActor @Sendable (Data) -> Void,
        onEnd: @escaping @MainActor @Sendable (String) -> Void
    ) throws {
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = URL(fileURLWithPath: launch.workingDirectory, isDirectory: true)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        self.input = input.fileHandleForWriting
        Self.read(output.fileHandleForReading, errors.fileHandleForReading, onOutput: onOutput, onEnd: onEnd)
    }

    var isRunning: Bool { process.isRunning }

    func write(_ data: Data) {
        writer.async { [input] in try? input.write(contentsOf: data) }
    }

    func closeInput() {
        writer.async { [input] in try? input.close() }
    }

    func terminate() {
        closeInput()
        process.terminate()
        Task { [process] in
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Foundation gives the child its own process group. Kill that group so a stopped run cannot leave a shell
    /// command working after its CLI process exits.
    func killImmediately() {
        closeInput()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        Darwin.kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
    }

    private nonisolated static func read(
        _ output: FileHandle,
        _ errors: FileHandle,
        onOutput: @escaping @MainActor @Sendable (Data) -> Void,
        onEnd: @escaping @MainActor @Sendable (String) -> Void
    ) {
        let errorTail = ErrorTail()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            forEachChunk(of: output) { chunk in DispatchQueue.main.async { onOutput(chunk) } }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            forEachChunk(of: errors, errorTail.keep)
            group.leave()
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { onEnd(errorTail.text) } }
    }

    /// Hands over bytes as soon as the pipe has any, until it closes. `FileHandle.read(upToCount:)` would wait
    /// for the full count, which a live process never sends.
    private nonisolated static func forEachChunk(of pipe: FileHandle, _ body: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(pipe.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                body(Data(buffer[..<count]))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}

private final class ErrorTail: Sendable {
    private let bytes = Mutex(Data())

    func keep(_ chunk: Data) {
        bytes.withLock { $0 = ($0 + chunk).suffix(4_096) }
    }

    var text: String {
        String(decoding: bytes.withLock { $0 }, as: UTF8.self)
    }
}
