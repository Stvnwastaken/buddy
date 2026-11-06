import Foundation
import JavaScriptCore

enum DrawFailure: Error, Equatable {
    case unavailable, noScreen, timedOut, nothingSaid
    case failed(String)

    var notice: String {
        switch self {
        case .unavailable: "Draw programs can't run on this Mac."
        case .noScreen: "There was no screen to draw on."
        case .timedOut: "The draw program took too long, so I stopped it."
        case .nothingSaid: "The draw program had nothing to say."
        case .failed(let error): "The draw program failed: \(error)"
        }
    }
}

private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
private typealias SetExecutionTimeLimit = @convention(c) (JSContextGroupRef, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

/// JavaScriptCore exports this function but leaves it out of its public headers, so it is looked up at run time.
private let setExecutionTimeLimit = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit")
    .map { unsafeBitCast($0, to: SetExecutionTimeLimit.self) }

/// Runs a draw program in a fresh JavaScriptCore context that has only the language's built-in objects and the draw
/// API, and stops it when its time runs out. The program's calls record beats and their marks; nothing else leaves it.
struct DrawSandbox: Sendable {
    static let beatLimit = 30, markLimit = 200, strokePointLimit = 500, lineLimit = 300, textLimit = 200
    static let defaultTextSize = 32.0

    let timeLimit: Duration

    func run(_ source: String, width: Int, height: Int) -> Result<[Beat], DrawFailure> {
        guard let setExecutionTimeLimit else { return .failure(.unavailable) }
        return autoreleasepool {
            let watchdog = Watchdog()
            let group = JSContextGroupCreate()!
            defer { JSContextGroupRelease(group) }
            let seconds = Double(timeLimit.components.seconds) + Double(timeLimit.components.attoseconds) / 1e18
            setExecutionTimeLimit(group, seconds, { _, info in
                Unmanaged<Watchdog>.fromOpaque(info!).takeUnretainedValue().fired = true
                return true
            }, Unmanaged.passUnretained(watchdog).toOpaque())
            let global = JSGlobalContextCreateInGroup(group, nil)!
            defer { JSGlobalContextRelease(global) }
            let context = JSContext(jsGlobalContextRef: global)!
            let recording = Recording()
            install(recording, width: width, height: height, in: context)
            context.evaluateScript(source)
            return withExtendedLifetime(watchdog) {
                if watchdog.fired { return .failure(.timedOut) }
                if let exception = context.exception { return .failure(.failed(exception.toString() ?? "an unknown error")) }
                return recording.beats.isEmpty ? .failure(.nothingSaid) : .success(recording.beats)
            }
        }
    }

    private func install(_ recording: Recording, width: Int, height: Int, in context: JSContext) {
        let global = context.globalObject!
        global.deleteProperty("console")
        global.deleteProperty("WebAssembly")
        let canvas = JSValue(object: ["width": width, "height": height], in: context)!
        context.objectForKeyedSubscript("Object").invokeMethod("freeze", withArguments: [canvas])
        global.setValue(canvas, forProperty: "canvas")
        define("beat", in: context) { arguments in
            guard let line = arguments.first, line.isString else { return Self.fail("beat(line) needs a line to say.") }
            let words = Self.collapsed(line.toString())
            guard !words.isEmpty else { return Self.fail("beat(line) needs a line to say.") }
            guard words.count <= Self.lineLimit else { return Self.fail("A line can have at most \(Self.lineLimit) characters.") }
            guard recording.beats.count < Self.beatLimit else { return Self.fail("A draw program can have at most \(Self.beatLimit) beats.") }
            recording.beats.append(Beat(words: words))
            return nil
        }
        let shapes: [(String, (PixelPoint, PixelPoint) -> DrawMark<PixelPoint>)] = [
            ("arrow", { .arrow(from: $0, to: $1) }), ("ring", { .ring(from: $0, to: $1) })
        ]
        for (name, shape) in shapes {
            define(name, in: context) { arguments in
                let numbers = arguments.prefix(4).compactMap(Self.number)
                guard numbers.count == 4 else { return Self.fail("\(name) needs four finite numbers.") }
                return recording.add(shape(PixelPoint(x: numbers[0], y: numbers[1]), PixelPoint(x: numbers[2], y: numbers[3])))
            }
        }
        define("stroke", in: context) { arguments in
            switch Self.points(arguments.first) {
            case .tooMany: return Self.fail("A stroke can have at most \(Self.strokePointLimit) points.")
            case .points(let points) where points.count >= 2: return recording.add(.stroke(points))
            case .points, .invalid: return Self.fail("stroke needs at least 2 points, each [x, y].")
            }
        }
        for name in ["text", "handwriting"] {
            define(name, in: context) { arguments in
                let words = arguments.first.flatMap { $0.isString ? Self.collapsed($0.toString()) : nil } ?? ""
                let position = arguments.dropFirst().prefix(2).compactMap(Self.number)
                guard !words.isEmpty, position.count == 2 else { return Self.fail("\(name) needs words, then x and y.") }
                guard words.count <= Self.textLimit else { return Self.fail("Text can have at most \(Self.textLimit) characters.") }
                guard let size = Self.size(arguments.dropFirst(3).first) else { return Self.fail("\(name)'s size must be a positive number.") }
                let at = PixelPoint(x: position[0], y: position[1])
                return recording.add(name == "handwriting" ? .handwriting(words, at: at, size: size) : .text(words, at: at, size: size))
            }
        }
        for (name, kind, width) in [("sticky", DrawPaperKind.sticky, 240.0), ("card", DrawPaperKind.card, 420.0)] {
            define(name, in: context) { arguments in
                let words = arguments.first.flatMap { $0.isString ? Self.collapsed($0.toString()) : nil } ?? ""
                let position = arguments.dropFirst().prefix(2).compactMap(Self.number)
                guard !words.isEmpty, position.count == 2 else { return Self.fail("\(name) needs words, then x and y.") }
                guard words.count <= Self.textLimit else { return Self.fail("Text can have at most \(Self.textLimit) characters.") }
                let widthArgument = arguments.dropFirst(3).first
                let paperWidth = widthArgument.map { $0.isUndefined ? width : Self.number($0) } ?? width
                guard let paperWidth, paperWidth > 0 else { return Self.fail("\(name)'s width must be a positive number.") }
                guard let size = Self.size(arguments.dropFirst(4).first) else { return Self.fail("\(name)'s size must be a positive number.") }
                return recording.add(.paper(DrawPaper(kind: kind, words: words,
                    at: PixelPoint(x: position[0], y: position[1]), width: paperWidth, size: size)))
            }
        }
        for name in ["measureText", "measureHandwriting"] {
            define(name, in: context) { arguments in
                guard let words = arguments.first, words.isString else { return Self.fail("\(name) needs words.") }
                guard let size = Self.size(arguments.dropFirst().first) else { return Self.fail("\(name)'s size must be a positive number.") }
                let line = DrawText.line(Self.collapsed(words.toString()), size: size, handwriting: name == "measureHandwriting")
                return ["width": line.width, "height": line.ascent + line.descent]
            }
        }
        define("measurePath", in: context) { arguments in
            guard case .points(let points) = Self.points(arguments.first), !points.isEmpty else {
                return Self.fail("measurePath needs points, each [x, y].")
            }
            let length = zip(points, points.dropFirst()).reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            let xs = points.map(\.x), ys = points.map(\.y)
            return ["length": length, "left": xs.min()!, "top": ys.min()!, "right": xs.max()!, "bottom": ys.max()!]
        }
    }

    private func define(_ name: String, in context: JSContext, _ body: @escaping ([JSValue]) -> Any?) {
        let function: @convention(block) () -> Any? = { body(JSContext.currentArguments() as? [JSValue] ?? []) }
        context.setObject(function, forKeyedSubscript: name as NSString)
    }

    /// Throws `message` in the program as an Error.
    fileprivate static func fail(_ message: String) -> Any? {
        let context = JSContext.current()!
        context.exception = JSValue(newErrorFromMessage: message, in: context)
        return nil
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func number(_ value: JSValue) -> Double? {
        guard value.isNumber else { return nil }
        let number = value.toDouble()
        return number.isFinite ? number : nil
    }

    /// A missing size is the default one.
    private static func size(_ value: JSValue?) -> Double? {
        guard let value, !value.isUndefined else { return defaultTextSize }
        return number(value).flatMap { $0 > 0 ? $0 : nil }
    }

    private enum Points {
        case points([PixelPoint]), tooMany, invalid
    }

    private static func points(_ value: JSValue?) -> Points {
        guard let value, value.isArray else { return .invalid }
        let count = Int(value.forProperty("length").toInt32())
        guard count <= strokePointLimit else { return .tooMany }
        var points: [PixelPoint] = []
        for index in 0..<count {
            let pair = value.atIndex(index)!
            guard pair.isArray, pair.forProperty("length").toInt32() == 2,
                  let x = number(pair.atIndex(0)), let y = number(pair.atIndex(1)) else { return .invalid }
            points.append(PixelPoint(x: x, y: y))
        }
        return .points(points)
    }
}

private final class Watchdog {
    var fired = false
}

private final class Recording {
    var beats: [Beat] = []
    private var marks = 0

    func add(_ mark: DrawMark<PixelPoint>) -> Any? {
        guard !beats.isEmpty else { return DrawSandbox.fail("Call beat(line) before drawing.") }
        guard marks < DrawSandbox.markLimit else {
            return DrawSandbox.fail("A draw program can have at most \(DrawSandbox.markLimit) marks.")
        }
        marks += 1
        beats[beats.count - 1].drawMarks.append(mark)
        return nil
    }
}
