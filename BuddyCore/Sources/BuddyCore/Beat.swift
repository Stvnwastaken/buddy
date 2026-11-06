import Foundation

struct Tag<Gesture: Equatable & Sendable>: Equatable, Sendable {
    let gesture: Gesture
    let screen: Int?
}

struct PointGesture: Equatable, Sendable {
    let pixel: PixelPoint
    let label: String?
}

/// A box in the screenshot, given by two opposite corners.
struct PixelBox: Equatable, Sendable {
    let from: PixelPoint
    let to: PixelPoint
}

struct TypeGesture: Equatable, Sendable {
    let pixel: PixelPoint
    let text: String
}

/// The box a target rings, in global display points. A click up to `margin` outside it still counts, since a box
/// read from a screenshot is rarely exact.
struct TargetArea: Equatable, Sendable {
    static let margin = 10.0
    let minX: Double, minY: Double, maxX: Double, maxY: Double

    init(_ corner: DisplayPoint, _ opposite: DisplayPoint) {
        minX = min(corner.x, opposite.x)
        maxX = max(corner.x, opposite.x)
        minY = min(corner.y, opposite.y)
        maxY = max(corner.y, opposite.y)
    }

    func contains(_ spot: DisplayPoint) -> Bool {
        (minX - Self.margin...maxX + Self.margin).contains(spot.x) && (minY - Self.margin...maxY + Self.margin).contains(spot.y)
    }
}

/// One spoken line of a reply, with the point, annotations, target and typing that fire as the mouth starts it. A draw
/// program's beats carry its marks in `drawMarks`, on the screen it drew on.
struct Beat: Equatable, Sendable {
    let words: String
    var point: Tag<PointGesture>? = nil
    var annotations: [Tag<Annotation<PixelPoint>>] = []
    /// The brief of the agent run this line offers, from its first RUN tag.
    var offeredBrief: String? = nil
    var drawMarks: [DrawMark<PixelPoint>] = []
    /// A box to ring. The reply's later lines wait until the owner clicks inside it.
    var target: Tag<PixelBox>? = nil
    var typing: Tag<TypeGesture>? = nil

    /// The beat without its target and typing. An agent run's lines may show things but not wait for clicks or type
    /// into the owner's apps.
    var shownOnly: Beat { Beat(words: words, point: point, annotations: annotations, offeredBrief: offeredBrief, drawMarks: drawMarks) }
}

/// The beats of the lines a reply finished, and the profile edits those lines asked for.
struct ParsedLines: Equatable, Sendable {
    var beats: [Beat] = []
    var profileEdits: [ProfileEdit] = []

    static func + (lhs: ParsedLines, rhs: ParsedLines) -> ParsedLines {
        ParsedLines(beats: lhs.beats + rhs.beats, profileEdits: lhs.profileEdits + rhs.profileEdits)
    }
}

/// Splits a streamed reply into beats, one for each line as soon as it is finished.
///
/// Every `[KIND:fields]` tag is cut from the spoken words, leaving a space only between two words. A well-formed one
/// takes effect wherever it sits in its line, except that a line uses only its first POINT, RUN, TARGET and TYPE. Any
/// other tag is skipped: an unknown kind, a wrong count of whole numbers, an empty label, brief or text, or an extra
/// field. TYPE's text is the rest of the tag, colons included. REMEMBER and FORGET take the rest of the tag as their
/// note, which may hold colons but no bracket. A line with no words is skipped, but its profile edits still count.
struct BeatParser: Equatable, Sendable {
    private enum ParsedTag {
        case point(PointGesture)
        case annotation(Annotation<PixelPoint>)
        case offeredBrief(String)
        case target(PixelBox)
        case type(TypeGesture)
    }

    private var unfinished = ""

    mutating func feed(_ delta: String) -> ParsedLines {
        unfinished += delta
        var lines = unfinished.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        unfinished = String(lines.removeLast())
        return lines.map(Self.parse).reduce(ParsedLines(), +)
    }

    /// The last line, which the end of the reply finished.
    mutating func finish() -> ParsedLines {
        defer { unfinished = "" }
        return Self.parse(unfinished[...])
    }

    private static func parse(_ line: Substring) -> ParsedLines {
        let tag = /\s*\[([A-Z]+):([^\]]*)\]/
        let words = line.replacing(/(?:\s*\[[A-Z]+:[^\]]*\])+/) { match -> String in
            let neighbours = [line[..<match.range.lowerBound].last, line[match.range.upperBound...].first]
            return neighbours.allSatisfy { $0.map { $0.isLetter || $0.isNumber } ?? false } ? " " : ""
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        var point: Tag<PointGesture>?
        var annotations: [Tag<Annotation<PixelPoint>>] = []
        var profileEdits: [ProfileEdit] = []
        var offeredBrief: String?
        var target: Tag<PixelBox>?
        var typing: Tag<TypeGesture>?
        for match in line.matches(of: tag) {
            if let edit = profileEdit(kind: match.output.1, note: match.output.2) {
                profileEdits.append(edit)
                continue
            }
            var fields = match.output.2.split(separator: ":", omittingEmptySubsequences: false)
            let screen = fields.last.flatMap(screenNumber)
            if screen != nil { fields.removeLast() }
            switch gesture(kind: match.output.1, fields: fields) {
            case .point(let gesture): point = point ?? Tag(gesture: gesture, screen: screen)
            case .annotation(let annotation): annotations.append(Tag(gesture: annotation, screen: screen))
            case .offeredBrief(let brief): offeredBrief = offeredBrief ?? brief
            case .target(let box): target = target ?? Tag(gesture: box, screen: screen)
            case .type(let gesture): typing = typing ?? Tag(gesture: gesture, screen: screen)
            case nil: break
            }
        }
        guard !words.isEmpty else { return ParsedLines(profileEdits: profileEdits) }
        let beat = Beat(
            words: words, point: point, annotations: annotations, offeredBrief: offeredBrief, target: target, typing: typing
        )
        return ParsedLines(beats: [beat], profileEdits: profileEdits)
    }

    private static func profileEdit(kind: Substring, note: Substring) -> ProfileEdit? {
        let note = note.trimmingCharacters(in: .whitespaces)
        guard !note.isEmpty, !note.contains("[") else { return nil }
        switch kind {
        case "REMEMBER": return .remember(note)
        case "FORGET": return .forget(note)
        default: return nil
        }
    }

    private static func gesture(kind: Substring, fields: [Substring]) -> ParsedTag? {
        if let shape = AnnotationShape(rawValue: String(kind)) {
            guard fields.count == 1, let corners = pixels(fields[0], count: 2) else { return nil }
            return .annotation(.shape(shape, from: corners[0], to: corners[1]))
        }
        switch kind {
        case "POINT":
            guard (1...2).contains(fields.count), let spot = pixels(fields[0], count: 1) else { return nil }
            if fields.count == 1 { return .point(PointGesture(pixel: spot[0], label: nil)) }
            return label(fields[1]).map { .point(PointGesture(pixel: spot[0], label: $0)) }
        case "RUN":
            guard fields.count == 1 else { return nil }
            return label(fields[0]).map { .offeredBrief($0) }
        case "LABEL":
            guard fields.count == 2, let spot = pixels(fields[0], count: 1), let text = label(fields[1]) else { return nil }
            return .annotation(.label(text, at: spot[0]))
        case "TARGET":
            guard fields.count == 1, let corners = pixels(fields[0], count: 2) else { return nil }
            return .target(PixelBox(from: corners[0], to: corners[1]))
        case "TYPE":
            guard fields.count >= 2, let spot = pixels(fields[0], count: 1),
                  let text = label(fields.dropFirst().joined(separator: ":")[...]) else { return nil }
            return .type(TypeGesture(pixel: spot[0], text: text))
        default:
            return nil
        }
    }

    private static func pixels(_ field: Substring, count: Int) -> [PixelPoint]? {
        let numbers = field.split(separator: ",", omittingEmptySubsequences: false).map(wholeNumber)
        guard numbers.count == count * 2 else { return nil }
        let values = numbers.compactMap { $0 }
        guard values.count == numbers.count else { return nil }
        return (0..<count).map { PixelPoint(x: Double(values[$0 * 2]), y: Double(values[$0 * 2 + 1])) }
    }

    private static func wholeNumber(_ text: Substring) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    private static func screenNumber(_ field: Substring) -> Int? {
        let field = field.trimmingCharacters(in: .whitespaces)
        guard field.hasPrefix("screen") else { return nil }
        return wholeNumber(field.dropFirst("screen".count))
    }

    private static func label(_ field: Substring) -> String? {
        let text = field.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
