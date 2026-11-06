import AppKit
import BuddyCore
import CoreText
import QuartzCore

/// A paper alone takes clicks. The drawing windows around it remain click-through.
final class DrawPaperPanel: NSPanel {
    private var placed: PlacedPaper
    private let send: (BuddyEngine.Event) -> Void
    private let pin = NSButton()
    private let words: NSTextField

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(_ placed: PlacedPaper, scrollerStyle: NSScroller.Style = NSScroller.preferredScrollerStyle,
         send: @escaping (BuddyEngine.Event) -> Void) {
        self.placed = placed
        self.send = send
        let paper = placed.paper
        let center = CGPoint(x: placed.display.x + placed.display.width / 2, y: placed.display.y + placed.display.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
        let visible = screen?.visibleFrame ?? CGRect(x: placed.display.x, y: placed.display.y,
                                                    width: placed.display.width, height: placed.display.height)
        let width = min(max(paper.width, 160), visible.width - 24)
        let scroll = NSScrollView(frame: CGRect(x: 20, y: 20, width: width - 40, height: 1))
        scroll.drawsBackground = false
        scroll.scrollerStyle = scrollerStyle
        scroll.hasVerticalScroller = true
        scroll.tile()
        let bodyWidth = scroll.contentSize.width
        let font = DrawText.font(size: paper.size, handwriting: true)
        let bodyFont = NSFont(name: CTFontCopyPostScriptName(font) as String, size: paper.size)!
        let label = NSTextField(wrappingLabelWithString: paper.words)
        label.font = bodyFont
        let bodyHeight = ceil(label.cell!.cellSize(forBounds: CGRect(x: 0, y: 0, width: bodyWidth,
                                                                    height: .greatestFiniteMagnitude)).height) + 8
        let height = min(max(bodyHeight + 76, 150), visible.height - 24)
        let origin = CGPoint(x: min(max(paper.at.x, visible.minX + 12), visible.maxX - width - 12),
                             y: min(max(paper.at.y - height, visible.minY + 12), visible.maxY - height - 12))
        words = label
        super.init(contentRect: CGRect(origin: origin, size: CGSize(width: width, height: height)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        appearance = NSAppearance(named: .aqua)
        setAccessibilityLabel(paper.kind == .sticky ? "Buddy sticky note" : "Buddy paper card")

        let page = NSView(frame: CGRect(origin: .zero, size: frame.size))
        page.wantsLayer = true
        page.layer?.backgroundColor = (paper.kind == .sticky
            ? NSColor(calibratedRed: 1, green: 0.94, blue: 0.65, alpha: 1)
            : NSColor(calibratedRed: 1, green: 0.985, blue: 0.95, alpha: 1)).cgColor
        page.layer?.cornerRadius = paper.kind == .sticky ? 3 : 14
        page.layer?.borderWidth = 1
        page.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        contentView = page

        let header = PaperDragHandle(frame: CGRect(x: 0, y: height - 38, width: width, height: 38))
        header.onMoved = { [weak self] in
            guard let self else { return }
            send(.paperMoved(paper.id, to: DisplayPoint(x: frame.minX, y: frame.maxY)))
        }
        page.addSubview(header)
        let title = NSTextField(labelWithString: paper.kind == .sticky ? "STICKY NOTE" : "BUDDY'S NOTEBOOK")
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.25, alpha: 0.7)
        title.frame = CGRect(x: 20, y: 10, width: width - 112, height: 14)
        header.addSubview(title)
        pin.frame = CGRect(x: width - 76, y: 5, width: 30, height: 28)
        pin.bezelStyle = .inline
        pin.contentTintColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        pin.target = self
        pin.action = #selector(togglePin)
        header.addSubview(pin)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close note")!,
                             target: self, action: #selector(closeNote))
        close.bezelStyle = .inline
        close.contentTintColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        close.frame = CGRect(x: width - 42, y: 5, width: 28, height: 28)
        close.toolTip = "Close note"
        header.addSubview(close)

        scroll.setFrameSize(CGSize(width: width - 40, height: height - 68))
        scroll.autohidesScrollers = true
        words.textColor = NSColor(calibratedRed: 0.20, green: 0.18, blue: 0.15, alpha: 1)
        words.frame = CGRect(x: 0, y: 0, width: bodyWidth, height: max(bodyHeight, scroll.contentSize.height))
        words.setAccessibilityLabel(paper.words)
        scroll.documentView = words
        page.addSubview(scroll)
        update(placed, moving: false)
    }

    func update(_ placed: PlacedPaper, moving: Bool = true) {
        let moved = self.placed.paper.at != placed.paper.at
        self.placed = placed
        pin.image = NSImage(systemSymbolName: placed.pinned ? "pin.fill" : "pin", accessibilityDescription: placed.pinned ? "Unpin note" : "Pin note")
        pin.toolTip = placed.pinned ? "Unpin note. Clears on the next turn." : "Pin note. Keeps it on the next turn."
        pin.setAccessibilityLabel(placed.pinned ? "Unpin note" : "Pin note")
        if moving && moved { setFrameOrigin(CGPoint(x: placed.paper.at.x, y: placed.paper.at.y - frame.height)) }
    }

    func reveal(from begin: CFTimeInterval, duration: Double) {
        orderFrontRegardless()
        guard duration > 0 else { return }
        contentView?.wantsLayer = true
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.12
        appear.beginTime = begin
        appear.fillMode = .backwards
        contentView?.layer?.add(appear, forKey: "paper")
        words.wantsLayer = true
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.anchorPoint = .zero
        mask.frame = words.bounds
        let write = CABasicAnimation(keyPath: "bounds.size.width")
        write.fromValue = 0
        write.toValue = words.bounds.width
        write.duration = duration
        write.beginTime = begin
        write.fillMode = .backwards
        mask.add(write, forKey: "write")
        words.layer?.mask = mask
    }

    @objc private func togglePin() { send(.paperPinToggled(placed.paper.id)) }
    @objc private func closeNote() { send(.paperClosed(placed.paper.id)) }
}

private final class PaperDragHandle: NSView {
    var onMoved: (() -> Void)?
    private var offset: CGPoint?

    override func mouseDown(with event: NSEvent) {
        offset = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let offset, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(CGPoint(x: point.x - offset.x, y: point.y - offset.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard offset != nil else { return }
        offset = nil
        onMoved?()
    }
}
