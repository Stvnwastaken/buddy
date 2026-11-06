import AppKit
import BuddyCore
import SwiftUI

struct RunCardView: View {
    static let width: CGFloat = 340

    let run: AgentRun
    /// The tallest the note area grows before it scrolls. The dock shrinks it when it holds several cards.
    var noteHeight: CGFloat = 320
    /// The question the owner's next spoken or typed turn answers. Only that question's card invites a spoken answer.
    var questionTakingNextTurn: ToolCallID?
    var shortcuts = Shortcuts()
    let onStop: () -> Void
    let onShowFolder: () -> Void
    let onClose: () -> Void
    /// The owner's answer to a permission prompt, by its id: true to approve.
    let onApproval: (String, Bool) -> Void
    let onChoice: (ToolCallID, String) -> Void
    /// The owner's answer to the run's request for the screen: true to allow it.
    let onTakeover: (ToolCallID, Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let look = run.look
        let needsOwner = run.status == .needsOwner
        VStack(alignment: .leading, spacing: 0) {
            header(look)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider().overlay(DS.Colors.textSecondary.opacity(0.2))
            ScrollView {
                sections(look)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: run.asks.isEmpty ? noteHeight : 560)
            Divider().overlay(DS.Colors.textSecondary.opacity(0.2))
            controls(ended: look.ending != nil)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .textSelection(.enabled)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(DS.Colors.textPrimary)
        .background(DS.Colors.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(needsOwner ? DS.Colors.accentText : .white.opacity(0.08), lineWidth: needsOwner ? 2 : 1)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: needsOwner)
        .preferredColorScheme(.dark)
        .tint(DS.Colors.accentText)
        .allowsWindowActivationEvents()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent run \(run.id.number), \(run.name), \(look.words)")
        .accessibilityIdentifier("runCard")
    }

    private func header(_ look: StatusLook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                mark(look.mark)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text("Agent run \(run.id.number) · \(look.words)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Text(run.name)
                .font(.headline)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(run.name)
            if run.namesItself {
                Text(run.request)
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(run.request)
            }
        }
    }

    @ViewBuilder private func mark(_ mark: StatusLook.Mark) -> some View {
        switch mark {
        case .working:
            ProgressView().controlSize(.small)
        case .needsOwner:
            Image(systemName: "hand.raised.fill").foregroundStyle(DS.Colors.accentText)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Colors.success)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DS.Colors.danger)
        case .stopped:
            Image(systemName: "stop.circle.fill").foregroundStyle(DS.Colors.textSecondary)
        case .takingOver:
            Image(systemName: "cursorarrow.motionlines").foregroundStyle(DS.Colors.accent)
        }
    }

    private func sections(_ look: StatusLook) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if run.status == .takingOver {
                Text("Press Esc to take back control.")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(DS.Colors.accentText)
                    .accessibilityIdentifier("runTakeoverHint")
            }
            if !run.asks.isEmpty {
                section("Waiting for you") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(run.asks.enumerated()), id: \.offset) { _, ask in
                            askRow(ask)
                        }
                    }
                }
            }
            if let ending = look.ending {
                section("Report") { lines(ending) }
            }
            if !run.noteBody.isEmpty {
                section("Run note") { lines(run.noteBody) }
            } else if look.ending == nil && run.asks.isEmpty && run.status != .takingOver {
                Text("Starting…")
                    .font(.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            if !run.denials.isEmpty {
                section("Denied") {
                    ForEach(Array(run.denials.enumerated()), id: \.offset) { _, denial in
                        denialRow(denial)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Colors.textSecondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func lines(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(NoteLine.lines(of: text).enumerated()), id: \.offset) { _, line in
                noteLine(line)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func noteLine(_ line: NoteLine) -> some View {
        switch line {
        case .step(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Image(systemName: done ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(done ? DS.Colors.success : DS.Colors.textSecondary)
                    .accessibilityLabel(done ? "Done" : "Not done")
                Text(Self.inline(text))
            }
            .accessibilityElement(children: .combine)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .foregroundStyle(DS.Colors.textSecondary)
                    .accessibilityHidden(true)
                Text(Self.inline(text))
            }
        case .heading(let text):
            Text(Self.inline(text)).fontWeight(.semibold)
        case .text(let text):
            Text(Self.inline(text))
        case .blank:
            Color.clear.frame(height: 2)
        }
    }

    private func denialRow(_ denial: Denial) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(denial.action)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(denial.action)
            Text(Self.inline(denial.reason))
                .font(.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func askRow(_ ask: OwnerAsk) -> some View {
        switch ask {
        case .approval(let id, let action, let reason):
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow this?")
                    .font(.callout.weight(.medium))
                Text(action)
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Request: \(action)")
                Text(Self.inline(reason))
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Deny") { onApproval(id, false) }
                        .accessibilityIdentifier("runDeny")
                    Button("Approve") { onApproval(id, true) }
                        .accessibilityIdentifier("runApprove")
                }
            }
            .accessibilityElement(children: .contain)
        case .question(let call, let question, let choices):
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.inline(question))
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                    Button { onChoice(call, choice) } label: {
                        Text(choice)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("runChoice")
                }
                Text(answerHint(for: call, hasChoices: !choices.isEmpty))
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
        case .takeover(let call, let reason):
            VStack(alignment: .leading, spacing: 8) {
                Text("Let the run use your mouse and keyboard?")
                    .font(.callout.weight(.medium))
                Text(Self.inline(reason))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Reason: \(reason)")
                Text("Your own mouse and keyboard stop working until it's done. Press Esc or \(shortcuts[.talk].instruction) to take back control.")
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Don't Allow") { onTakeover(call, false) }
                        .accessibilityIdentifier("runTakeoverDeny")
                    Button("Allow") { onTakeover(call, true) }
                        .accessibilityIdentifier("runTakeoverAllow")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func controls(ended: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if ended {
                if run.folder != nil {
                    Button("Show in Finder", action: onShowFolder)
                        .accessibilityIdentifier("runShowFolder")
                }
                Button("Close", action: onClose)
                    .accessibilityIdentifier("runClose")
            } else {
                Button("Stop", action: onStop)
                    .accessibilityLabel("Stop the agent run")
                    .accessibilityIdentifier("runStop")
            }
        }
    }

    /// How the owner can answer this question. While an earlier question in the dock is waiting, the next spoken or
    /// typed turn goes to that one, so this card asks for a click or for patience instead.
    func answerHint(for call: ToolCallID, hasChoices: Bool) -> String {
        let speak = "\(shortcuts[.talk].instruction), or \(shortcuts[.textBox].instruction) to type."
        switch (hasChoices, questionTakingNextTurn.map { $0 == call } ?? true) {
        case (false, true): return "Answer out loud: \(speak)"
        case (true, true): return "Or answer out loud: \(speak)"
        case (false, false): return "An earlier question takes your next spoken or typed answer. Answer this one after it."
        case (true, false): return "Click a choice. An earlier question takes your next spoken or typed answer."
        }
    }

    private static func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

struct StatusLook: Equatable {
    enum Mark { case working, needsOwner, takingOver, done, failed, stopped }

    let mark: Mark
    let words: String
    let ending: String?
}

extension AgentRun {
    var look: StatusLook {
        switch status {
        case .running:
            return StatusLook(mark: .working, words: "Working", ending: nil)
        case .paused:
            return StatusLook(mark: .working, words: "Switching provider", ending: nil)
        case .needsOwner:
            return StatusLook(mark: .needsOwner, words: "Needs you", ending: nil)
        case .takingOver:
            return StatusLook(mark: .takingOver, words: "Using your screen", ending: nil)
        case .done:
            let report = (report ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return StatusLook(mark: .done, words: "Done", ending: report.isEmpty ? "The run finished without a report." : report)
        case .failed(let message):
            return StatusLook(mark: .failed, words: "Failed", ending: message)
        case .stopped(.owner):
            return StatusLook(mark: .stopped, words: "Stopped", ending: "You stopped this run.")
        case .stopped(.stepCap):
            return StatusLook(mark: .stopped, words: "Stopped", ending: "Buddy stopped this run at its step cap.")
        case .stopped(.timeCap):
            return StatusLook(mark: .stopped, words: "Stopped", ending: "Buddy stopped this run at its time cap.")
        }
    }
}

/// One line of a run note or report. Inline Markdown leaves checklist and list markers as typed, so the card draws
/// them as marks.
enum NoteLine: Equatable {
    case step(done: Bool, String)
    case bullet(String)
    case heading(String)
    case text(String)
    case blank

    static func lines(of text: String) -> [NoteLine] {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { NoteLine($0.trimmingCharacters(in: .whitespaces)) }
    }

    init(_ line: String) {
        if let step = line.wholeMatch(of: /[-*+] \[([ xX])\]\s+(.*)/) {
            self = .step(done: step.1 != " ", String(step.2))
        } else if let bullet = line.wholeMatch(of: /[-*+]\s+(.*)/) {
            self = .bullet(String(bullet.1))
        } else if let heading = line.wholeMatch(of: /#{1,6}\s+(.*)/) {
            self = .heading(String(heading.1))
        } else {
            self = line.isEmpty ? .blank : .text(line)
        }
    }
}

/// The dock's cards, oldest first, in one column that scrolls when it outgrows the screen. A card that needs the
/// owner scrolls into view.
struct DockView: View {
    let cards: [RunCardView]
    let maxHeight: CGFloat
    /// Room beside the cards for a scroll bar that takes space, so it never covers or clips them.
    var scrollerWidth: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: DockPanel.gap) {
                    ForEach(cards, id: \.run.id) { card in
                        card
                            .id(card.run.id)
                            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(width: RunCardView.width + scrollerWidth, alignment: .leading)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: cards.map(\.run.id))
            .onChange(of: needingOwner) { waited, waiting in
                guard let newest = waiting.last(where: { !waited.contains($0) }) else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scroller.scrollTo(newest, anchor: .top) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent runs")
        .accessibilityIdentifier("runDock")
    }

    private var needingOwner: [RunID] {
        cards.map(\.run).filter { $0.status == .needsOwner }.map(\.id)
    }
}

/// The dock at the right edge of the screen the cursor was on when its first card appeared.
final class DockPanel {
    static let gap: CGFloat = 10
    private static let inset: CGFloat = 16

    private let send: (BuddyEngine.Event) -> Void
    private var window: (panel: NSPanel, hosting: NSHostingView<DockView>)?
    private var shown: [AgentRun] = []
    private var shownQuestion: ToolCallID?
    private var shownShortcuts = Shortcuts()
    private var screenFrame = NSRect.zero

    init(send: @escaping (BuddyEngine.Event) -> Void) {
        self.send = send
    }

    func show(_ runs: [AgentRun], questionTakingNextTurn: ToolCallID? = nil, shortcuts: Shortcuts = Shortcuts()) {
        guard runs != shown || questionTakingNextTurn != shownQuestion || shortcuts != shownShortcuts else { return }
        let newlyWaiting = runs.contains { run in
            run.status == .needsOwner && shown.first { $0.id == run.id }?.status != .needsOwner
        }
        shown = runs
        shownQuestion = questionTakingNextTurn
        shownShortcuts = shortcuts
        guard !runs.isEmpty else {
            window?.panel.orderOut(nil)
            return
        }
        let appearing = window.map { !$0.panel.isVisible } ?? true
        if appearing { screenFrame = Self.visibleFrameUnderCursor() }
        let cards = runs.map { card(for: $0, among: runs.count, questionTakingNextTurn: questionTakingNextTurn) }
        let maxHeight = screenFrame.height - 2 * Self.inset
        let content = DockView(cards: cards, maxHeight: maxHeight)
        let (panel, hosting) = window ?? makeWindow(content)
        hosting.rootView = content
        let height = min(hosting.fittingSize.height, maxHeight)
        let scrollerWidth = Self.scrollerWidth(scrolls: height >= maxHeight - 0.5, style: NSScroller.preferredScrollerStyle)
        if scrollerWidth > 0 { hosting.rootView = DockView(cards: cards, maxHeight: maxHeight, scrollerWidth: scrollerWidth) }
        let width = RunCardView.width + scrollerWidth
        let frame = NSRect(
            x: screenFrame.maxX - Self.inset - width,
            y: screenFrame.maxY - Self.inset - height,
            width: width,
            height: height
        )
        if appearing {
            appear(panel, at: frame)
        } else {
            resize(panel, to: frame)
            if newlyWaiting { panel.orderFrontRegardless() }
        }
    }

    /// With "Show scroll bars" set to Always, or a mouse attached, a scrolling dock's scroll bar takes space of its own
    /// instead of floating over the cards, so the dock widens by it.
    static func scrollerWidth(scrolls: Bool, style: NSScroller.Style) -> CGFloat {
        scrolls && style == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    /// A card in a dock of several keeps its note shorter, so more cards fit before the dock scrolls.
    func card(for run: AgentRun, among count: Int = 1, questionTakingNextTurn: ToolCallID? = nil) -> RunCardView {
        RunCardView(
            run: run,
            noteHeight: count > 1 ? 180 : 320,
            questionTakingNextTurn: questionTakingNextTurn,
            shortcuts: shownShortcuts,
            onStop: { [send] in send(.runStopRequested(run.id)) },
            onShowFolder: {
                guard let folder = run.folder else { return }
                Self.reveal(folder)
            },
            onClose: { [send] in send(.runDismissed(run.id)) },
            onApproval: { [send] request, approved in
                send(.runApprovalAnswered(run.id, request: request, approved: approved))
            },
            onChoice: { [send] call, choice in send(.runQuestionAnswered(run.id, call, choice)) },
            onTakeover: { [send] call, approved in send(.runTakeoverAnswered(run.id, call, approved: approved)) }
        )
    }

    /// A click on a card leaves Buddy inactive, and macOS keeps an inactive app from bringing Finder forward, so
    /// Buddy takes the click's activation and hands it to Finder.
    private static func reveal(_ folder: String) {
        NSApp.activate()
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.apple.finder")
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder, isDirectory: true)])
    }

    /// A borderless panel never becomes key, so a click on a card leaves keyboard focus in the owner's app.
    private func makeWindow(_ content: DockView) -> (panel: NSPanel, hosting: NSHostingView<DockView>) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: RunCardView.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.title = "Agent runs"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        window = (panel, hosting)
        return (panel, hosting)
    }

    private func appear(_ panel: NSPanel, at frame: NSRect) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        panel.setFrame(reduceMotion ? frame : frame.offsetBy(dx: 0, dy: 8), display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1, 0.5, 1)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(frame, display: true) }
        }
    }

    /// A frame change that also goes through the animator replaces an appear animation still in flight.
    private func resize(_ panel: NSPanel, to frame: NSRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return panel.setFrame(frame, display: true)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().setFrame(frame, display: true)
        }
    }

    private static func visibleFrameUnderCursor() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
