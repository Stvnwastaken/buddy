/// How to start one child process.
public struct ProcessLaunch: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// The environment for a run's commands: a plain zsh that skips the owner's startup files and finds system
    /// programs before the CLI's own `path`, so no alias or look-alike stands in for the program the policy judged.
    static func runShell(_ environment: [String: String], path: String) -> [String: String] {
        environment
            .filter { name, _ in name != "BASH_ENV" && name != "ENV" }
            .merging(["SHELL": "/bin/zsh", "ZDOTDIR": "/var/empty", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:" + path]) { _, run in run }
    }

    /// Finds the owner's CLI on their `PATH`, then in its usual install folders, then in Homebrew's. It returns the
    /// child's `PATH` with that folder first, so an npm install finds its `node` when Buddy starts from Finder.
    static func locate(
        _ name: String,
        installFolders: [String],
        environment: [String: String],
        isExecutable: (String) -> Bool
    ) -> (executable: String, path: String)? {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + installFolders + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let folder = folders.filter({ $0.hasPrefix("/") }).first(where: { isExecutable("\($0)/\(name)") })
        else { return nil }
        return ("\(folder)/\(name)", ([folder] + (environment["PATH"].map { [$0] } ?? [])).joined(separator: ":"))
    }
}
