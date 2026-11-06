import Foundation

/// A provider process that answers turns.
@MainActor
public protocol ProviderSession: AnyObject {
    func start()
    func send(_ turn: TurnRequest, onEvent: @escaping (ProviderEvent) -> Void)
    func endConversation()
    func stop()
}

extension ClaudeBrain: ProviderSession {}
extension CodexBrain: ProviderSession {}

/// Buddy's utility model: a warm provider session on a small fast model for short text requests, such as
/// conversation summaries.
///
/// Each question ends its session's conversation once answered, so one answer never sees another question's text:
/// Claude starts a new process and Codex a new thread, ready by the time the next question comes.
@MainActor
public final class UtilityModel {
    private struct Question {
        let id: Int
        let onAnswer: (Result<String, ProviderFailure>) -> Void
    }

    private let session: any ProviderSession
    private var questions = 0
    private var answering: Question?

    public init(_ session: any ProviderSession) {
        self.session = session
    }

    public func start() {
        session.start()
    }

    /// Warms a session for the current provider selection. A question being answered keeps its session, which is
    /// renewed once it answers.
    public func refresh() {
        guard answering == nil else { return }
        renew()
    }

    /// Fails the question being answered, if any, and warms a new session.
    public func cancel() {
        drop()
        renew()
    }

    /// Fails the question being answered, if any, and ends the session.
    public func stop() {
        drop()
        session.stop()
    }

    /// The answer always arrives after `ask` returns.
    public func ask(_ question: String, onAnswer: @escaping (Result<String, ProviderFailure>) -> Void) {
        drop()
        questions += 1
        let current = questions
        answering = Question(id: current, onAnswer: onAnswer)
        var answer = ""
        session.send(.question(question)) { [weak self] event in
            guard let self, answering?.id == current else { return }
            switch event {
            case .textDelta(let text):
                answer += text
            case .usage, .searching:
                break
            case .completed:
                answering = nil
                renew()
                onAnswer(.success(answer))
            case .failed(let failure):
                answering = nil
                renew()
                onAnswer(.failure(failure))
            }
        }
    }

    private func drop() {
        guard let question = answering else { return }
        answering = nil
        question.onAnswer(.failure(.error("the question was dropped")))
    }

    private func renew() {
        session.endConversation()
        session.start()
    }
}
