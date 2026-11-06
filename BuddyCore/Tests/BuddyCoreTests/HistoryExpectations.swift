import Foundation
import BuddyCore

func savedTurn(transcript: String, reply: String) -> BuddyEngine.Effect {
    .saveHistory(ConversationHistory(conversations: [Conversation(
        turns: [TurnRecord(transcript: transcript, reply: reply)],
        lastActivity: Date(timeIntervalSince1970: 1_000)
    )]))
}
