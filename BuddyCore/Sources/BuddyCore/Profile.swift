import Foundation

/// The owner's "about you" notes, kept as a small Markdown document with one bullet per note.
public struct Profile: Equatable, Sendable {
    public private(set) var notes: [String]

    public init(notes: [String] = []) {
        self.notes = notes
    }

    /// Reads the notes from the document's bullets. Any other line is ignored.
    public init(markdown: String) {
        notes = markdown.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let marker = trimmed.first, marker == "-" || marker == "*", trimmed.dropFirst().first == " " else { return nil }
            let note = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return note.isEmpty ? nil : note
        }
    }

    public var markdown: String {
        "# About you\n\n" + notes.map { "- \($0)\n" }.joined()
    }

    /// What the provider reads on every turn.
    var turnText: String {
        guard !notes.isEmpty else {
            return "Your owner's profile is empty. They haven't asked you to remember anything about them."
        }
        return "Your owner's profile, the notes they asked you to remember about them:\n"
            + notes.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Notes match whatever their case, spacing and final punctuation.
    mutating func apply(_ edit: ProfileEdit) {
        switch edit {
        case .remember(let note):
            guard !notes.contains(where: { Self.key($0) == Self.key(note) }) else { return }
            notes.append(note)
        case .forget(let note):
            notes.removeAll { Self.key($0) == Self.key(note) }
        }
    }

    private static func key(_ note: String) -> String {
        note.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?").union(.whitespaces))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// A change to the profile that a reply's line asks for with a REMEMBER or FORGET tag.
enum ProfileEdit: Equatable, Sendable {
    case remember(String)
    case forget(String)
}
