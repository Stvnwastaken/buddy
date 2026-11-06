/// A shape the buddy can draw. Its raw value is the tag that draws it, as in `[RING:x1,y1,x2,y2]`.
public enum AnnotationShape: String, Equatable, Sendable {
    case arrow = "ARROW", line = "LINE", ring = "RING", underline = "UNDERLINE", highlight = "HIGHLIGHT"
}

public enum Annotation<Point: Equatable & Sendable>: Equatable, Sendable {
    /// arrow: tail at `from`, head at `to`. line: `from` to `to`. ring, underline, highlight: the box with these
    /// opposite corners.
    case shape(AnnotationShape, from: Point, to: Point)
    /// A pill holding the text beside `at`.
    case label(String, at: Point)

    func map<T>(_ transform: (Point) -> T) -> Annotation<T> {
        switch self {
        case .shape(let shape, let from, let to): .shape(shape, from: transform(from), to: transform(to))
        case .label(let text, let point): .label(text, at: transform(point))
        }
    }
}
