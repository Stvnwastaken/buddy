extension [AgentRun] {
    /// What talk reads about the dock on every turn, so Buddy can say how each run is going.
    var dockSummary: String {
        guard !isEmpty else { return "The dock has no agent runs." }
        return "The dock's agent runs, oldest first:\n\n" + map(\.dockSummary).joined(separator: "\n\n")
    }
}

extension AgentRun {
    private static let longest = 500

    /// The card's entry in the dock summary. It names the run only once the run has named itself, since the request
    /// follows anyway.
    var dockSummary: String {
        let nameClause = namesItself ? ", \"\(name)\"," : ""
        var lines = ["Run \(id.number)\(nameClause) \(statusWords).", "The owner asked: \(brief.request)"]
        if case .failed(let message) = status { lines.append("Why it failed: \(message)") }
        for case .approval(_, let action, _) in asks {
            lines.append("It waits for the owner to approve or deny this on its card: \(Self.clipped(action))")
        }
        for case .takeover(_, let reason) in asks {
            lines.append("It waits for the owner to allow or refuse it the mouse and keyboard on its card: \(Self.clipped(reason))")
        }
        if !noteBody.isEmpty { lines.append("Run note:\n\(Self.clipped(noteBody))") }
        if status == .done {
            let report = (report ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(report.isEmpty ? "It finished without a report." : "Report: \(Self.clipped(report))")
        }
        return lines.joined(separator: "\n")
    }

    private var statusWords: String {
        switch status {
        case .running: "is working"
        case .paused: "is switching providers"
        case .needsOwner: "is waiting for the owner"
        case .takingOver: "is using the owner's mouse and keyboard"
        case .done: "is done"
        case .failed: "failed"
        case .stopped(.owner): "was stopped by the owner"
        case .stopped(.stepCap): "was stopped at its step cap"
        case .stopped(.timeCap): "was stopped at its time cap"
        }
    }

    private static func clipped(_ text: String) -> String {
        text.count > longest ? text.prefix(longest) + "…" : text
    }
}
