import AppKit
import BuddyCore
import Observation
import SwiftUI

/// Takes the keyboard only for explicit text input, without activating Buddy over the owner's app.
private final class NotchWindow: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Where the notch sits on a screen. On a screen with a camera housing the notch wraps around it. Elsewhere a stand-in
/// of the same shape hangs from the menu bar.
struct NotchGeometry: Equatable {
    /// The camera housing, or its stand-in.
    let core: CGSize

    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            core = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            core = CGSize(width: 180, height: menuBar > 0 ? menuBar : NSStatusBar.system.thickness)
        }
    }
}

/// The text in the strip below the notch.
enum NotchStrip: Equatable {
    case listening(heard: String)
    case thinking
    case line(String)
    case notice(String)
}

/// What the buddy icon beside the camera notch shows.
enum NotchActivity: Equatable {
    case idle, listening, thinking, talking
}

struct NotchConversationObservation {
    let phase: String
    let modelRevision: Int
    let entryCount: Int
    let strip: NotchStrip?
    let focused: Bool
    let frame: CGRect?
}

@Observable
final class NotchModel {
    var geometry: NotchGeometry?
    var strip: NotchStrip?
    var activity = NotchActivity.idle
    /// A full-screen app covers the cursor's screen, so the idle icon hides there.
    var overFullScreen = false
    var conversation = NotchConversation()
    @ObservationIgnored var onConversationObservation: (@MainActor (NotchConversationObservation) -> Void)?
    @ObservationIgnored private var observationRevision = 0

    @MainActor
    func observeConversation(_ phase: String, frame: CGRect? = nil, modelChanged: Bool = false) {
        guard let onConversationObservation else { return }
        if modelChanged { observationRevision += 1 }
        onConversationObservation(NotchConversationObservation(
            phase: phase, modelRevision: observationRevision, entryCount: conversation.entries.count, strip: strip,
            focused: conversation.focused, frame: frame
        ))
    }
}

/// One notch, on the screen with the cursor. It follows the cursor to another screen within half a second.
@MainActor
final class NotchPanel: NotchDisplay {
    /// Room for the widest strip and four lines of text below the tallest camera housing.
    private static let size = CGSize(width: 500, height: 560)
    private static let closeDelay = Duration.seconds(3)

    private let model = NotchModel()
    private let microphone: MicrophoneLevel
    private let observesEnvironment: Bool
    private var window: NotchWindow?
    private var tracking: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var closing: Task<Void, Never>?
    private var pointerTracking: Timer?
    private var pointerInside = false
    private var onEvent: ((BuddyEngine.Event) -> Void)?
    private let input = NotchInput()

    init(microphone: MicrophoneLevel, observesEnvironment: Bool = true,
         onConversationObservation: (@MainActor (NotchConversationObservation) -> Void)? = nil) {
        self.microphone = microphone
        self.observesEnvironment = observesEnvironment
        model.onConversationObservation = onConversationObservation
    }

    func start(onEvent: @escaping (BuddyEngine.Event) -> Void) {
        guard window == nil else { return }
        self.onEvent = onEvent
        let window = NotchWindow(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: NotchView(model: model, microphone: microphone, onEvent: onEvent))
        host.frame = CGRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        let content = NSView(frame: host.frame)
        content.addSubview(host)
        input.onEvent = onEvent
        input.isHidden = true
        content.addSubview(input)
        window.contentView = content
        window.onResignKey = { [weak self] in
            guard let self, model.conversation.focused else { return }
            self.onEvent?(.textBoxDismissed)
        }
        self.window = window
        follow()
        window.orderFrontRegardless()
        guard observesEnvironment else { return }
        let tracking = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(tracking, forMode: .common)
        self.tracking = tracking
        let pointerTracking = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        RunLoop.main.add(pointerTracking, forMode: .common)
        self.pointerTracking = pointerTracking
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
    }

    func stop() {
        tracking?.invalidate()
        tracking = nil
        pointerTracking?.invalidate()
        pointerTracking = nil
        onEvent = nil
        input.onEvent = nil
        pointerInside = false
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        closing?.cancel()
        closing = nil
        model.strip = nil
        model.activity = .idle
        window?.onResignKey = nil
        window?.close()
        window = nil
    }

    func update(_ conversation: NotchConversation) {
        guard model.conversation != conversation else { return }
        model.observeConversation("update.before-assignment")
        let release = model.conversation.focused && !conversation.focused
            || model.conversation.isOpen && !conversation.isOpen
        model.conversation = conversation
        input.isHidden = !conversation.isOpen || conversation.page == .history
        if input.stringValue != conversation.draft { input.stringValue = conversation.draft }
        positionInput()
        model.observeConversation("update.after-assignment-and-input-position", modelChanged: true)
        if release { releaseTextBox() }
        model.observeConversation("update.returned")
    }

    func focusTextBox() {
        guard let window, model.conversation.isOpen, model.conversation.page == .thread,
              !input.isBecomingFirstResponder else { return }
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(input)
    }

    private func positionInput() {
        guard let geometry = model.geometry else { return }
        input.frame = CGRect(x: 36, y: Self.size.height - geometry.core.height - 440 + 16, width: 398, height: 20)
    }

    func releaseTextBox() {
        guard let window, window.isKeyWindow else { return }
        model.observeConversation("release-editor.before")
        window.makeFirstResponder(nil)
        window.resignKey()
        model.observeConversation("release-editor.returned")
    }

    private func trackPointer() {
        trackPointer(at: NSEvent.mouseLocation)
    }

    func trackPointer(at mouse: CGPoint) {
        guard let window, let geometry = model.geometry else { return }
        let top = window.frame.maxY
        let region = model.conversation.isOpen
            ? CGRect(x: window.frame.midX - 230, y: top - geometry.core.height - 440, width: 460, height: geometry.core.height + 440)
            : CGRect(x: window.frame.midX - geometry.core.width / 2 - NotchView.earWidth,
                     y: top - geometry.core.height, width: geometry.core.width + 2 * NotchView.earWidth, height: geometry.core.height)
        let inside = region.contains(mouse) && (!model.overFullScreen || model.conversation.isOpen || model.strip != nil)
        window.ignoresMouseEvents = !model.conversation.isOpen || !inside
        if inside != pointerInside {
            pointerInside = inside
            onEvent?(.notchPointerChanged(inside))
        }
        if inside && !model.conversation.isOpen { onEvent?(.notchHoverElapsed) }
    }

    func show(_ notch: Notch) {
        model.observeConversation("show-strip.before")
        closing?.cancel()
        closing = nil
        switch notch {
        case .idle:
            model.strip = nil
            model.activity = .idle
        case .listening(let heard):
            model.strip = .listening(heard: heard)
            model.activity = .listening
        case .thinking:
            model.strip = .thinking
            model.activity = .thinking
        case .line(let line):
            model.strip = .line(line)
            model.activity = .talking
        case .notice(let notice):
            model.strip = .notice(notice)
            model.activity = .idle
        case .closing:
            model.activity = .idle
            if model.strip == .thinking { model.strip = nil }
            closing = Task { [weak self] in
                try? await Task.sleep(for: Self.closeDelay)
                guard !Task.isCancelled, let self else { return }
                closing = nil
                model.strip = nil
                model.observeConversation("closing-strip-cleared", modelChanged: true)
            }
        }
        model.observeConversation("show-strip.returned", modelChanged: true)
    }

    private func follow() {
        guard !model.conversation.isOpen else { return }
        let mouse = NSEvent.mouseLocation
        guard let window,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let geometry = NotchGeometry(screen: screen)
        if model.geometry != geometry { model.geometry = geometry; positionInput() }
        let frame = CGRect(
            x: screen.frame.midX - Self.size.width / 2, y: screen.frame.maxY - Self.size.height,
            width: Self.size.width, height: Self.size.height
        )
        if window.frame != frame { window.setFrame(frame, display: true) }
        let covered = observesEnvironment && Self.fullScreenApp(covers: screen)
        if model.overFullScreen != covered { model.overFullScreen = covered }
    }

    private static func fullScreenApp(covers screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        let windows = list.compactMap { info -> OnScreenWindow? in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary)
            else { return nil }
            return OnScreenWindow(owner: owner, layer: layer, alpha: info[kCGWindowAlpha as String] as? Double ?? 1, bounds: bounds)
        }
        return OnScreenWindow.fullScreenApp(
            in: windows, covers: CGDisplayBounds(number.uint32Value),
            below: max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY),
            ignoring: ProcessInfo.processInfo.processIdentifier
        )
    }
}

/// A window as `CGWindowListCopyWindowInfo` reports it, in global display coordinates with the origin at the top left.
struct OnScreenWindow {
    let owner: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect

    /// A full-screen space holds only its app's windows, one of which fills the display below the camera housing or
    /// the menu bar, `top` points high. A zoomed window on the desktop has the same bounds, but other apps' windows
    /// share its display. Transparent and tiny windows, which some utilities keep on every space, don't count.
    static func fullScreenApp(in windows: [OnScreenWindow], covers display: CGRect, below top: CGFloat, ignoring own: pid_t) -> Bool {
        let others = windows.filter {
            $0.layer == 0 && $0.owner != own && $0.alpha > 0 && $0.bounds.width >= 100 && $0.bounds.height >= 100
                && $0.bounds.intersects(display)
        }
        guard Set(others.map(\.owner)).count == 1 else { return false }
        return others.contains {
            $0.bounds.minX <= display.minX && $0.bounds.maxX >= display.maxX
                && $0.bounds.maxY >= display.maxY && $0.bounds.minY <= display.minY + top
        }
    }
}

/// The notch is drawn at the top center of its window, which is otherwise clear.
private struct NotchView: View {
    static let earWidth: CGFloat = 34
    static let stripWidth: CGFloat = 380

    let model: NotchModel
    let microphone: MicrophoneLevel
    let onEvent: (BuddyEngine.Event) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let geometry = model.geometry {
                notch(geometry)
                    .opacity(!model.conversation.isOpen && model.strip == nil && model.overFullScreen ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: model.strip)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.overFullScreen)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.08), value: model.conversation.isOpen)
    }

    private func notch(_ geometry: NotchGeometry) -> some View {
        let closedWidth = geometry.core.width + 2 * Self.earWidth
        let open = model.strip != nil || model.conversation.isOpen
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.earWidth + geometry.core.width)
                NotchIcon(activity: model.activity, microphone: microphone, reduceMotion: reduceMotion)
                    .frame(width: Self.earWidth)
            }
            .frame(width: closedWidth, height: geometry.core.height)
            if model.conversation.isOpen {
                NotchConversationView(model: model, onEvent: onEvent)
                    .frame(width: 460, height: 440)
                    .transition(.opacity)
            } else if let strip = model.strip {
                StripText(strip: strip, microphone: microphone, reduceMotion: reduceMotion)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .frame(width: max(closedWidth, Self.stripWidth), alignment: .leading)
                    .transition(.opacity)
            }
        }
        .frame(width: model.conversation.isOpen ? 460 : open ? max(closedWidth, Self.stripWidth) : closedWidth)
        .background {
            NotchShape(corner: open ? 18 : 10)
                .fill(.black)
                .padding(.horizontal, -NotchShape.shoulder)
                .shadow(color: .black.opacity(open ? 0.3 : 0), radius: 10, y: 4)
        }
    }
}

private final class NotchCursorView: NSView {
    private let cursor: NSCursor

    // Inactive nonkey panels need this private WindowServer property to display their cursors.
    private static let backgroundCursorEnabled: Bool = {
        typealias Connection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let symbols = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connectionSymbol = dlsym(symbols, "CGSMainConnectionID"),
              let propertySymbol = dlsym(symbols, "CGSSetConnectionProperty") else { return false }
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        let setProperty = unsafeBitCast(propertySymbol, to: SetProperty.self)
        return setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()

    init(cursor: NSCursor) {
        self.cursor = cursor
        _ = Self.backgroundCursorEnabled
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { cursor.set() }
    override func mouseMoved(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}

private struct NotchButtonCursor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NotchCursorView { NotchCursorView(cursor: .pointingHand) }
    func updateNSView(_ view: NotchCursorView, context: Context) { view.isHidden = !isEnabled }
}

private final class NotchInput: NSTextField, NSTextFieldDelegate {
    var onEvent: ((BuddyEngine.Event) -> Void)?
    private(set) var isBecomingFirstResponder = false
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        textColor = .white
        font = .systemFont(ofSize: 13, weight: .medium)
        placeholderString = "Ask about your screen"
        setAccessibilityLabel("Ask Buddy")
        delegate = self
        let cursor = NotchCursorView(cursor: .iBeam)
        cursor.frame = bounds
        cursor.autoresizingMask = [.width, .height]
        addSubview(cursor)
    }

    required init?(coder: NSCoder) { nil }

    override func becomeFirstResponder() -> Bool {
        // The focus event can synchronously ask the panel to focus this field again.
        isBecomingFirstResponder = true
        defer { isBecomingFirstResponder = false }
        let accepted = super.becomeFirstResponder()
        if accepted { onEvent?(.textBoxFocused) }
        return accepted
    }

    func controlTextDidChange(_ notification: Notification) { onEvent?(.textBoxChanged(stringValue)) }
    func controlTextDidEndEditing(_ notification: Notification) { onEvent?(.textBoxDismissed) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.insertNewline(_:)) {
            onEvent?(.textBoxSubmitted(stringValue))
            return true
        }
        if command == #selector(NSResponder.cancelOperation(_:)) {
            onEvent?(.interrupted)
            return true
        }
        return false
    }
}

private struct NotchConversationFrameObservation: ViewModifier {
    let phase: String
    let model: NotchModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if model.onConversationObservation != nil {
            content.onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named("notch-conversation-observation"))
            } action: { frame in
                model.observeConversation(phase, frame: frame)
            }
        } else {
            content
        }
    }
}

private struct NotchConversationView: View {
    let model: NotchModel
    let onEvent: (BuddyEngine.Event) -> Void

    var body: some View {
        VStack(spacing: 0) {
            conversationHeader
                .modifier(NotchConversationFrameObservation(phase: "frame.header", model: model))
            if model.conversation.page == .history {
                historyList
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if model.conversation.entries.isEmpty {
                                Text("Ask Buddy about your screen.")
                                    .foregroundStyle(DS.Colors.textSecondary)
                                    .padding(.vertical, 16)
                            }
                            ForEach(Array(model.conversation.entries.enumerated()), id: \.offset) { index, entry in
                                row(entry).id(index)
                            }
                            if case .thinking? = model.strip {
                                ThinkingIndicator(reduceMotion: true)
                                    .modifier(NotchConversationFrameObservation(phase: "frame.status-thinking", model: model))
                            } else if case .listening(let heard)? = model.strip {
                                Text(heard.isEmpty ? "Listening…" : heard).foregroundStyle(DS.Colors.textSecondary)
                                    .modifier(NotchConversationFrameObservation(phase: "frame.status-listening", model: model))
                            }
                            Color.clear.frame(height: 1).id("bottom")
                                .modifier(NotchConversationFrameObservation(phase: "frame.bottom-anchor", model: model))
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                        .modifier(NotchConversationFrameObservation(phase: "frame.padded-content", model: model))
                    }
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .modifier(NotchConversationFrameObservation(phase: "frame.viewport", model: model))
                    .onAppear {
                        model.observeConversation("scroll.appear.before-request")
                        proxy.scrollTo("bottom", anchor: .bottom)
                        model.observeConversation("scroll.appear.request-returned")
                    }
                    .onChange(of: model.conversation.entries) { _, _ in
                        model.observeConversation("scroll.entries.before-request")
                        proxy.scrollTo("bottom", anchor: .bottom)
                        model.observeConversation("scroll.entries.request-returned")
                    }
                }
                Divider().overlay(.white.opacity(0.12))
                HStack(spacing: 10) {
                    Color.clear.frame(height: 20)
                    Button {
                        onEvent(.textBoxFocused)
                        onEvent(.textBoxSubmitted(model.conversation.draft))
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .background(NotchButtonCursor())
                    .foregroundStyle(DS.Colors.accentText)
                    .disabled(model.conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send question")
                }
                .padding(16)
                .modifier(NotchConversationFrameObservation(phase: "frame.composer", model: model))
            }
        }
        .foregroundStyle(.white)
        .coordinateSpace(name: "notch-conversation-observation")

    }

    private var conversationHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.conversation.page == .history ? "Past conversations" : "Conversation")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                if model.conversation.page == .history {
                    Button { onEvent(.conversationThreadRequested) } label: {
                        Label("Back to conversation", systemImage: "chevron.left")
                            .frame(height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(NotchButtonCursor())
                    .foregroundStyle(DS.Colors.accentText)
                    .accessibilityLabel("Back to current conversation")
                    .accessibilityIdentifier("notch.back")
                    .help("Back to current conversation")
                } else {
                    Button { onEvent(.conversationsRequested) } label: {
                        Label("Past conversations", systemImage: "clock.arrow.circlepath")
                            .frame(height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(NotchButtonCursor())
                    .foregroundStyle(DS.Colors.accentText)
                    .accessibilityLabel("Past conversations")
                    .accessibilityIdentifier("notch.history")
                    .help("Past conversations")
                }
                Spacer(minLength: 0)
                Button {
                    onEvent(.newConversationRequested)
                    onEvent(.textBoxFocused)
                } label: {
                    Label("New conversation", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(NotchButtonCursor())
                .foregroundStyle(DS.Colors.textPrimary)
                .accessibilityIdentifier("notch.new")
                .help("Start a new conversation")
            }
            .font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.conversation.pastConversations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No past conversations yet.")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text("Choose New conversation above to start fresh.")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                ForEach(model.conversation.pastConversations) { conversation in
                    historyRow(conversation)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
    }

    /// "Started Nov 5, 2026 at 9:14 PM · Active 10:02 PM", with the active date only when it's another day.
    static func times(of conversation: NotchConversation.HistoryItem, calendar: Calendar = .current) -> String {
        let started = conversation.startedAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
        let active = calendar.isDate(conversation.lastActivity, inSameDayAs: conversation.startedAt)
            ? conversation.lastActivity.formatted(.dateTime.hour().minute())
            : conversation.lastActivity.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "Started \(started) · Active \(active)"
    }

    private func historyRow(_ conversation: NotchConversation.HistoryItem) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Button { onEvent(.conversationOpened(conversation.id)) } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conversation.question)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.times(of: conversation))
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(NotchButtonCursor())
            .accessibilityHint("Open and continue this conversation")
            .accessibilityIdentifier("notch.open.\(conversation.id)")
            Button(role: .destructive) { onEvent(.conversationDeleted(conversation.id)) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .frame(width: 36, height: 36)
                    .background(DS.Colors.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .background(NotchButtonCursor())
            .foregroundStyle(DS.Colors.danger)
            .accessibilityLabel("Delete conversation: \(conversation.question)")
            .accessibilityIdentifier("notch.delete.\(conversation.id)")
            .help("Delete conversation")
            .padding(.trailing, 10)
        }
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.Colors.textSecondary.opacity(0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func row(_ entry: NotchConversation.Entry) -> some View {
        let words: String
        let name: String
        switch entry {
        case .owner(let text): words = text; name = "You"
        case .buddy(let text): words = text; name = "Buddy"
        case .notice(let text): words = text; name = "Notice"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Colors.accentText)
            Text(words).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A notch that widens the camera housing: square top edge, small concave shoulders where it meets the top of the
/// screen, and rounded bottom corners. Its rect includes the shoulders.
private struct NotchShape: Shape {
    static let shoulder: CGFloat = 7
    var corner: CGFloat

    var animatableData: CGFloat {
        get { corner }
        set { corner = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder = Self.shoulder
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        let corner = min(corner, (right - left) / 2, (rect.height - shoulder) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + shoulder), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - corner))
        path.addQuadCurve(to: CGPoint(x: left + corner, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - corner, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - corner), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The buddy's triangle. It swells with the owner's voice while listening, turns while thinking and bobs while talking.
/// With reduced motion it holds still, and only its brightness and glow change.
private struct NotchIcon: View {
    let activity: NotchActivity
    let microphone: MicrophoneLevel
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || activity == .idle)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Triangle()
                .fill(activity == .idle ? DS.Colors.accent : DS.Colors.accentText)
                .frame(width: 10, height: 11)
                .rotationEffect(.degrees(rotation(at: time)))
                .scaleEffect(scale(at: time))
                .shadow(color: DS.Colors.accent.opacity(activity == .idle ? 0 : 0.9), radius: 5)
        }
    }

    private func rotation(at time: TimeInterval) -> Double {
        guard activity == .thinking, !reduceMotion else { return 35 }
        return 35 + time.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360
    }

    private func scale(at time: TimeInterval) -> Double {
        guard !reduceMotion else { return activity == .idle ? 1 : 1.15 }
        switch activity {
        case .idle, .thinking: return 1
        case .listening: return 1 + min(microphone.value * 2.85, 1) * 0.45
        case .talking: return 1 + (sin(time * 9) + 1) * 0.08
        }
    }
}

private struct StripText: View {
    let strip: NotchStrip
    let microphone: MicrophoneLevel
    let reduceMotion: Bool

    var body: some View {
        switch strip {
        case .listening(let heard):
            HStack(alignment: .center, spacing: 10) {
                ListeningWaveform(microphone: microphone, reduceMotion: reduceMotion)
                text(heard.isEmpty ? "Listening…" : heard, lineLimit: 3)
                    .truncationMode(.head)
                    .foregroundStyle(heard.isEmpty ? DS.Colors.textSecondary : .white)
            }
        case .thinking:
            ThinkingIndicator(reduceMotion: reduceMotion)
        case .line(let line):
            text(line, lineLimit: 4)
                .foregroundStyle(.white)
        case .notice(let notice):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(DS.Colors.accentText)
                text(notice, lineLimit: 4)
                    .foregroundStyle(DS.Colors.textPrimary)
            }
        }
    }

    private func text(_ string: String, lineLimit: Int) -> some View {
        Text(string)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ThinkingIndicator: View {
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 7) {
            TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion)) { timeline in
                HStack(spacing: 3) {
                    ForEach(0..<3) { dot in
                        Circle()
                            .frame(width: 3, height: 3)
                            .opacity(reduceMotion ? 1 : 0.35 + 0.65 * (sin(timeline.date.timeIntervalSinceReferenceDate * 4 - Double(dot)) + 1) / 2)
                    }
                }
            }
            Text("Thinking…")
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(DS.Colors.accentText)
    }
}

/// Five bars that rise with the owner's voice while push-to-talk is held. Upstream's listening waveform.
private struct ListeningWaveform: View {
    let microphone: MicrophoneLevel
    let reduceMotion: Bool
    private let profile: [Double] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36, paused: reduceMotion)) { timeline in
            HStack(spacing: 2) {
                ForEach(profile.indices, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.accent)
                        .frame(width: 2.5, height: height(of: bar, at: timeline.date))
                }
            }
            .frame(height: 18)
            .shadow(color: DS.Colors.accent.opacity(0.6), radius: 6)
            .animation(reduceMotion ? nil : .linear(duration: 0.08), value: microphone.value)
        }
    }

    private func height(of bar: Int, at date: Date) -> CGFloat {
        let voice = pow(min(max(microphone.value - 0.008, 0) * 2.85, 1), 0.76)
        let idle = reduceMotion ? 0 : (sin(date.timeIntervalSinceReferenceDate * 3.6 + Double(bar) * 0.35) + 1) * 0.75
        return 3 + voice * 12 * profile[bar] + idle
    }
}
