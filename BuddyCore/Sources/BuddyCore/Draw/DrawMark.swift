import CoreText
import Foundation

/// A mark a draw program records. The app redraws it natively while its beat's line plays.
public enum DrawMark<Point: Equatable & Sendable>: Equatable, Sendable {
    /// A freehand line through the points, in order.
    case stroke([Point])
    /// Tail at `from`, head at `to`.
    case arrow(from: Point, to: Point)
    /// Circles the box with these opposite corners.
    case ring(from: Point, to: Point)
    /// Words whose top-left corner is `at`, in `DrawText.font` of `size`, in the same units as the points.
    case text(String, at: Point, size: Double)
    case handwriting(String, at: Point, size: Double)
    case paper(DrawPaper<Point>)

    func map<T>(scale: Double, _ transform: (Point) -> T) -> DrawMark<T> {
        switch self {
        case .stroke(let points): .stroke(points.map(transform))
        case .arrow(let from, let to): .arrow(from: transform(from), to: transform(to))
        case .ring(let from, let to): .ring(from: transform(from), to: transform(to))
        case .text(let words, let at, let size): .text(words, at: transform(at), size: size * scale)
        case .handwriting(let words, let at, let size): .handwriting(words, at: transform(at), size: size * scale)
        case .paper(let paper): .paper(DrawPaper(
            id: paper.id, kind: paper.kind, words: paper.words, at: transform(paper.at),
            width: paper.width * scale, size: paper.size * scale
        ))
        }
    }
}

/// One scratch, relative to the start of a line's mark reveals.
public struct PenSoundCue: Equatable, Sendable {
    public let offset: Double
    public let duration: Double

    public init(offset: Double, duration: Double) {
        self.offset = offset
        self.duration = duration
    }
}

/// The font of a draw program's text. The program measures text with it and the app draws text with it, so a ring
/// drawn around measured words fits them.
public enum DrawText {
    private static let registerHandwriting: Void = {
        guard let url = Bundle.module.url(forResource: "PatrickHand-Regular", withExtension: "ttf", subdirectory: "PatrickHand") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    public static func font(size: Double, handwriting: Bool = false) -> CTFont {
        if handwriting {
            _ = registerHandwriting
            return CTFontCreateWithName("PatrickHand-Regular" as CFString, size, nil)
        }
        return CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    /// One line of `words` set in the font, with its width and the font's ascent and descent. Text of one size is
    /// always `ascent + descent` tall, whatever its words.
    public static func line(_ words: String, size: Double, handwriting: Bool = false) -> (line: CTLine, width: Double, ascent: Double, descent: Double) {
        let font = font(size: size, handwriting: handwriting)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, words as CFString, attributes))
        return (line, CTLineGetTypographicBounds(line, nil, nil, nil), CTFontGetAscent(font), CTFontGetDescent(font))
    }

    public static func path(_ words: String, size: Double, top: CGPoint = .zero, handwriting: Bool = false) -> CGPath {
        let typeset = line(words, size: size, handwriting: handwriting)
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(typeset.line) as? [CTRun] ?? [] {
            let attribute = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String]
            let font = attribute.map { $0 as! CTFont } ?? font(size: size, handwriting: handwriting)
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                path.addPath(outline, transform: CGAffineTransform(translationX: top.x + position.x,
                                                                  y: top.y - typeset.ascent + position.y))
            }
        }
        return path
    }
}

public extension DrawMark where Point == DisplayPoint {
    /// Shared by native mark playback and its optional pen cues.
    var revealDuration: Double {
        let length: Double
        let speed: Double
        switch self {
        case .stroke(let points):
            length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            speed = 900
        case .arrow(let from, let to):
            length = hypot(to.x - from.x, to.y - from.y) + 28
            speed = 900
        case .ring(let from, let to):
            length = .pi * (max(abs(to.x - from.x) + 16, 28) + max(abs(to.y - from.y) + 16, 28)) / 2
            speed = 900
        case .text(let words, _, let size):
            length = DrawText.path(words, size: size).boundingBoxOfPath.width
            speed = 500
        case .handwriting(let words, _, let size):
            length = DrawText.path(words, size: size, handwriting: true).boundingBoxOfPath.width
            speed = 500
        case .paper(let paper):
            length = paper.width
            speed = 500
        }
        return min(max(length / speed, 0.25), 1.2)
    }
}

/// Paper content stays together when the owner drags it. The engine assigns an id when its line starts.
public enum DrawPaperKind: Equatable, Sendable { case sticky, card }

public struct DrawPaper<Point: Equatable & Sendable>: Equatable, Sendable {
    public var id: Int
    public let kind: DrawPaperKind
    public let words: String
    public var at: Point
    public let width: Double
    public let size: Double

    public init(id: Int = 0, kind: DrawPaperKind, words: String, at: Point, width: Double, size: Double) {
        self.id = id
        self.kind = kind
        self.words = words
        self.at = at
        self.width = width
        self.size = size
    }
}

public struct PlacedPaper: Equatable, Sendable {
    public var paper: DrawPaper<DisplayPoint>
    public let display: DisplayRect
    public var pinned: Bool

    public init(paper: DrawPaper<DisplayPoint>, display: DisplayRect, pinned: Bool = false) {
        self.paper = paper
        self.display = display
        self.pinned = pinned
    }
}
