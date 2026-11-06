import Foundation

/// One of the owner's AI subscriptions the buddy can think with.
public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude, codex

    public var title: String { self == .claude ? "Claude" : "Codex" }

    var other: Provider { self == .claude ? .codex : .claude }
}

/// The choice for talk or new agent runs: Auto routes by headroom, and naming a provider forces it.
public enum ProviderChoice: String, Codable, CaseIterable, Sendable {
    case auto, claude, codex

    public var title: String { self == .auto ? "Auto" : (forced?.title ?? "") }

    public var forced: Provider? {
        switch self {
        case .auto: nil
        case .claude: .claude
        case .codex: .codex
        }
    }
}

/// How the app reaches the providers.
public enum TalkSetup: Equatable, Sendable {
    /// Each provider on its own CLI and sign-in, which report the usage the router works from.
    case direct(ProviderChoice)
    /// The owner's CLIProxy hub serves this provider through Claude Code's transport. Its figures aren't the
    /// provider's own sign-in's, so Buddy records none and never routes.
    case proxied(Provider)

    var choice: ProviderChoice {
        switch self {
        case .direct(let choice): choice
        case .proxied(.claude): .claude
        case .proxied(.codex): .codex
        }
    }

    /// The CLI that answers talk for the provider. Through the hub, Claude Code answers for both.
    public func cli(for provider: Provider) -> ProviderCLI {
        if case .direct = self, provider == .codex { return .codex }
        return .claudeCode
    }
}

/// The latest usage each provider reported. Kept across launches, so routing starts from what was last known.
public struct UsageSnapshots: Codable, Equatable, Sendable {
    public var claude: ProviderUsage?
    public var codex: ProviderUsage?

    public init(claude: ProviderUsage? = nil, codex: ProviderUsage? = nil) {
        self.claude = claude
        self.codex = codex
    }

    public subscript(provider: Provider) -> ProviderUsage? {
        get { provider == .claude ? claude : codex }
        set { if provider == .claude { claude = newValue } else { codex = newValue } }
    }
}

extension ProviderUsage {
    /// 1 minus the higher utilization of its windows, where a window whose reset time has passed counts as unused.
    /// Nil when the provider reported no window.
    public func headroom(at now: Date) -> Double? {
        let spent = [fiveHour, sevenDay].compactMap { $0.map { $0.resetsAt > now ? $0.utilization : 0 } }
        return spent.max().map { min(1, max(0, 1 - $0)) }
    }

    /// The usage after the provider refused a turn for its limit: its fullest live window is full. With no live
    /// window known, the five-hour window counts as full for five hours, the longest it can take to reset.
    func reachingLimit(at now: Date) -> ProviderUsage {
        let live = { (window: UsageWindow?) in window.flatMap { $0.resetsAt > now ? $0 : nil } }
        if let sevenDay = live(sevenDay), sevenDay.utilization >= live(fiveHour)?.utilization ?? 0 {
            return ProviderUsage(fiveHour: fiveHour, sevenDay: UsageWindow(utilization: 1, resetsAt: sevenDay.resetsAt))
        }
        let resetsAt = live(fiveHour)?.resetsAt ?? now.addingTimeInterval(5 * 60 * 60)
        return ProviderUsage(fiveHour: UsageWindow(utilization: 1, resetsAt: resetsAt), sevenDay: sevenDay)
    }
}

public enum ProviderRouter {
    /// How far the other provider's headroom must lead before a turn leaves the current one's warm process.
    public static let margin = 0.15

    /// The provider for the next turn. A forced choice always wins. Under Auto the turn stays on the current
    /// provider unless the other leads by `margin`, or the current one has reached its limit and the other hasn't.
    /// Unknown usage never shows a lead.
    public static func route(from current: Provider, choice: ProviderChoice, usage: UsageSnapshots, at now: Date) -> Provider {
        if let forced = choice.forced { return forced }
        let other = current.other
        let currentHeadroom = usage[current]?.headroom(at: now)
        let otherHeadroom = usage[other]?.headroom(at: now)
        if let currentHeadroom, currentHeadroom <= 0 { return (otherHeadroom ?? 1) > 0 ? other : current }
        guard let currentHeadroom, let otherHeadroom else { return current }
        // The tolerance keeps float error from turning an exact 15-point lead into 14.999.
        return otherHeadroom - currentHeadroom >= margin - 1e-9 ? other : current
    }
}
