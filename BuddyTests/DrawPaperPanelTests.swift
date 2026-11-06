import AppKit
import BuddyCore
import CoreText
import QuartzCore
import Testing
@testable import Buddy

@MainActor
struct DrawPaperPanelTests {
    @Test func bundledHandwritingUsesPatrickHand() {
        #expect(CTFontCopyPostScriptName(DrawText.font(size: 36, handwriting: true)) as String == "PatrickHand-Regular")
        #expect(DrawText.path("Three quarters", size: 36, handwriting: true).isEmpty == false)
    }

    @Test(arguments: [true, false])
    func mixedMarksAndPaperUseTheSharedHostClock(animated: Bool) throws {
        let view = DrawMarksView(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 1)
        let paper = DrawPaper(id: 1, kind: DrawPaperKind.card, words: "A note.",
                              at: DisplayPoint(x: 112.5, y: 675), width: 450, size: 36)
        let panel = DrawPaperPanel(PlacedPaper(paper: paper, display: DisplayRect(x: 0, y: 0, width: 1440, height: 900))) { _ in }
        defer { panel.close() }
        let start = CACurrentMediaTime() + 1
        var paperTimes: [Double] = []
        view.add([
            .handwriting("i", at: DisplayPoint(x: 112.5, y: 810), size: 45), .paper(paper),
            .stroke([DisplayPoint(x: 0, y: 900), DisplayPoint(x: 450, y: 900)])
        ], animated: animated, startingAt: start) { _, begin, duration in
            paperTimes = [begin - start, duration]
            panel.reveal(from: begin, duration: duration)
        }
        let root = try #require(view.layer)
        let layers = try #require(root.sublayers)
        #expect(layers.count == 2)
        if animated {
            let handwriting = try #require(layers[0].mask?.animation(forKey: "write"))
            let stroke = try #require(layers[1].animation(forKey: "draw"))
            #expect(handwriting.beginTime == start)
            #expect(handwriting.duration == 0.25)
            #expect(paperTimes == [0.25, 0.9])
            #expect(panel.contentView?.layer?.animation(forKey: "paper")?.beginTime == start + 0.25)
            #expect(stroke.beginTime == start + 1.15)
            #expect(stroke.duration == 0.5)
        } else {
            #expect(layers[0].mask == nil)
            #expect(layers[1].animation(forKey: "draw") == nil)
            #expect(paperTimes == [0, 0])
            #expect(panel.contentView?.layer?.animation(forKey: "paper") == nil)
        }
        view.clear()
        #expect((root.sublayers ?? []).isEmpty)
        #expect(layers.allSatisfy { $0.superlayer == nil })
    }

    @Test func papersStayInsideTheirCapturedDisplayEvenWhenTextCoordinatesAreOutsideIt() {
        let paper = PlacedPaper(paper: DrawPaper(id: 1, kind: .card, words: "Keep the note on its canvas.",
                                                 at: DisplayPoint(x: 200, y: 900), width: 360, size: 32),
                                display: DisplayRect(x: -1_000_000, y: 0, width: 1440, height: 900))
        let panel = DrawPaperPanel(paper) { _ in }
        defer { panel.close() }
        #expect(panel.frame.minX >= -999_988)
        #expect(panel.frame.maxX <= -998_572)
        #expect(panel.frame.maxY <= 888)
        #expect(panel.frame.minY >= 12)
    }

    @Test func legacyScrollbarsLeaveTheEndOfWrappedPaperReachable() throws {
        let text = "Three quarters means three of four equal parts. The bottom number counts all the parts. The top number counts the parts we have."
        let paper = PlacedPaper(paper: DrawPaper(id: 1, kind: .card, words: text,
                                                 at: DisplayPoint(x: -999_900, y: 350), width: 240, size: 40),
                                display: DisplayRect(x: -1_000_000, y: 0, width: 1440, height: 400))
        let panel = DrawPaperPanel(paper, scrollerStyle: .legacy) { _ in }
        defer { panel.close() }
        let scroll = try #require(panel.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let label = try #require(scroll.documentView as? NSTextField)
        let cell = try #require(label.cell)
        let needed = cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude))
        #expect(label.bounds.width <= scroll.contentSize.width)
        #expect(label.bounds.height >= needed.height)
        #expect(label.bounds.height > scroll.contentSize.height)
        label.scrollToVisible(CGRect(x: 0, y: label.bounds.maxY - 1, width: 1, height: 1))
        #expect(scroll.contentView.bounds.maxY >= label.bounds.maxY - 1)
    }

    @Test(arguments: [DrawPaperKind.card, .sticky])
    func nativeControlsSendOwnerEventsAndDraggedPaperKeepsItsContent(kind: DrawPaperKind) throws {
        let paper = PlacedPaper(paper: DrawPaper(id: 7, kind: kind, words: "Three quarters means three of four equal parts.",
                                                 at: DisplayPoint(x: 120, y: 650), width: 460, size: 36),
                                display: DisplayRect(x: 0, y: 0, width: 1440, height: 900))
        var events: [String] = []
        let panel = DrawPaperPanel(paper) { event in
            switch event {
            case .paperPinToggled(let id): events.append("pin \(id)")
            case .paperClosed(let id): events.append("close \(id)")
            case .paperMoved(let id, _): events.append("move \(id)")
            default: Issue.record("Unexpected paper event")
            }
        }
        defer { panel.close() }
        let view = try #require(panel.contentView)
        let buttons = descendants(of: view).compactMap { $0 as? NSButton }
        let pin = try #require(buttons.first { $0.toolTip?.hasPrefix("Pin note") == true })
        let close = try #require(buttons.first { $0.toolTip == "Close note" })
        pin.performClick(nil)
        close.performClick(nil)
        #expect(events == ["pin 7", "close 7"])
        let header = try #require(view.subviews.first { $0.frame.height == 38 })
        let start = panel.frame
        header.mouseDown(with: try mouse(.leftMouseDown, in: panel, at: CGPoint(x: 30, y: start.height - 20)))
        header.mouseDragged(with: try mouse(.leftMouseDragged, in: panel, at: CGPoint(x: 90, y: start.height - 50)))
        header.mouseUp(with: try mouse(.leftMouseUp, in: panel, at: CGPoint(x: 30, y: start.height - 20)))
        #expect(panel.frame.origin == CGPoint(x: start.minX + 60, y: start.minY - 30))
        #expect(events == ["pin 7", "close 7", "move 7"])
        let words = try #require(descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue == paper.paper.words })
        #expect(words.font?.fontName == "PatrickHand-Regular")
        #expect(panel.canBecomeKey == false)
        #expect(panel.ignoresMouseEvents == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_DRAW_EVIDENCE"] != nil))
    func renderHandwrittenExplanation() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["BUDDY_DRAW_EVIDENCE"])
        let paper = PlacedPaper(paper: DrawPaper(id: 1, kind: .card,
            words: "3 / 4 means three of four equal parts. The bottom number counts all the parts. The top number counts the parts we have.",
            at: DisplayPoint(x: 160, y: 700), width: 520, size: 36),
            display: DisplayRect(x: 0, y: 0, width: 1440, height: 900))
        let panel = DrawPaperPanel(paper) { _ in }
        defer { panel.close() }
        panel.reveal(from: CACurrentMediaTime(), duration: 1.04)
        try await Task.sleep(for: .milliseconds(1600))
        let view = try #require(panel.contentView)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("handwritten-card.png"))
        #expect(panel.isVisible)
    }

    @Test func engineAndOverlayKeepPinnedPaperAndCloseOnlyTheRequestedNote() throws {
        let screen = try #require(NSScreen.main)
        let frame = screen.frame
        let display = DisplayRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        let capture = ScreenCapture(jpeg: Data([1]), display: display, pixelWidth: Int(frame.width),
                                    pixelHeight: Int(frame.height), containsCursor: true)
        var engine = BuddyEngine(providerConnected: true)
        let overlay = OverlayWindowManager()
        func send(_ event: BuddyEngine.Event) {
            for effect in engine.handle(event) {
                switch effect {
                case .draw(let marks, let display): overlay.draw(marks, on: display)
                case .updatePaper(let paper): overlay.updatePaper(paper)
                case .removePaper(let id): overlay.removePaper(id)
                case .clearAnnotations: overlay.clearAnnotations()
                default: break
                }
            }
        }
        overlay.onPaperEvent = { send($0) }
        defer {
            send(.interrupted)
            overlay.onPaperEvent = nil
        }
        for event in [BuddyEngine.Event.pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("draw it"),
                      .screensCaptured([capture])] { send(event) }
        let previousWindows = Set(NSApp.windows.map(\.windowNumber))
        send(.provider(.textDelta("""
        ```draw
        beat("Look."); card("Keep this explanation.", 100, 200, 300); sticky("Close this reminder.", 450, 200);
        ```

        """)))
        send(.provider(.completed))
        send(.lineStarted)
        send(.lineFinished)
        let panels = NSApp.windows.filter { !previousWindows.contains($0.windowNumber) }.compactMap { $0 as? DrawPaperPanel }
        let card = try #require(panels.first { panel in
            descendants(of: panel.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Keep this explanation." }
        })
        let sticky = try #require(panels.first { $0 !== card })
        let pin = try #require(descendants(of: card.contentView!).compactMap { $0 as? NSButton }.first { $0.toolTip?.hasPrefix("Pin note") == true })
        pin.performClick(nil)
        #expect(engine.state.papers.first?.pinned == true)
        let closeSticky = try #require(descendants(of: sticky.contentView!).compactMap { $0 as? NSButton }.first { $0.toolTip == "Close note" })
        closeSticky.performClick(nil)
        #expect(sticky.isVisible == false)
        #expect(card.isVisible)
        send(.pushToTalkPressed)
        #expect(card.isVisible)
        #expect(engine.state.papers.count == 1)
        pin.performClick(nil)
        #expect(engine.state.papers.first?.pinned == false)
        let closeCard = try #require(descendants(of: card.contentView!).compactMap { $0 as? NSButton }.first { $0.toolTip == "Close note" })
        closeCard.performClick(nil)
        #expect(card.isVisible == false)
        #expect(engine.state.papers == [])
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mouse(_ type: NSEvent.EventType, in panel: NSPanel, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
