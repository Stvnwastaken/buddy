import Foundation

/// What the notch at the top of the cursor's screen shows. Idle, it is the buddy icon beside the camera notch. During a
/// turn a strip drops down from it with the turn's text.
public enum Notch: Equatable, Sendable {
    /// The icon alone, with the strip closed.
    case idle
    /// Push-to-talk is held. The strip shows a waveform and the words heard so far.
    case listening(heard: String)
    /// The question is asked and no line of the reply has started yet.
    case thinking
    /// The line of the reply being spoken, or being read while spoken replies are off.
    case line(String)
    /// A failure or other message for the owner. The app sends `noticeExpired` a few seconds after it.
    case notice(String)
    /// The reply has ended. The strip keeps its last line for a few seconds, then closes.
    case closing
}

/// The current conversation and the owner's interaction with the open notch. The strip remains independent so a
/// hovering owner can read earlier turns while a new line is spoken.
public struct NotchConversation: Equatable, Sendable {
    public enum Page: Equatable, Sendable { case thread, history }

    public struct HistoryItem: Equatable, Sendable, Identifiable {
        public let id: Int
        public let question: String
        public let startedAt: Date
        public let lastActivity: Date

        public init(id: Int, question: String, startedAt: Date, lastActivity: Date) {
            self.id = id
            self.question = question
            self.startedAt = startedAt
            self.lastActivity = lastActivity
        }
    }

    public internal(set) var page = Page.thread
    public internal(set) var pastConversations: [HistoryItem] = []
    public enum Entry: Equatable, Sendable {
        case owner(String), buddy(String), notice(String)
    }

    public internal(set) var entries: [Entry] = []
    public internal(set) var isOpen = false
    public internal(set) var focused = false
    public internal(set) var draft = ""
    var pointerInside = false
    var hoverBegan: Date?

    public init() {}

    mutating func closeIfUnused() {
        if !pointerInside && !focused && draft.isEmpty { isOpen = false }
    }
}
