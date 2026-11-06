import Foundation

/// A spot in a screenshot, in its pixels from the top-left corner.
struct PixelPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

/// A location in global AppKit coordinates: points, with the origin at the bottom-left of the main display.
public struct DisplayPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A display's frame in global AppKit coordinates.
public struct DisplayRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One display's screenshot. A turn's captures are ordered, and that order is what `screenN` in a tag counts.
public struct ScreenCapture: Equatable, Sendable {
    public let jpeg: Data
    public let display: DisplayRect
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let containsCursor: Bool

    public init(jpeg: Data, display: DisplayRect, pixelWidth: Int, pixelHeight: Int, containsCursor: Bool) {
        self.jpeg = jpeg
        self.display = display
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.containsCursor = containsCursor
    }

    /// Converts a pixel in the screenshot (top-left origin) to a global display point.
    func displayPoint(_ pixel: PixelPoint) -> DisplayPoint {
        let width = Double(pixelWidth)
        let height = Double(pixelHeight)
        let x = min(max(pixel.x, 0), width) * (display.width / width)
        let y = min(max(pixel.y, 0), height) * (display.height / height)
        return DisplayPoint(x: display.x + x, y: display.y + display.height - y)
    }
}

extension [ScreenCapture] {
    func capture(for screen: Int?) -> ScreenCapture? {
        if let screen, indices.contains(screen - 1) { return self[screen - 1] }
        return first(where: \.containsCursor)
    }

    /// The screen a draw program draws on: the one with the cursor, else the first.
    var drawCanvas: ScreenCapture? {
        capture(for: nil) ?? first
    }

    var labeled: [TurnContent] {
        enumerated().flatMap { index, capture -> [TurnContent] in
            let cursor = capture.containsCursor ? ", with the cursor" : ""
            let label = "Screen \(index + 1) of \(count), \(capture.pixelWidth)x\(capture.pixelHeight) pixels\(cursor):"
            return [.text(label), .jpeg(capture.jpeg)]
        }
    }
}

public struct TurnRequest: Equatable, Sendable {
    public let transcript: String
    public let captures: [ScreenCapture]
    /// Summaries of the conversations before this one, oldest first.
    public let earlierSummaries: [String]
    /// This conversation's own summary of the turns before `recentTurns`.
    public let summary: String?
    public let recentTurns: [TurnRecord]
    /// The owner's profile, read on every talk turn. A utility model question has none.
    public let profile: Profile?
    /// The dock's agent runs, summarized on every talk turn. A utility model question has none.
    public let runs: [AgentRun]?
    /// The date where the owner is as they ask, such as "Sunday, November 1, 2026", so a web search about today
    /// searches the right day.
    public let today: String?

    public init(
        transcript: String,
        captures: [ScreenCapture],
        earlierSummaries: [String] = [],
        summary: String? = nil,
        recentTurns: [TurnRecord] = [],
        profile: Profile = Profile(),
        runs: [AgentRun] = [],
        today: String? = nil
    ) {
        self.init(
            transcript: transcript, captures: captures, earlierSummaries: earlierSummaries, summary: summary,
            recentTurns: recentTurns, profile: Optional(profile), runs: Optional(runs), today: today
        )
    }

    private init(
        transcript: String,
        captures: [ScreenCapture],
        earlierSummaries: [String],
        summary: String?,
        recentTurns: [TurnRecord],
        profile: Profile?,
        runs: [AgentRun]?,
        today: String?
    ) {
        self.transcript = transcript
        self.captures = captures
        self.earlierSummaries = earlierSummaries
        self.summary = summary
        self.recentTurns = recentTurns
        self.profile = profile
        self.runs = runs
        self.today = today
    }

    /// A text-only question for the utility model, without the owner's profile.
    static func question(_ text: String) -> TurnRequest {
        TurnRequest(
            transcript: text, captures: [], earlierSummaries: [], summary: nil, recentTurns: [], profile: nil, runs: nil,
            today: nil
        )
    }

    /// The same turn for a provider that is already primed: it keeps the profile, the dock, the date, screenshots and
    /// transcript, and drops the summaries and recent turns the provider already holds.
    var withoutPriming: TurnRequest {
        TurnRequest(
            transcript: transcript, captures: captures, earlierSummaries: [], summary: nil, recentTurns: [],
            profile: profile, runs: runs, today: today
        )
    }

    /// What the provider reads: the profile, the dock, the text priming, the date, the labeled screenshots, then the
    /// transcript.
    public var content: [TurnContent] {
        var texts = (profile.map { [$0.turnText] } ?? []) + (runs.map { [$0.dockSummary] } ?? [])
        if !earlierSummaries.isEmpty {
            texts.append("Summaries of earlier conversations, oldest first:\n" + earlierSummaries.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let summary { texts.append("Summary of this conversation so far:\n\(summary)") }
        if !recentTurns.isEmpty {
            texts.append("Recent exchanges in this conversation (text only):\n" + recentTurns.dialogue)
        }
        if let today { texts.append("Today is \(today).") }
        return texts.map(TurnContent.text) + captures.labeled + [.text(transcript)]
    }
}

public enum TurnContent: Equatable, Sendable {
    case text(String)
    case jpeg(Data)
}

public enum ProviderEvent: Equatable, Sendable {
    case textDelta(String)
    /// The provider started a web search for the reply.
    case searching
    case usage(ProviderUsage)
    case completed
    case failed(ProviderFailure)
}

public enum ProviderFailure: Error, Equatable, Sendable {
    case notInstalled
    case signedOut
    /// The provider refused the turn because the owner's subscription reached its usage limit.
    case limitReached
    case error(String)
}

/// How much of a provider's usage limits is spent, as it last reported. A plan without one of the windows reports nil
/// for it.
public struct ProviderUsage: Codable, Equatable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    /// The spent share of the window's limit, from 0 to 1.
    public let utilization: Double
    public let resetsAt: Date

    public init(utilization: Double, resetsAt: Date) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// The text of one finished turn: what the owner said and the reply with its tags stripped.
public struct TurnRecord: Codable, Equatable, Sendable {
    public let transcript: String
    public let reply: String

    public init(transcript: String, reply: String) {
        self.transcript = transcript
        self.reply = reply
    }
}
