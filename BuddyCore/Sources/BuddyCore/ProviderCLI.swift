/// One of the owner's CLIs Buddy can think with. Talk and agent runs each use the one the owner chose for them.
public enum ProviderCLI: Equatable, Sendable {
    case claudeCode, codex

    var provider: Provider { self == .codex ? .codex : .claude }

    init(_ provider: Provider) {
        self = provider == .codex ? .codex : .claudeCode
    }

    /// What the owner reads when this CLI can't answer.
    func notice(for failure: ProviderFailure) -> String {
        switch (self, failure) {
        case (.claudeCode, .notInstalled): "Claude Code isn't installed. Install it and sign in, then try again."
        case (.claudeCode, .signedOut): "Claude Code is signed out. Run claude in Terminal to sign in."
        case (.claudeCode, .limitReached): "Claude Code reached its usage limit. Try again after it resets."
        case (.claudeCode, .error(let detail)): "Claude Code failed: \(detail)"
        case (.codex, .notInstalled): "Codex isn't installed. Install it and sign in, then try again."
        case (.codex, .signedOut): "Codex isn't signed in with ChatGPT. Run codex login in Terminal to sign in."
        case (.codex, .limitReached): "Codex reached its usage limit. Try again after it resets."
        case (.codex, .error(let detail)): "Codex failed: \(detail)"
        }
    }
}
