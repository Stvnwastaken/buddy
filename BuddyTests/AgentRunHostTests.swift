import BuddyCore
import Foundation
import Testing
@testable import Buddy

@MainActor
struct AgentRunHostTests {
    @Test func runFolderKeepsItsBriefCapturesNoteAndReportAfterStop() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buddy-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AgentRunHost(runsFolder: root) { _, _, folder, _, _ in
            ProcessLaunch(executable: "/bin/cat", arguments: [], environment: [:], workingDirectory: folder.path)
        }
        defer { host.stopAll() }
        let capture = ScreenCapture(
            jpeg: Data([1, 2, 3]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
            pixelWidth: 2880, pixelHeight: 1800, containsCursor: true
        )
        let brief = RunBrief(request: "list open apps", captures: [capture])
        let first = try await startedFolder(host, run: RunID(1), brief)
        host.saveNote(RunID(1), "- [x] List the apps\n")
        host.stop(RunID(1))
        host.saveReport(RunID(1), "Saved the app list.\n")
        #expect(try String(contentsOf: first.appending(path: "brief.md"), encoding: .utf8) == "# Brief\n\nThe owner asked: list open apps\n\nScreens when they asked: screen-1.jpg (with the cursor).\n")
        #expect(try Data(contentsOf: first.appending(path: "screen-1.jpg")) == Data([1, 2, 3]))
        #expect(try String(contentsOf: first.appending(path: "note.md"), encoding: .utf8) == "- [x] List the apps\n")
        #expect(try String(contentsOf: first.appending(path: "report.md"), encoding: .utf8) == "Saved the app list.\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.path).sorted() == ["brief.md", "note.md", "output", "report.md", "scratch", "screen-1.jpg"])

        let secondHost = AgentRunHost(runsFolder: root) { _, _, folder, _, _ in
            ProcessLaunch(executable: "/bin/cat", arguments: [], environment: [:], workingDirectory: folder.path)
        }
        defer { secondHost.stopAll() }
        let second = try await startedFolder(secondHost, run: RunID(1), brief)
        #expect(second != first)
        #expect(try String(contentsOf: first.appending(path: "report.md"), encoding: .utf8) == "Saved the app list.\n")
    }

    @Test func codexRunTalksToCodexsAppServerInItsFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buddy-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeCodex = #"""
        read -r initialize; echo '{"id":1,"result":{}}'
        read -r initialized; read -r account; echo '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
        read -r thread; echo '{"id":3,"result":{"thread":{"id":"t"},"cwd":"'"$PWD"'","approvalPolicy":"untrusted","approvalsReviewer":"user"}}'
        cat > /dev/null
        """#
        var launched: [ProviderCLI] = []
        let host = AgentRunHost(runsFolder: root) { cli, _, folder, _, _ in
            launched.append(cli)
            return ProcessLaunch(executable: "/bin/sh", arguments: ["-c", fakeCodex], environment: [:], workingDirectory: folder.path)
        }
        defer { host.stopAll() }
        let folder = try await startedFolder(host, run: RunID(1), RunBrief(request: "list open apps", captures: []), on: .codex)
        #expect(launched == [.codex])
        #expect(folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    }

    @Test func codexRunLaunchesTheOwnersCodexFromBuddysOwnHomeLinkedToTheirSignIn() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buddy-host-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/bin", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(root)/bin/codex", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let folder = URL(fileURLWithPath: "\(root)/Runs/run")

        let launch = try #require(try AgentRunHost.makeLaunch(
            cli: .codex, approvalMode: .auto, folder: folder, port: 49152, token: "run-token",
            environment: ["HOME": "\(root)/home", "CODEX_HOME": "\(root)/owner", "PATH": "\(root)/bin"],
            codexHome: "\(root)/run home"
        ))

        #expect(launch.executable == "\(root)/bin/codex")
        #expect(launch.workingDirectory == folder.path)
        #expect(launch.environment["CODEX_HOME"] == "\(root)/run home")
        #expect(launch.arguments.contains(#"mcp_servers.buddy.url="http://127.0.0.1:49152/mcp""#))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(root)/run home/auth.json") == "\(root)/owner/auth.json")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(root)/run home/auth.lock") == "\(root)/owner/auth.lock")
    }

    private func startedFolder(_ host: AgentRunHost, run: RunID, _ brief: RunBrief, on cli: ProviderCLI = .claudeCode) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            host.start(run, brief, on: cli, approving: .auto) { event in
                switch event {
                case .started(let folder): continuation.resume(returning: URL(fileURLWithPath: folder))
                case .failed(let failure): continuation.resume(throwing: HostFailure(message: String(describing: failure)))
                default: break
                }
            }
        }
    }

    private struct HostFailure: Error {
        let message: String
    }
}
