import AppKit
import BuddyCore
import Combine
import CoreText
import QuartzCore
import Observation
import SwiftUI

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    let drawMarks: DrawMarksView

    init(screen: NSScreen, presence: BuddyPresence) {
        drawMarks = DrawMarksView(screenFrame: screen.frame, scale: screen.backingScaleFactor)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        let swiftUI = NSHostingView(rootView: OverlayView(screenFrame: screen.frame, presence: presence))
        swiftUI.frame = content.bounds
        swiftUI.autoresizingMask = [.width, .height]
        // Draw program marks sit beneath the SwiftUI annotations and the buddy.
        content.addSubview(drawMarks)
        content.addSubview(swiftUI)
        contentView = content
    }
}

struct PlacedDrawMark {
    let mark: DrawMark<DisplayPoint>
    let display: CGRect
}

/// Redraws a draw program's marks with Core Animation in the buddy's accent ink. A line's marks draw on one after
/// another at a steady pen speed, starting as the line starts.
final class DrawMarksView: NSView {
    private let screenFrame: CGRect
    private let scale: CGFloat
    private let ink = NSColor(DS.Colors.accent).cgColor

    init(screenFrame: CGRect, scale: CGFloat) {
        self.screenFrame = screenFrame
        self.scale = scale
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        let root = CALayer()
        root.contentsScale = scale
        root.shadowColor = ink
        root.shadowOpacity = 0.4
        root.shadowRadius = 7
        root.shadowOffset = .zero
        layer = root
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Adds one line's marks. Animated, each draws on after the one before it, from now.
    func add(_ marks: [DrawMark<DisplayPoint>], animated: Bool, startingAt: CFTimeInterval = CACurrentMediaTime(),
             paper: ((DrawPaper<DisplayPoint>, CFTimeInterval, Double) -> Void)? = nil) {
        // Explicit animations only: a mark appears at once unless it draws on.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var pen = startingAt
        for mark in marks {
            if case .paper(let content) = mark {
                let duration = animated ? mark.revealDuration : 0
                paper?(content, pen, duration)
                pen += duration
                continue
            }
            pen = add(mark, animated: animated, from: pen)
        }
    }

    /// Returns when the pen is free again.
    private func add(_ mark: DrawMark<DisplayPoint>, animated: Bool, from begin: CFTimeInterval) -> CFTimeInterval {
        let (path, isText) = outline(of: mark)
        let shape = CAShapeLayer()
        shape.contentsScale = scale
        shape.frame = bounds
        shape.path = path
        if isText {
            shape.fillColor = ink
        } else {
            shape.fillColor = nil
            shape.strokeColor = ink
            shape.lineWidth = 4
            shape.lineCap = .round
            shape.lineJoin = .round
        }
        layer?.addSublayer(shape)
        guard animated else { return begin }
        let duration = mark.revealDuration
        if isText {
            wipe(shape, from: begin, for: duration)
            return begin + duration
        }
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.beginTime = begin
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 0, 0.2, 1)
        shape.add(animation, forKey: "draw")
        return begin + duration
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
    }

    /// Reveals text from left to right, as if written.
    private func wipe(_ shape: CAShapeLayer, from begin: CFTimeInterval, for duration: Double) {
        guard let box = shape.path?.boundingBoxOfPath.insetBy(dx: -4, dy: -4), !box.isNull else { return }
        let mask = CALayer()
        mask.backgroundColor = .black
        mask.anchorPoint = CGPoint(x: 0, y: 0.5)
        mask.bounds = CGRect(origin: .zero, size: box.size)
        mask.position = CGPoint(x: box.minX, y: box.midY)
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = 0
        animation.toValue = box.width
        animation.duration = duration
        animation.beginTime = begin
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mask.add(animation, forKey: "write")
        shape.mask = mask
    }

    /// The layer is not flipped, so it shares the display's upward y.
    private func viewPoint(_ point: DisplayPoint) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY)
    }

    /// The mark's path and whether it is text, which is filled, not stroked.
    private func outline(of mark: DrawMark<DisplayPoint>) -> (CGPath, Bool) {
        let path = CGMutablePath()
        switch mark {
        case .stroke(let points):
            let spots = points.map(viewPoint)
            guard let first = spots.first, let last = spots.last else { return (path, false) }
            path.move(to: first)
            // Curves through the midpoints between spots, so a few points make a smooth freehand line.
            for (spot, next) in zip(spots.dropFirst(), spots.dropFirst(2)) {
                path.addQuadCurve(to: CGPoint(x: (spot.x + next.x) / 2, y: (spot.y + next.y) / 2), control: spot)
            }
            path.addLine(to: last)
            return (path, false)
        case .arrow(let from, let to):
            let tail = viewPoint(from)
            let tip = viewPoint(to)
            let heading = atan2(tip.y - tail.y, tip.x - tail.x)
            let spread = 28 * Double.pi / 180
            func barb(_ side: Double) -> CGPoint {
                CGPoint(x: tip.x - 14 * cos(heading + side), y: tip.y - 14 * sin(heading + side))
            }
            path.move(to: tail)
            path.addLine(to: tip)
            path.move(to: barb(spread))
            path.addLine(to: tip)
            path.addLine(to: barb(-spread))
            return (path, false)
        case .ring(let from, let to):
            let start = viewPoint(from)
            let end = viewPoint(to)
            let grown = CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)
                .standardized.insetBy(dx: -8, dy: -8)
            let box = grown.insetBy(dx: min(0, (grown.width - 28) / 2), dy: min(0, (grown.height - 28) / 2))
            path.addEllipse(in: box)
            return (path, false)
        case .text(let words, let top, let size):
            let glyphs = DrawText.path(words, size: size, top: viewPoint(top))
            return (glyphs, true)
        case .handwriting(let words, let top, let size):
            let glyphs = DrawText.path(words, size: size, top: viewPoint(top), handwriting: true)
            return (glyphs, true)
        case .paper:
            return (path, false)
        }
    }


}

struct Pointing: Equatable {
    let target: CGPoint
    let display: CGRect
}

struct PlacedAnnotation: Identifiable {
    let id = UUID()
    let annotation: Annotation<DisplayPoint>
    let display: CGRect
}

/// What every overlay window shows. Without a point, a shown buddy is at the cursor. A point's label sits beside the
/// buddy while it points. Annotations stay up while it is hidden. The turn's text is in the notch. During a screen
/// takeover the buddy stays shown and says how to take back control.
@Observable
final class BuddyPresence {
    var buddyShown = false
    var pointing: Pointing?
    var label: String?
    var takingOver = false
    var annotations: [PlacedAnnotation] = []

    static let takingOverText = "Using your mouse and keyboard. Press Esc to take back control."

    /// What sits beside the buddy. During a takeover the way to take back control wins over a point's label.
    enum Beside: Equatable {
        case label(String)
        case takingOver
    }

    var beside: Beside? {
        if takingOver { return .takingOver }
        return label.map(Beside.label)
    }
}

private extension CGRect {
    init(_ display: DisplayRect) {
        self.init(x: display.x, y: display.y, width: display.width, height: display.height)
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// The buddy view is inserted each time it is shown, so it starts with the same flight a new window gives it.
private struct OverlayView: View {
    let screenFrame: CGRect
    let presence: BuddyPresence

    var body: some View {
        ZStack(alignment: .topLeading) {
            AnnotationLayer(screenFrame: screenFrame, presence: presence)
            if presence.buddyShown {
                BuddyCursorView(screenFrame: screenFrame, presence: presence)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .accessibilityHidden(true)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct BuddyCursorView: View {
    static let flightSeconds = 0.6

    let screenFrame: CGRect
    let presence: BuddyPresence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = CGPoint.zero
    @State private var rotation = 35.0
    @State private var scale = 1.0
    @State private var flightStart = CGPoint.zero
    @State private var flightBegan: Date?
    @State private var besideSize = CGSize(width: 80, height: 26)
    private let frames = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isVisible {
                Triangle()
                    .fill(DS.Colors.accent)
                    .frame(width: PointerPose.size.width, height: PointerPose.size.height)
                    .rotationEffect(.degrees(rotation))
                    .scaleEffect(scale)
                    .shadow(color: DS.Colors.accent.opacity(0.4), radius: 7)
                    .position(position)
                switch presence.beside {
                case .takingOver: besideBuddy(takeoverHint)
                case .label(let label): besideBuddy(pill(label))
                case nil: EmptyView()
                }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .onAppear {
            let target = destination
            fly(from: presence.pointing == nil
                ? CGPoint(x: max(20, target.x - 70), y: max(20, target.y - 40))
                : clamped(cursorPoint))
        }
        .onChange(of: presence.pointing) { previous, _ in
            fly(from: isVisible(pointing: previous) ? position : clamped(cursorPoint))
        }
        .onReceive(frames) { date in advance(to: date) }
    }

    private var isVisible: Bool { isVisible(pointing: presence.pointing) }

    private func isVisible(pointing: Pointing?) -> Bool {
        guard let pointing else { return screenFrame.contains(NSEvent.mouseLocation) }
        return screenFrame.contains(pointing.display.center)
    }

    private func fly(from start: CGPoint) {
        flightStart = reduceMotion ? destination : start
        position = flightStart
        flightBegan = reduceMotion ? nil : Date()
        if reduceMotion { rotation = pointingPose?.rotation ?? 35 }
    }

    private var destination: CGPoint {
        pointingPose?.position ?? cursorPoint
    }

    private var pointingPose: PointerPose? {
        presence.pointing.map { PointerPose(pointingAt: $0.target, in: screenFrame) }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: max(20, min(point.x, screenFrame.width - 20)), y: max(20, min(point.y, screenFrame.height - 20)))
    }

    private var cursorPoint: CGPoint {
        let mouse = NSEvent.mouseLocation
        return clamped(CGPoint(x: mouse.x - screenFrame.minX + 22, y: screenFrame.maxY - mouse.y + 24))
    }

    /// The label of the point, in the same pill as a LABEL annotation.
    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(DS.Colors.accent, in: Capsule())
            .shadow(color: DS.Colors.accent.opacity(0.4), radius: 7)
    }

    private var takeoverHint: some View {
        Text(BuddyPresence.takingOverText)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(3)
            .frame(width: 256, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Beside the buddy, on its right unless that would leave the display, and kept on screen.
    private func besideBuddy(_ content: some View) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { besideSize = $0 }
            .offset(x: besideOrigin.x, y: besideOrigin.y)
    }

    private var besideOrigin: CGPoint {
        let right = position.x + 20
        let left = position.x - besideSize.width - 20
        let x = right + besideSize.width <= screenFrame.width - 10 ? right
            : (left >= 10 ? left : max(10, screenFrame.width - besideSize.width - 10))
        let y = min(max(8, position.y - besideSize.height / 2), screenFrame.height - besideSize.height - 8)
        return CGPoint(x: x, y: y)
    }

    private func advance(to date: Date) {
        let target = destination
        guard let began = flightBegan, !reduceMotion else {
            position = target
            rotation = pointingPose?.rotation ?? 35
            scale = 1
            return
        }
        let progress = min(date.timeIntervalSince(began) / Self.flightSeconds, 1)
        let t = progress * progress * (3 - 2 * progress)
        let control = CGPoint(x: (flightStart.x + target.x) / 2, y: min(flightStart.y, target.y) - 35)
        let remaining = 1 - t
        position = CGPoint(
            x: remaining * remaining * flightStart.x + 2 * remaining * t * control.x + t * t * target.x,
            y: remaining * remaining * flightStart.y + 2 * remaining * t * control.y + t * t * target.y
        )
        let tangentX = 2 * remaining * (control.x - flightStart.x) + 2 * t * (target.x - control.x)
        let tangentY = 2 * remaining * (control.y - flightStart.y) + 2 * t * (target.y - control.y)
        rotation = atan2(tangentY, tangentX) * (180 / .pi) + 90
        scale = 1 + sin(progress * .pi) * 0.3
        if progress == 1 { flightBegan = nil }
    }
}

private struct AnnotationLayer: View {
    let screenFrame: CGRect
    let presence: BuddyPresence

    var body: some View {
        ZStack {
            ForEach(presence.annotations.filter { screenFrame.contains($0.display.center) }) { placed in
                AnnotationMark(annotation: placed.annotation, screenFrame: screenFrame)
            }
        }
    }
}

private struct AnnotationMark: View {
    let annotation: Annotation<DisplayPoint>
    let screenFrame: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        // A full-screen frame keeps a label near an edge from growing the layer and shifting the other marks.
        mark
            .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
            .shadow(color: DS.Colors.accent.opacity(0.4), radius: 7)
            .onAppear {
                withAnimation(reduceMotion ? nil : drawOn) { drawn = true }
            }
    }

    private var drawOn: Animation {
        switch annotation {
        case .label: .easeOut(duration: 0.2)
        case .shape(.highlight, _, _): .easeOut(duration: 0.3)
        case .shape: .easeOut(duration: 0.35)
        }
    }

    @ViewBuilder private var mark: some View {
        switch annotation {
        case .label(let text, let spot):
            pill(text, at: viewPoint(spot))
        case .shape(let shape, let from, let to):
            let start = viewPoint(from)
            let end = viewPoint(to)
            let box = CGRect(origin: start, size: CGSize(width: end.x - start.x, height: end.y - start.y)).standardized
            switch shape {
            case .arrow: stroke(arrow(from: start, to: end))
            case .line: stroke(segment(from: start, to: end))
            case .ring: stroke(Path(ellipseIn: ring(around: box)))
            case .underline:
                stroke(segment(from: CGPoint(x: box.minX, y: box.maxY + 3), to: CGPoint(x: box.maxX, y: box.maxY + 3)))
            case .highlight: highlight(box.insetBy(dx: -3, dy: -3))
            }
        }
    }

    private func viewPoint(_ point: DisplayPoint) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y)
    }

    private func stroke(_ path: Path) -> some View {
        path
            .trim(from: 0, to: drawn ? 1 : 0)
            .stroke(DS.Colors.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
    }

    private func segment(from start: CGPoint, to end: CGPoint) -> Path {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
    }

    private func arrow(from tail: CGPoint, to tip: CGPoint) -> Path {
        let heading = atan2(tip.y - tail.y, tip.x - tail.x)
        let spread = 28 * Double.pi / 180
        func barb(_ side: Double) -> CGPoint {
            CGPoint(x: tip.x - 14 * cos(heading + side), y: tip.y - 14 * sin(heading + side))
        }
        return Path { path in
            path.move(to: tail)
            path.addLine(to: tip)
            path.move(to: barb(spread))
            path.addLine(to: tip)
            path.addLine(to: barb(-spread))
        }
    }

    private func ring(around box: CGRect) -> CGRect {
        let grown = box.insetBy(dx: -8, dy: -8)
        return grown.insetBy(dx: min(0, (grown.width - 28) / 2), dy: min(0, (grown.height - 28) / 2))
    }

    private func highlight(_ box: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(DS.Colors.accent.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DS.Colors.accent.opacity(0.6), lineWidth: 1.5))
            .frame(width: box.width, height: box.height)
            .mask(alignment: .leading) { Rectangle().frame(width: drawn ? box.width : 0) }
            .position(x: box.midX, y: box.midY)
    }

    /// Alignment guides place the pill, because only they see its measured size: just right of the spot, or just left
    /// of it when it would cross the display's right edge.
    private func pill(_ text: String, at spot: CGPoint) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(DS.Colors.accent, in: Capsule())
            .scaleEffect(drawn ? 1 : 0.85)
            .opacity(drawn ? 1 : 0)
            .alignmentGuide(.leading) { size in
                spot.x + 10 + size.width > screenFrame.width ? size.width + 10 - spot.x : -10 - spot.x
            }
            .alignmentGuide(.top) { size in
                -min(max(spot.y - size.height / 2, 8), screenFrame.height - 8 - size.height)
            }
    }
}

/// Keeps the same windows up while the buddy is shown or any annotation is up, so the buddy flies from where it is:
/// from one point to the next, and back to the cursor when a point ends.
@MainActor
final class OverlayWindowManager: Overlay {
    private let presence = BuddyPresence()
    private var windows: [OverlayWindow] = []
    private var drawMarks: [PlacedDrawMark] = []
    private var papers: [Int: DrawPaperPanel] = [:]
    var onPaperEvent: ((BuddyEngine.Event) -> Void)?
    private var hiding: Task<Void, Never>?
    /// The buddy was shown for a turn or a run's lines, so it stays when a takeover ends.
    private var shownForTalk = false

    func showBuddy() {
        shownForTalk = true
        present(pointing: nil, label: nil)
    }

    func takeover(_ active: Bool) {
        presence.takingOver = active
        if active {
            guard !presence.buddyShown || hiding != nil else { return }
            present(pointing: nil, label: nil)
        } else if !shownForTalk {
            hideBuddy()
        }
    }

    func point(at point: DisplayPoint, on display: DisplayRect, label: String?) {
        shownForTalk = true
        present(pointing: Pointing(target: CGPoint(x: point.x, y: point.y), display: CGRect(display)), label: label)
    }

    func annotate(_ annotation: Annotation<DisplayPoint>, on display: DisplayRect) {
        presence.annotations.append(PlacedAnnotation(annotation: annotation, display: CGRect(display)))
        openWindows()
    }

    func draw(_ marks: [DrawMark<DisplayPoint>], on display: DisplayRect) {
        draw(marks, on: display, startingAt: CACurrentMediaTime())
    }

    func draw(_ marks: [DrawMark<DisplayPoint>], on display: DisplayRect, startingAt time: CFTimeInterval) {
        openWindows()
        let frame = CGRect(display)
        drawMarks += marks.compactMap {
            if case .paper = $0 { return nil }
            return PlacedDrawMark(mark: $0, display: frame)
        }
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for window in windows where window.frame.contains(frame.center) {
            window.drawMarks.add(marks, animated: animated, startingAt: time) { [weak self] content, begin, duration in
                guard let self else { return }
                let panel = DrawPaperPanel(PlacedPaper(paper: content, display: display)) { [weak self] in
                    self?.onPaperEvent?($0)
                }
                papers[content.id] = panel
                panel.reveal(from: begin, duration: duration)
            }
        }
    }

    func updatePaper(_ paper: PlacedPaper) {
        papers[paper.paper.id]?.update(paper)
    }

    func removePaper(_ id: Int) {
        papers.removeValue(forKey: id)?.close()
    }

    func clearAnnotations() {
        presence.annotations.removeAll()
        drawMarks.removeAll()
        for window in windows { window.drawMarks.clear() }
        closeUnusedWindows()
    }

    /// A buddy that is pointing flies back to the cursor before it goes.
    func hideBuddy() {
        let returning = presence.pointing != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        shownForTalk = false
        presence.pointing = nil
        presence.label = nil
        hiding?.cancel()
        hiding = nil
        // During a takeover the buddy stays at the cursor, so a pointing one flies back and stays.
        guard !presence.takingOver else { return }
        guard returning else { return finishHiding() }
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(BuddyCursorView.flightSeconds))
            guard !Task.isCancelled else { return }
            self?.finishHiding()
        }
    }

    private func finishHiding() {
        hiding = nil
        presence.buddyShown = false
        closeUnusedWindows()
    }

    private func closeUnusedWindows() {
        guard !presence.buddyShown, presence.annotations.isEmpty, drawMarks.isEmpty else { return }
        closeWindows()
    }

    private func closeWindows() {
        for window in windows { window.close() }
        windows.removeAll()
    }

    private func present(pointing: Pointing?, label: String?) {
        hiding?.cancel()
        hiding = nil
        presence.pointing = pointing
        presence.label = label
        presence.buddyShown = true
        openWindows()
    }

    private func openWindows() {
        let screens = NSScreen.screens
        guard windows.map(\.frame) != screens.map(\.frame) else { return }
        closeWindows()
        windows = screens.map { OverlayWindow(screen: $0, presence: presence) }
        // New windows redraw the marks so far at once.
        for window in windows {
            window.drawMarks.add(drawMarks.filter { window.frame.contains($0.display.center) }.map(\.mark), animated: false)
            window.orderFrontRegardless()
        }
    }
}
