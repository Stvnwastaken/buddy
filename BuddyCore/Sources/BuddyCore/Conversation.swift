import Foundation

/// The durable record contains text and times only. Screen captures never enter it.
public struct ConversationHistory: Codable, Equatable, Sendable {
    /// A fresh provider process is primed with at most this many of the active conversation's latest turns.
    static let recentTurnLimit = 10
    /// The most summaries of earlier conversations a fresh provider process is primed with, newest kept first.
    static let summaryLimit = (count: 5, characters: 2_000)

    public private(set) var conversations: [Conversation]
    private var nextConversationID: Int

    public init(conversations: [Conversation] = []) {
        self.conversations = conversations
        nextConversationID = (conversations.map(\.id).max() ?? -1) + 1
        for index in self.conversations.indices where self.conversations[index].id < 0 {
            self.conversations[index].id = nextConversationID
            nextConversationID += 1
        }
    }

    private enum CodingKeys: String, CodingKey { case conversations, nextConversationID }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try values.decode([Conversation].self, forKey: .conversations)
        guard decoded.allSatisfy({ $0.id < Int.max - decoded.count }) else {
            throw DecodingError.dataCorruptedError(forKey: .conversations, in: values, debugDescription: "Conversation identifiers are exhausted")
        }
        self.init(conversations: decoded)
        guard Set(conversations.map(\.id)).count == conversations.count else {
            throw DecodingError.dataCorruptedError(forKey: .conversations, in: values, debugDescription: "Duplicate conversation identifiers")
        }
        let next = try values.decodeIfPresent(Int.self, forKey: .nextConversationID) ?? nextConversationID
        guard next >= nextConversationID, next < Int.max else {
            throw DecodingError.dataCorruptedError(forKey: .nextConversationID, in: values, debugDescription: "Invalid next conversation identifier")
        }
        nextConversationID = next
    }

    /// Changes when turns or conversation selection change, including reopening and deletion.
    var progress: [Int] { conversations.flatMap { [$0.id, $0.turns.count, $0.endedAt == nil ? 0 : 1] } }

    var active: Conversation? { conversations.last.flatMap { $0.endedAt == nil ? $0 : nil } }

    /// The active conversation's latest turns that its own summary doesn't cover yet.
    var recentTurns: [TurnRecord] {
        guard let active else { return [] }
        return Array(active.turns.dropFirst(active.summary?.turns ?? 0).suffix(Self.recentTurnLimit))
    }

    /// The newest summaries of ended conversations that fit the limit, oldest first.
    var earlierSummaries: [String] {
        var kept: [String] = []
        var characters = 0
        for conversation in conversations.reversed() where conversation.endedAt != nil {
            guard let text = conversation.summary?.text else { continue }
            guard kept.count < Self.summaryLimit.count, characters + text.count <= Self.summaryLimit.characters else { break }
            kept.append(text)
            characters += text.count
        }
        return kept.reversed()
    }

    /// The newest conversation whose summary is behind: an ended one that could still prime a later conversation,
    /// or the active one once turns fall out of its recent turns.
    var unsummarized: (conversation: Int, turns: [TurnRecord])? {
        let considered = Self.summaryLimit.count + (active == nil ? 0 : 1)
        for index in conversations.indices.suffix(considered).reversed() {
            let conversation = conversations[index]
            let covered = conversation.summary?.turns ?? 0
            let due = conversation.endedAt == nil
                ? max(0, conversation.turns.count - Self.recentTurnLimit)
                : conversation.turns.count
            if covered < due { return (index, Array(conversation.turns[covered..<due])) }
        }
        return nil
    }

    mutating func append(_ record: TurnRecord, at date: Date) {
        if active == nil {
            conversations.append(Conversation(turns: [], startedAt: date, lastActivity: date, id: nextConversationID))
            nextConversationID += 1
        }
        conversations[conversations.count - 1].turns.append(record)
        conversations[conversations.count - 1].lastActivity = max(date, conversations[conversations.count - 1].lastActivity)
    }

    mutating func touch(at date: Date) -> Bool {
        guard let active, date > active.lastActivity else { return false }
        conversations[conversations.count - 1].lastActivity = date
        return true
    }

    mutating func end(at date: Date) -> Bool {
        guard active != nil else { return false }
        conversations[conversations.count - 1].endedAt = date
        return true
    }

    mutating func reopen(_ id: Int, at date: Date) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == id }), active?.id != id else { return false }
        _ = end(at: date)
        var conversation = conversations.remove(at: index)
        conversation.endedAt = nil
        conversation.lastActivity = max(date, conversation.lastActivity)
        conversations.append(conversation)
        return true
    }

    mutating func delete(_ id: Int) {
        conversations.removeAll { $0.id == id }
    }

    mutating func summarize(_ id: Int, as text: String, adding turns: Int) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let covered = conversations[index].summary?.turns ?? 0
        conversations[index].summary = ConversationSummary(text: text, turns: covered + turns)
    }
}

public struct Conversation: Codable, Equatable, Sendable {
    public fileprivate(set) var id: Int
    public fileprivate(set) var turns: [TurnRecord]
    /// When the first turn was asked. History saved before this was recorded starts at its last activity.
    public let startedAt: Date
    public fileprivate(set) var lastActivity: Date
    public fileprivate(set) var endedAt: Date?
    public fileprivate(set) var summary: ConversationSummary?

    public init(turns: [TurnRecord], startedAt: Date? = nil, lastActivity: Date, endedAt: Date? = nil,
                summary: ConversationSummary? = nil, id: Int = -1) {
        self.id = id
        self.turns = turns
        self.startedAt = startedAt ?? lastActivity
        self.lastActivity = lastActivity
        self.endedAt = endedAt
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey { case id, turns, startedAt, lastActivity, endedAt, summary }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decodeIfPresent(Int.self, forKey: .id)
        if let id, id < 0 {
            throw DecodingError.dataCorruptedError(forKey: .id, in: values, debugDescription: "Invalid conversation identifier")
        }
        self.init(
            turns: try values.decode([TurnRecord].self, forKey: .turns),
            startedAt: try values.decodeIfPresent(Date.self, forKey: .startedAt),
            lastActivity: try values.decode(Date.self, forKey: .lastActivity),
            endedAt: try values.decodeIfPresent(Date.self, forKey: .endedAt),
            summary: try values.decodeIfPresent(ConversationSummary.self, forKey: .summary),
            id: id ?? -1
        )
    }
}

/// What the utility model wrote about a conversation's first `turns` turns.
public struct ConversationSummary: Codable, Equatable, Sendable {
    public let text: String
    public let turns: Int

    public init(text: String, turns: Int) {
        self.text = text
        self.turns = turns
    }
}

/// Asks the utility model to fold a conversation's next turns into its summary.
public struct SummaryRequest: Equatable, Sendable {
    public let id: Int
    /// The durable conversation identifier, independent of its position in history.
    public let conversation: Int
    public let summary: String?
    public let turns: [TurnRecord]

    public init(id: Int, conversation: Int, summary: String?, turns: [TurnRecord]) {
        self.id = id
        self.conversation = conversation
        self.summary = summary
        self.turns = turns
    }

    /// The message the utility model reads. `UtilityInstructions.system` says how to write the summary.
    public var prompt: String {
        (["Fold these new turns into the conversation summary."]
            + (summary.map { ["Summary so far:\n\($0)"] } ?? [])
            + ["New turns:\n\(turns.dialogue)"]).joined(separator: "\n\n")
    }
}

extension [TurnRecord] {
    var dialogue: String {
        map { "Owner: \($0.transcript)\nBuddy: \($0.reply)" }.joined(separator: "\n\n")
    }
}
