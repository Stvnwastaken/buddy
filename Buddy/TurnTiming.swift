import BuddyCore
import os

extension Logger {
    /// Turn timing for `/usr/bin/log stream --predicate 'subsystem == "dev.steven.buddy"' --level debug`.
    /// It records case names, which ears listened and which voice spoke, never transcripts, replies or screenshots.
    nonisolated static let turnTiming = Logger(subsystem: "dev.steven.buddy", category: "turn-timing")
}

extension BuddyEngine.Event {
    var logName: String {
        switch self {
        case .provider(let event): "provider." + caseName(of: event)
        case .neuralVoiceObserved(let status): "neuralVoiceObserved." + caseName(of: status)
        case .run(_, let event): "run." + caseName(of: event)
        default: caseName(of: self)
        }
    }

    /// Modifier changes, key presses and clicks arrive from every app. They are logged only when they do something,
    /// so the log never records the owner's typing.
    var isGlobalInput: Bool {
        switch self {
        case .modifiersChanged, .keyOrButtonPressed, .clicked, .notchPointerChanged, .notchHoverElapsed, .textBoxChanged: true
        default: false
        }
    }
}

extension BuddyEngine.Effect {
    var logName: String {
        if case .speak(_, let voice, _) = self { return "speak.\(voice)" }
        if case .playCue(let cue) = self { return "playCue.\(cue)" }
        return caseName(of: self)
    }
}

private func caseName(of value: Any) -> String {
    Mirror(reflecting: value).children.first?.label ?? String(describing: value)
}
