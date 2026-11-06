import AppKit
import BuddyCore
import Foundation
import MachO
import Synchronization
import Testing
@testable import Buddy

@MainActor
@Suite(.serialized)
struct NotchPanelTests {
    @Test(arguments: [false, true])
    func hoveringTheNotchOrBuddyIconWaitsThreeHundredMillisecondsAndNeverTakesFocus(overIcon: Bool) throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000))
        var engine = BuddyEngine(providerConnected: true, now: { clock.withLock { $0 } })
        let notch = NotchPanel(microphone: MicrophoneLevel(), observesEnvironment: false)
        let previousWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
        notch.start { event in
            #expect(engine.handle(event).isEmpty)
            notch.update(engine.state.notchConversation)
        }
        defer { notch.stop() }
        let window = try #require(NSApp.windows.first {
            !previousWindows.contains(ObjectIdentifier($0)) && String(describing: type(of: $0)) == "NotchWindow"
        })
        let geometry = NotchGeometry(screen: try #require(window.screen))
        let inside = CGPoint(x: window.frame.midX + (overIcon ? geometry.core.width / 2 + 17 : 0),
                             y: window.frame.maxY - 1)
        let outside = CGPoint(x: window.frame.minX - 10, y: window.frame.maxY - 1)

        notch.trackPointer(at: inside)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_000.299) }
        notch.trackPointer(at: inside)
        #expect(engine.state.notchConversation.isOpen == false)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_000.3) }
        notch.trackPointer(at: inside)
        #expect(engine.state.notchConversation.isOpen)
        #expect(engine.state.notchConversation.focused == false)
        #expect(window.isKeyWindow == false)

        notch.trackPointer(at: outside)
        #expect(engine.state.notchConversation.isOpen == false)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_002) }
        notch.trackPointer(at: inside)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_002.15) }
        notch.trackPointer(at: outside)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_003) }
        notch.trackPointer(at: inside)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_003.299) }
        notch.trackPointer(at: inside)
        #expect(engine.state.notchConversation.isOpen == false)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_003.3) }
        notch.trackPointer(at: inside)
        #expect(engine.state.notchConversation.isOpen)
        #expect(engine.state.notchConversation.focused == false)
        #expect(window.isKeyWindow == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_NOTCH_EVIDENCE"] != nil))
    func ownedHistoryControlsRenderScrollContinueDeleteAndClear() async throws {
        let directory = URL(filePath: try #require(ProcessInfo.processInfo.environment["BUDDY_NOTCH_EVIDENCE"]), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = HistoryStore(url: directory.appending(path: "fixture-history.json"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let longTurns = (1...30).map { number in
            TurnRecord(transcript: "Long conversation question \(number)",
                       reply: "Answer \(number). This explanation stays readable while scrolling through earlier turns.")
        }
        try store.save(ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "What is my paper kite called?", reply: "Copper Finch."),
                                 TurnRecord(transcript: "What color are its wings?", reply: "Its wings are gold.")],
                         lastActivity: date.addingTimeInterval(-86_400), endedAt: date.addingTimeInterval(-86_390),
                         summary: ConversationSummary(text: "The owner's kite is Copper Finch.", turns: 1)),
            Conversation(turns: [TurnRecord(transcript: "Which fern can I delete from this fixture?", reply: "Silver Fern.")],
                         lastActivity: date.addingTimeInterval(-100), endedAt: date.addingTimeInterval(-90),
                         summary: ConversationSummary(text: "The spare fern is Silver Fern.", turns: 1)),
            Conversation(turns: longTurns, lastActivity: date.addingTimeInterval(-200), endedAt: date.addingTimeInterval(-190),
                         summary: ConversationSummary(text: "A long explanation with thirty turns.", turns: 30)),
            Conversation(turns: [TurnRecord(transcript: "What is today's task?", reply: "Water the plants.")], lastActivity: date,
                         summary: ConversationSummary(text: "Today's task is watering plants.", turns: 1))
        ]))
        let notch = NotchPanel(microphone: MicrophoneLevel(), observesEnvironment: false)
        var engine = BuddyEngine(providerConnected: true, history: try store.load(), spokenReplies: false, now: { date })
        var request: TurnRequest?
        var shownNotch: Notch?
        func send(_ event: BuddyEngine.Event) {
            let effects = engine.handle(event)
            notch.update(engine.state.notchConversation)
            for effect in effects {
                do {
                    switch effect {
                    case .saveHistory(let history): try store.save(history)
                    case .clearHistory:
                        try store.clear()
                        _ = engine.handle(.historyCleared(error: nil))
                        notch.update(engine.state.notchConversation)
                    case .showTextBox: notch.focusTextBox()
                    case .hideTextBox: notch.releaseTextBox()
                    case .showNotch(let value):
                        shownNotch = value
                        notch.show(value)
                    case .sendTurn(let turn): request = turn
                    default: break
                    }
                } catch { Issue.record("Owned history fixture failed: \(error)") }
            }
        }
        let previousWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
        notch.start(onEvent: send)
        defer { notch.stop() }
        let ownedWindows = NSApp.windows.filter {
            !previousWindows.contains(ObjectIdentifier($0)) && String(describing: type(of: $0)) == "NotchWindow"
        }
        try #require(ownedWindows.count == 1, "The fixture must create exactly one owned NotchWindow")
        let window = try #require(ownedWindows.first)
        send(.notchPointerChanged(true))
        send(.textBoxFocused)
        await Task.yield()
        let root = try #require(window.contentView)
        try await picture(root, directory: directory, name: "initial-thread-diagnostic")
        try await press("notch.history", in: root)
        #expect(engine.state.notchConversation.pastConversations.map(\.id) == [3, 1, 2, 0])
        try await picture(root, directory: directory, name: "history-list")
        try await press("notch.back", in: root)
        #expect(engine.state.notchConversation.entries == [.owner("What is today's task?"), .buddy("Water the plants.")])
        try await press("notch.history", in: root)
        try await press("notch.open.2", in: root, history: engine.state.notchConversation.pastConversations)
        #expect(engine.state.notchConversation.entries.first == .owner("Long conversation question 1"))
        #expect(engine.state.notchConversation.entries.last == .buddy("Answer 30. This explanation stays readable while scrolling through earlier turns."))
        let scroll = try #require(descendants(root).compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        #expect(document.bounds.height > scroll.contentView.bounds.height)
        try await picture(root, directory: directory, name: "long-thread-latest")
        let latestReply = "Answer 30. This explanation stays readable while scrolling through earlier turns."
        let initialEnd = try measureThreadEnd(in: scroll, latestReply: latestReply, stage: "initial")
        try #require(initialEnd.latestReplyFrame != nil, "The owned accessibility tree must expose the exact latest saved reply")
        #expect(initialEnd.isAtLatestTurn, "The reopened conversation must initially show its complete latest saved reply at the semantic end without a manual scroll")
        let latestOffset = scroll.contentView.bounds.minY
        document.scroll(.zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(150))
        #expect(scroll.contentView.bounds.minY < latestOffset)
        try await picture(root, directory: directory, name: "long-thread-first")
        let olderEnd = try measureThreadEnd(in: scroll, latestReply: latestReply, stage: "older-negative-control")
        #expect(olderEnd.isAtLatestTurn == false, "The same end predicate must reject the deliberately older scroll position")
        #expect(abs(olderEnd.semanticBottomGap) > 2)
        #expect(olderEnd.latestReplyFullyVisible == false)
        try await press("notch.history", in: root)
        try await press("notch.open.2", in: root, history: engine.state.notchConversation.pastConversations)
        try await picture(root, directory: directory, name: "long-thread-reopened-latest")
        let reopenedScroll = try #require(descendants(root).compactMap { $0 as? NSScrollView }.first)
        let reopenedEnd = try measureThreadEnd(in: reopenedScroll, latestReply: latestReply, stage: "same-thread-reopened")
        try #require(reopenedEnd.latestReplyFrame != nil, "The reopened owned accessibility tree must expose the exact latest saved reply")
        #expect(reopenedEnd.isAtLatestTurn, "Reopening the same conversation after reading its first turns must return to its complete latest saved reply at the semantic end")
        try await press("notch.history", in: root)
        try await press("notch.open.0", in: root, history: engine.state.notchConversation.pastConversations)
        #expect(engine.state.notchConversation.entries == [
            .owner("What is my paper kite called?"), .buddy("Copper Finch."),
            .owner("What color are its wings?"), .buddy("Its wings are gold.")
        ])
        try await picture(root, directory: directory, name: "reopened-thread")
        send(.textBoxFocused)
        await Task.yield()
        let editor = try #require(window.firstResponder as? NSTextView)
        try #require(editor.isFieldEditor)
        let live = ProcessInfo.processInfo.environment["BUDDY_NOTCH_LIVE_CLAUDE"] == "1"
        let question = live ? "What color are my kite’s wings? Answer with only the color." : "x"
        var keys = [("\r", UInt16(36))]
        if live {
            editor.insertText(question, replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            keys.insert(("x", UInt16(7)), at: 0)
        }
        for (characters, keyCode) in keys {
            try #require(window.isKeyWindow)
            try #require(window.firstResponder === editor)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            NSApp.sendEvent(event)
        }
        let capture = ScreenCapture(jpeg: Data([1, 2, 3]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
                                    pixelWidth: 1280, pixelHeight: 800, containsCursor: true)
        send(.screensCaptured([capture]))
        #expect(request == TurnRequest(transcript: question, captures: [capture], earlierSummaries: [
            "The spare fern is Silver Fern.", "Today's task is watering plants.", "A long explanation with thirty turns."
        ], summary: "The owner's kite is Copper Finch.", recentTurns: [
            TurnRecord(transcript: "What color are its wings?", reply: "Its wings are gold.")
        ]))
        send(.provider(.searching))
        send(.replyLineRead)
        try await picture(root, directory: directory, name: "pending-after-search-cue")
        #expect(shownNotch == .thinking, "The owned notch must show progress after the intermediate search cue until a provider terminal event")
        if ProcessInfo.processInfo.environment["BUDDY_NOTCH_LIVE_CLAUDE"] == "1" {
            let environment = ProcessInfo.processInfo.environment
            let brain = ClaudeBrain { ClaudeLaunch.talk(environment: environment, workingDirectory: directory.path,
                                                       isExecutable: FileManager.default.isExecutableFile) }
            defer { brain.stop() }
            let submitted = try #require(request)
            let liveRequest = TurnRequest(transcript: submitted.transcript, captures: [],
                                      earlierSummaries: submitted.earlierSummaries, summary: submitted.summary,
                                      recentTurns: submitted.recentTurns)
            let events: [ProviderEvent] = await withCheckedContinuation { continuation in
                var events: [ProviderEvent] = []
                brain.send(liveRequest) { event in
                    events.append(event)
                    switch event {
                    case .completed, .failed: continuation.resume(returning: events)
                    default: break
                    }
                }
            }
            let reply = events.compactMap { if case .textDelta(let text) = $0 { text } else { nil } }.joined()
            #expect(reply.lowercased().contains("gold"))
            #expect(events.contains(.completed))
            try reply.write(to: directory.appending(path: "live-provider-answer.txt"), atomically: true, encoding: .utf8)
            for event in events { send(.provider(event)) }
        } else {
            send(.provider(.textDelta("Gold.")))
            send(.provider(.completed))
        }
        send(.replyLineRead)
        try await picture(root, directory: directory, name: "continued-thread")
        try await press("notch.history", in: root)
        try await press("notch.delete.1", in: root, history: engine.state.notchConversation.pastConversations)
        #expect(try store.load().conversations.map(\.id) == [3, 2, 0])
        #expect(try String(contentsOf: directory.appending(path: "fixture-history.json"), encoding: .utf8).contains("Silver Fern") == false)
        try await picture(root, directory: directory, name: "after-delete")
        try await press("notch.new", in: root)
        #expect(engine.state.notchConversation.entries == [])
        #expect(engine.state.notchConversation.focused == true)
        #expect(window.isKeyWindow == true)
        #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        try await picture(root, directory: directory, name: "new-conversation")
        send(.clearHistoryRequested)
        #expect(try store.load().conversations == [])
        send(.textBoxFocused)
        try await press("notch.history", in: root)
        #expect(engine.state.notchConversation.pastConversations == [])
        try await picture(root, directory: directory, name: "empty-history")
        let providerEvidence = ProcessInfo.processInfo.environment["BUDDY_NOTCH_LIVE_CLAUDE"] == "1" ? "liveClaude" : "injected"
        print("NOTCH_HISTORY_FIXTURE controls=list,back,open,delete,new,clear scroll=first,latest context=\(providerEvidence) capture=injected ownerData=false")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_NOTCH_EVIDENCE"] != nil))
    func sendingFromAnOlderPositionShowsTheNewQuestionAndStreamedAnswer() async throws {
        let hostObservation = try OwnedHostObservation.beginIfRequested()
        defer { hostObservation?.complete() }
        @MainActor
        final class OwnedConversationLayoutTrace {
            weak var root: NSView?
            private var sequence = 0
            private var invalid = false
            private var observers: [NSObjectProtocol] = []
            private var observedViews: [(view: NSView, frame: Bool, bounds: Bool)] = []

            func observe(_ scroll: NSScrollView) {
                let views: [NSView?] = [scroll.contentView, scroll.documentView]
                for view in views.compactMap({ $0 }) {
                    observedViews.append((view, view.postsFrameChangedNotifications, view.postsBoundsChangedNotifications))
                    view.postsFrameChangedNotifications = true
                    view.postsBoundsChangedNotifications = true
                let role = view === scroll.contentView ? "clip" : "document"
                    for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                        observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: nil) { [weak self] _ in
                        MainActor.assumeIsolated { self?.record("native.\(role).\(name.rawValue)") }
                        })
                    }
                }
                record("native.observers-attached")
            }

            func stop() {
                for observer in observers { NotificationCenter.default.removeObserver(observer) }
                observers.removeAll()
                for saved in observedViews {
                    saved.view.postsFrameChangedNotifications = saved.frame
                    saved.view.postsBoundsChangedNotifications = saved.bounds
                }
                observedViews.removeAll()
            }

            func record(_ phase: String, observation: NotchConversationObservation? = nil) {
                guard !invalid else { return }
                guard sequence < 4096 else {
                    invalid = true
                    Issue.record("INVALID owned passive layout trace exceeded its 4096-observation cap")
                    return
                }
                sequence += 1
                func rectangle(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                var fields: [String: Any] = [
                    "sequence": sequence, "uptime": ProcessInfo.processInfo.systemUptime, "phase": phase,
                    "ownApplicationActive": NSApp.isActive,
                    "ownApplicationActivationPolicy": NSApp.activationPolicy().rawValue
                ]
                if let observation {
                    fields["modelRevisionAtCallback"] = observation.modelRevision
                    fields["entries"] = observation.entryCount
                    fields["focused"] = observation.focused
                    switch observation.strip {
                    case .thinking?: fields["strip"] = "thinking"
                    case .listening?: fields["strip"] = "listening"
                    case .line?: fields["strip"] = "line"
                    case .notice?: fields["strip"] = "notice"
                    case nil: fields["strip"] = "nil"
                    }
                    if let frame = observation.frame { fields["swiftUIFrame"] = rectangle(frame) }
                }
                if let root {
                    fields["rootFrame"] = rectangle(root.frame)
                    fields["key"] = root.window?.isKeyWindow ?? false
                    fields["responder"] = root.window?.firstResponder.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
                    fields["fieldEditor"] = (root.window?.firstResponder as? NSTextView)?.isFieldEditor == true
                    if let window = root.window {
                        fields["ownedWindowID"] = String(describing: ObjectIdentifier(window))
                        fields["ownedWindowType"] = String(describing: type(of: window))
                        fields["ownedWindowCanBecomeKey"] = window.canBecomeKey
                        fields["ownedWindowCanBecomeMain"] = window.canBecomeMain
                        fields["ownedWindowVisible"] = window.isVisible
                        fields["ownedWindowMiniaturized"] = window.isMiniaturized
                        if let panel = window as? NSPanel {
                            fields["ownedPanelBecomesKeyOnlyIfNeeded"] = panel.becomesKeyOnlyIfNeeded
                        }
                    }
                    if let input = root.subviews.compactMap({ $0 as? NSTextField }).first {
                        fields["inputFrame"] = rectangle(input.frame)
                        fields["inputHidden"] = input.isHidden
                        fields["inputEnabled"] = input.isEnabled
                        fields["inputAcceptsFirstResponder"] = input.acceptsFirstResponder
                        fields["inputWindowMatchesOwnedWindow"] = input.window === root.window
                        let currentEditor = input.currentEditor()
                        fields["inputCurrentEditorID"] = currentEditor.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
                        fields["inputCurrentEditorIsResponder"] = currentEditor != nil && currentEditor === root.window?.firstResponder
                    }
                    if let scroll = descendants(root).compactMap({ $0 as? NSScrollView }).first {
                        fields["scrollID"] = String(describing: ObjectIdentifier(scroll))
                        fields["scrollFrame"] = rectangle(scroll.frame)
                        fields["clipBounds"] = rectangle(scroll.contentView.bounds)
                        fields["documentVisibleRect"] = rectangle(scroll.documentVisibleRect)
                        if let document = scroll.documentView {
                            fields["documentID"] = String(describing: ObjectIdentifier(document))
                            fields["documentFrame"] = rectangle(document.frame)
                            fields["documentBounds"] = rectangle(document.bounds)
                            fields["documentFlipped"] = document.isFlipped
                        }
                    }
                }
                do {
                    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
                    print("NOTCH_SEND_LAYOUT \(String(decoding: data, as: UTF8.self))")
                } catch {
                    invalid = true
                    Issue.record("INVALID owned passive layout trace serialization failure: \(error)")
                }
            }
        }

        let evidence = URL(filePath: try #require(ProcessInfo.processInfo.environment["BUDDY_NOTCH_EVIDENCE"]), directoryHint: .isDirectory)
        let directory = evidence.appending(path: "send-from-older", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let turns = (1...30).map { number in
            TurnRecord(transcript: "Long conversation question \(number)",
                       reply: "Answer \(number). This explanation stays readable while scrolling through earlier turns.")
        }
        let store = HistoryStore(url: directory.appending(path: "fixture-history.json"))
        try store.save(ConversationHistory(conversations: [Conversation(
            turns: turns, lastActivity: date.addingTimeInterval(-200), endedAt: date.addingTimeInterval(-190),
            summary: ConversationSummary(text: "The first twenty-nine saved turns describe a long explanation.", turns: 29)
        )]))
        let layoutTrace = OwnedConversationLayoutTrace()
        defer { layoutTrace.stop() }
        let notch = NotchPanel(microphone: MicrophoneLevel(), observesEnvironment: false,
                              onConversationObservation: { layoutTrace.record($0.phase, observation: $0) })
        var engine = BuddyEngine(providerConnected: true, history: try store.load(), spokenReplies: false, now: { date })
        var request: TurnRequest?
        var submissions: [String] = []
        var inputEvents: [String] = []
        func send(_ event: BuddyEngine.Event) {
            let eventName = String(describing: event).split(separator: "(", maxSplits: 1).first.map(String.init) ?? "unknown"
            layoutTrace.record("event.\(eventName).before-engine")
            if case .textBoxSubmitted(let words) = event { submissions.append(words) }
            switch event {
            case .textBoxFocused: inputEvents.append("focused")
            case .textBoxDismissed: inputEvents.append("dismissed")
            case .textBoxChanged(let words): inputEvents.append("changed:\(words)")
            case .textBoxSubmitted(let words): inputEvents.append("submitted:\(words)")
            default: break
            }
            let effects = engine.handle(event)
            let turnName = String(describing: engine.state.turn).split(separator: "(", maxSplits: 1).first.map(String.init) ?? "unknown"
            layoutTrace.record("event.\(eventName).after-engine entries=\(engine.state.notchConversation.entries.count) focused=\(engine.state.notchConversation.focused) turn=\(turnName)")
            notch.update(engine.state.notchConversation)
            layoutTrace.record("event.\(eventName).after-panel-update")
            for effect in effects {
                let effectName = String(describing: effect).split(separator: "(", maxSplits: 1).first.map(String.init) ?? "unknown"
                layoutTrace.record("effect.\(effectName).before")
                switch effect {
                case .saveHistory(let history):
                    do { try store.save(history) }
                    catch { Issue.record("Owned send fixture failed: \(error)") }
                case .showTextBox: notch.focusTextBox()
                case .hideTextBox: notch.releaseTextBox()
                case .showNotch(let value): notch.show(value)
                case .sendTurn(let turn): request = turn
                default: break
                }
                layoutTrace.record("effect.\(effectName).returned")
            }
        }
        let previousWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
        notch.start(onEvent: send)
        defer { notch.stop() }
        let ownedWindows = NSApp.windows.filter {
            !previousWindows.contains(ObjectIdentifier($0)) && String(describing: type(of: $0)) == "NotchWindow"
        }
        try #require(ownedWindows.count == 1, "The send fixture must create exactly one owned NotchWindow")
        let window = try #require(ownedWindows.first)
        let root = try #require(window.contentView)
        layoutTrace.root = root
        func traceFocus(_ stage: String, expectedEditor: NSTextView? = nil) {
            let responder = window.firstResponder
            let identity = responder.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
            let expectedIdentity = expectedEditor.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
            layoutTrace.record("focus.\(stage) engineFocused=\(engine.state.notchConversation.focused) expectedEditorID=\(expectedIdentity)")
            print("NOTCH_SEND_FOCUS stage=\(stage) engineFocused=\(engine.state.notchConversation.focused) key=\(window.isKeyWindow) responderID=\(identity) expectedEditorID=\(expectedIdentity) isFieldEditor=\((responder as? NSTextView)?.isFieldEditor == true) inputEvents=\(inputEvents)")
        }
        send(.notchPointerChanged(true))
        send(.textBoxFocused)
        try await press("notch.history", in: root)
        try await press("notch.open.0", in: root, history: engine.state.notchConversation.pastConversations)
        traceFocus("after-open")
        let scroll = try #require(descendants(root).compactMap { $0 as? NSScrollView }.first)
        layoutTrace.observe(scroll)
        let document = try #require(scroll.documentView)
        try #require(document.bounds.height > scroll.contentView.bounds.height)
        document.scroll(.zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        traceFocus("before-older-picture")
        try await picture(root, directory: directory, name: "older-before-send")
        traceFocus("after-older-picture")
        layoutTrace.record("fixture.final-focus.before")
        notch.focusTextBox()
        layoutTrace.record("fixture.final-focus.returned")
        root.layoutSubtreeIfNeeded()
        let editor = try #require(window.firstResponder as? NSTextView)
        traceFocus("after-final-focus", expectedEditor: editor)
        try #require(engine.state.notchConversation.focused)
        try #require(editor.isFieldEditor)
        let readyScroll = try #require(descendants(root).compactMap { $0 as? NSScrollView }.first)
        let older = try measureThreadEnd(in: readyScroll, latestReply: "Answer 30. This explanation stays readable while scrolling through earlier turns.", stage: "send-older-negative-control-after-final-focus")
        try #require(older.isAtLatestTurn == false && abs(older.semanticBottomGap) > 2 && !older.latestReplyFullyVisible,
                     "After final focus setup, submission must still start from an older viewport that excludes the latest saved answer")
        layoutTrace.record("checkpoint.older-after-final-focus")
        for (characters, keyCode) in [("x", UInt16(7)), ("\r", UInt16(36))] {
            traceFocus(characters == "x" ? "before-x" : "before-Return", expectedEditor: editor)
            try #require(window.isKeyWindow)
            try #require(window.firstResponder === editor)
            try #require(editor.isFieldEditor)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            NSApp.sendEvent(event)
            traceFocus(characters == "x" ? "after-x" : "after-Return", expectedEditor: editor)
            if characters == "x" { try #require(engine.state.notchConversation.draft == "x") }
        }
        try #require(submissions == ["x"], "Return must submit exactly once through the actual owned field")
        try #require(engine.state.turn == .capturing(transcript: "x"))
        try #require(engine.state.notchConversation.entries.last == .owner("x"))
        try #require(engine.state.notchConversation.isOpen)
        try await picture(root, directory: directory, name: "submitted-question")
        let submittedScroll = try #require(descendants(root).compactMap { $0 as? NSScrollView }.first)
        let submitted = try measureThreadEnd(in: submittedScroll, latestReply: "x", stage: "send-submitted-question", speaker: "You")
        layoutTrace.record("checkpoint.submitted-question")
        try #require(submitted.latestReplyFrame != nil || abs(submitted.semanticBottomGap) > 2,
                     "Content at the semantic end must have an owned accessibility frame")
        #expect(submitted.latestReplyFullyVisible, "Submitting from an older viewport must reveal the complete new question without a manual scroll")

        send(.screensCaptured([]))
        try #require(request == TurnRequest(transcript: "x", captures: [],
            summary: "The first twenty-nine saved turns describe a long explanation.", recentTurns: [
                TurnRecord(transcript: "Long conversation question 30", reply: "Answer 30. This explanation stays readable while scrolling through earlier turns.")
            ]))
        send(.provider(.textDelta("The new answer is visible.\n")))
        try #require(engine.state.notchConversation.entries.last == .buddy("The new answer is visible."))
        try await picture(root, directory: directory, name: "streamed-answer")
        let streamingScroll = try #require(descendants(root).compactMap { $0 as? NSScrollView }.first)
        let streaming = try measureThreadEnd(in: streamingScroll, latestReply: "The new answer is visible.", stage: "send-streamed-answer")
        layoutTrace.record("checkpoint.streamed-answer")
        try #require(streaming.latestReplyFrame != nil || abs(streaming.semanticBottomGap) > 2,
                     "Content at the semantic end must have an owned accessibility frame")
        #expect(streaming.latestReplyFullyVisible, "The complete streamed answer must become visible without a manual scroll")
        send(.provider(.completed))
        send(.replyLineRead)
        try #require(engine.state.turn == .idle)
        #expect(try store.load().conversations.first?.turns.last == TurnRecord(transcript: "x", reply: "The new answer is visible."))
        try await picture(root, directory: directory, name: "terminal-answer")
        let terminalScroll = try #require(descendants(root).compactMap { $0 as? NSScrollView }.first)
        let terminal = try measureThreadEnd(in: terminalScroll, latestReply: "The new answer is visible.", stage: "send-terminal-answer")
        layoutTrace.record("checkpoint.terminal-answer")
        try #require(terminal.latestReplyFrame != nil || abs(terminal.semanticBottomGap) > 2,
                     "Content at the semantic end must have an owned accessibility frame")
        #expect(terminal.latestReplyFullyVisible, "The complete terminal answer must remain visible without a manual scroll")
        print("NOTCH_SEND_FIXTURE input=owned-native-x-Return stages=older,submitted,streamed,terminal capture=injected provider=injected ownerData=false")
    }

    private struct OwnedHostObservation {
        let token: String
        let executable: String
        let pid: Int32
        let directory: URL

        static func beginIfRequested() throws -> Self? {
            let environment = ProcessInfo.processInfo.environment
            let keys = ["BUDDY_OWNED_HOST_TOKEN", "BUDDY_OWNED_HOST_EXECUTABLE", "BUDDY_OWNED_HOST_RECEIPT_DIR"]
            guard keys.contains(where: { environment[$0] != nil }) else { return nil }
            try #require(BuddyTestHostMode.isIsolated)
            let token = try #require(environment[keys[0]])
            try #require(token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
            let root = "/private/tmp/buddy-frontier-issue-61/owned-host-\(token)/"
            let expected = try #require(environment[keys[1]])
            let receiptDirectory = try #require(environment[keys[2]])
            try #require(expected.utf8.count <= 4096 && expected.hasPrefix(root)
                         && expected.hasSuffix("/Buddy.app/Contents/MacOS/Buddy"))
            let expectedURL = URL(fileURLWithPath: expected).standardizedFileURL.resolvingSymlinksInPath()
            try #require(expectedURL.path == expected)
            try #require(receiptDirectory == root + "receipts")
            let directory = URL(fileURLWithPath: receiptDirectory, isDirectory: true)
            try #require(directory.standardizedFileURL.resolvingSymlinksInPath().path == receiptDirectory)
            var capacity: UInt32 = 65536
            var buffer = [CChar](repeating: 0, count: Int(capacity))
            let result = buffer.withUnsafeMutableBufferPointer { _NSGetExecutablePath($0.baseAddress!, &capacity) }
            try #require(result == 0)
            let actual = URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.resolvingSymlinksInPath().path
            try #require(actual == expected)
            let pid = ProcessInfo.processInfo.processIdentifier
            try #require(pid > 0)
            for name in ["begin.json", "complete.json"] {
                try #require(!FileManager.default.fileExists(atPath: directory.appending(path: name).path))
            }
            let observation = Self(token: token, executable: actual, pid: pid, directory: directory)
            try observation.emit(phase: "begin", sequence: 1)
            return observation
        }

        private func emit(phase: String, sequence: Int) throws {
            let frame: [String: Any] = [
                "schema": 1, "fixture": "sendingFromAnOlderPositionShowsTheNewQuestionAndStreamedAnswer",
                "token": token, "executable": executable, "pid": pid, "phase": phase, "sequence": sequence
            ]
            let data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
            try data.write(to: directory.appending(path: phase == "begin" ? "begin.json" : "complete.json"),
                           options: [.withoutOverwriting])
            try FileHandle.standardOutput.write(contentsOf: Data("OWNED_HOST_OBSERVATION ".utf8) + data + Data([10]))
        }

        func complete() {
            do { try emit(phase: "complete", sequence: 2) }
            catch { Issue.record("INVALID owned host completion receipt: \(error)") }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private struct ThreadEndMeasurement {
        let rawBottomGap: CGFloat
        let viewport: NSRect
        let latestReplyFrame: NSRect?

        // The bottom scroll target precedes the thread's declared 14-point bottom padding.
        var semanticBottomGap: CGFloat { rawBottomGap - 14 }

        var latestReplyFullyVisible: Bool {
            guard let latestReplyFrame else { return false }
            return viewport.contains(latestReplyFrame)
        }

        var isAtLatestTurn: Bool { abs(semanticBottomGap) <= 2 && latestReplyFullyVisible }
    }

    private func measureThreadEnd(in scroll: NSScrollView, latestReply: String, stage: String, speaker: String = "Buddy") throws -> ThreadEndMeasurement {
        let document = try #require(scroll.documentView)
        let window = try #require(scroll.window)
        var seen = Set<ObjectIdentifier>()
        func replyElements(in element: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return [] }
            let labels = [element.accessibilityAttributeValue(.value), element.accessibilityAttributeValue(.title),
                          element.accessibilityAttributeValue(.description)].compactMap { $0 as? String }
            if labels.contains(where: { $0 == latestReply || $0 == "\(speaker), \(latestReply)" || $0 == "\(speaker)\n\(latestReply)" }) {
                return [element]
            }
            return (element.accessibilityAttributeValue(.children) as? [NSObject] ?? []).flatMap { replyElements(in: $0) }
        }
        let matches = replyElements(in: document)
        try #require(matches.count <= 1, "The exact latest saved reply must identify at most one owned accessibility element")
        let replyFrame: NSRect?
        if let element = matches.first {
            let position = try #require(element.accessibilityAttributeValue(.position) as? NSValue).pointValue
            let size = try #require(element.accessibilityAttributeValue(.size) as? NSValue).sizeValue
            try #require(position.x.isFinite && position.y.isFinite && size.width.isFinite && size.height.isFinite)
            try #require(size.width > 0 && size.height > 0)
            replyFrame = NSRect(origin: position, size: size)
        } else {
            replyFrame = nil
        }
        let measurement = ThreadEndMeasurement(
            rawBottomGap: document.isFlipped
                ? document.bounds.maxY - scroll.documentVisibleRect.maxY
                : scroll.documentVisibleRect.minY - document.bounds.minY,
            viewport: window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil)),
            latestReplyFrame: replyFrame
        )
        print("NOTCH_THREAD_END stage=\(stage) rawGap=\(measurement.rawBottomGap) semanticGap=\(measurement.semanticBottomGap) viewport=\(measurement.viewport) latestReplyFrame=\(String(describing: measurement.latestReplyFrame)) latestFullyVisible=\(measurement.latestReplyFullyVisible) atLatest=\(measurement.isAtLatestTurn)")
        return measurement
    }

    private func press(_ identifier: String, in root: NSView, history: [NotchConversation.HistoryItem] = []) async throws {
        func find(_ element: NSObject) -> NSObject? {
            if element.accessibilityAttributeValue(.identifier) as? String == identifier { return element }
            for child in element.accessibilityAttributeValue(.children) as? [NSObject] ?? [] {
                if let found = find(child) { return found }
            }
            return nil
        }
        root.layoutSubtreeIfNeeded()
        await Task.yield()
        if let element = find(root) {
            element.accessibilityPerformAction(.press)
        } else {
            let window = try #require(root.window)
            let controls = descendants(root).filter { String(describing: type(of: $0)) == "KeyViewProxy" }
                .sorted {
                    let left = $0.convert($0.bounds, to: nil)
                    let right = $1.convert($1.bounds, to: nil)
                    return abs(left.midY - right.midY) < 2 ? left.midX < right.midX : left.midY > right.midY
                }
            let index: Int
            switch identifier {
            case "notch.history", "notch.back": index = 0
            case "notch.new": index = 1
            default:
                let parts = identifier.split(separator: ".")
                let id = try #require(parts.last.flatMap { Int($0) })
                let row = try #require(history.firstIndex { $0.id == id })
                index = 2 + row * 2 + (parts[1] == "delete" ? 1 : 0)
            }
            #expect(controls.indices.contains(index), "Missing native owned control \(identifier)")
            guard controls.indices.contains(index) else { return }
            let target = controls[index]
            let bounds = target.convert(target.bounds, to: nil)
            window.ignoresMouseEvents = false
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: bounds.midX, y: bounds.midY), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ))
                window.sendEvent(event)
            }
            print("NOTCH_OWNED_NATIVE_PRESS \(identifier) bounds=\(bounds)")
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    private func picture(_ view: NSView, directory: URL, name: String) async throws {
        try await Task.sleep(for: .milliseconds(350))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: name + ".png"))
    }

    @Test func theFirstMouseClickInAReopenedConversationAcceptsTypingAndReturn() async throws {
        let notch = NotchPanel(microphone: MicrophoneLevel(), observesEnvironment: false)
        let date = Date(timeIntervalSince1970: 1_000)
        var engine = BuddyEngine(providerConnected: true, history: ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "Name my kite", reply: "Copper Finch.")],
                         lastActivity: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 110),
                         summary: ConversationSummary(text: "The kite is Copper Finch.", turns: 1)),
            Conversation(turns: [TurnRecord(transcript: "Current", reply: "Fern.")], lastActivity: date,
                         summary: ConversationSummary(text: "The plant is Fern.", turns: 1))
        ]), now: { date })
        var submitted: String?
        func send(_ event: BuddyEngine.Event) {
            if case .textBoxSubmitted(let text) = event { submitted = text }
            if case .textBoxFocused = event { print("NOTCH_FIRST_CLICK focus callback") }
            if case .textBoxDismissed = event { print("NOTCH_FIRST_CLICK dismissal callback") }
            let effects = engine.handle(event)
            notch.update(engine.state.notchConversation)
            for effect in effects {
                switch effect {
                case .showTextBox:
                    print("NOTCH_FIRST_CLICK focus effect")
                    notch.focusTextBox()
                case .hideTextBox: notch.releaseTextBox()
                case .showNotch(let value): notch.show(value)
                default: break
                }
            }
        }
        notch.start(onEvent: send)
        defer { notch.stop() }
        send(.notchPointerChanged(true))
        send(.textBoxFocused)
        await Task.yield()
        let window = try #require(NSApp.keyWindow)
        let input = try #require(window.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
        send(.conversationsRequested)
        send(.conversationOpened(0))
        #expect(engine.state.notchConversation.focused == false)
        #expect(window.isKeyWindow == false)
        #expect(input.isHidden == false)
        window.contentView?.layoutSubtreeIfNeeded()
        window.ignoresMouseEvents = false
        let bounds = input.convert(input.bounds, to: nil)
        print("NOTCH_FIRST_CLICK before owned mouse click")
        let mouseEvents = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: bounds.midX, y: bounds.midY), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
        }
        // NSTextField tracks the click synchronously, so its own mouse-up must already be queued.
        NSApp.postEvent(mouseEvents[1], atStart: true)
        window.sendEvent(mouseEvents[0])
        print("NOTCH_FIRST_CLICK after owned mouse click")
        await Task.yield()
        #expect(engine.state.notchConversation.isOpen == true)
        #expect(engine.state.notchConversation.focused == true)
        #expect(window.isKeyWindow == true)
        #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        for (characters, keyCode) in [("x", UInt16(7)), ("\r", UInt16(36))] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            NSApp.sendEvent(event)
            if characters == "x" {
                #expect(engine.state.notchConversation.draft == "x")
                #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
                print("NOTCH_FIRST_CLICK typed x")
            }
        }
        print("NOTCH_FIRST_CLICK Return submitted")
        #expect(submitted == "x")
        #expect(engine.handle(.screensCaptured([])) == [.sendTurn(TurnRequest(
            transcript: "x", captures: [], earlierSummaries: ["The plant is Fern."], summary: "The kite is Copper Finch."
        ))])
    }

    @Test func historyHidesTheFieldAndAReopenedConversationAcceptsNativeReturn() async throws {
        let notch = NotchPanel(microphone: MicrophoneLevel(), observesEnvironment: false)
        let date = Date(timeIntervalSince1970: 1_000)
        var engine = BuddyEngine(providerConnected: true, history: ConversationHistory(conversations: [
            Conversation(turns: [TurnRecord(transcript: "My kite", reply: "Copper Finch.")],
                         lastActivity: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 110),
                         summary: ConversationSummary(text: "The kite is Copper Finch.", turns: 1)),
            Conversation(turns: [TurnRecord(transcript: "Current", reply: "Fern.")], lastActivity: date)
        ]), now: { date })
        var submitted: String?
        notch.start { event in
            if case .textBoxSubmitted(let text) = event { submitted = text }
            _ = engine.handle(event)
            notch.update(engine.state.notchConversation)
        }
        defer { notch.stop() }
        _ = engine.handle(.textBoxFocused)
        notch.update(engine.state.notchConversation)
        notch.focusTextBox()
        await Task.yield()
        let window = try #require(NSApp.keyWindow)
        let input = try #require(window.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(input.isHidden == false)
        _ = engine.handle(.conversationsRequested)
        notch.update(engine.state.notchConversation)
        #expect(input.isHidden == true)
        #expect(window.isKeyWindow == false)
        _ = engine.handle(.conversationThreadRequested)
        notch.update(engine.state.notchConversation)
        #expect(input.isHidden == false)
        #expect(engine.state.notchConversation.entries == [.owner("Current"), .buddy("Fern.")])
        _ = engine.handle(.conversationOpened(0))
        _ = engine.handle(.textBoxFocused)
        notch.update(engine.state.notchConversation)
        notch.focusTextBox()
        await Task.yield()
        for (characters, keyCode) in [("x", UInt16(7)), ("\r", UInt16(36))] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            NSApp.sendEvent(event)
        }
        #expect(submitted == "x")
        let capture = ScreenCapture(jpeg: Data([1, 2, 3]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
                                    pixelWidth: 1280, pixelHeight: 800, containsCursor: true)
        #expect(engine.handle(.screensCaptured([capture])) == [.sendTurn(TurnRequest(
            transcript: "x", captures: [capture], summary: "The kite is Copper Finch."
        ))])
    }

    @Test func theInlineFieldAcceptsTypingAfterOpeningAndReopening() async throws {
        let notch = NotchPanel(microphone: MicrophoneLevel(), observesEnvironment: false)
        let prior = TurnRecord(transcript: "Where is Settings?", reply: "Click the gear.")
        let date = Date(timeIntervalSince1970: 1_000)
        var engine = BuddyEngine(providerConnected: true, history: ConversationHistory(conversations: [
            Conversation(turns: [prior], lastActivity: date)
        ]), now: { date })
        var submitted: String?
        var submissionEffects: [BuddyEngine.Effect] = []
        notch.start { event in
            if case .textBoxSubmitted(let text) = event { submitted = text }
            let effects = engine.handle(event)
            if case .textBoxSubmitted = event { submissionEffects = effects }
            notch.update(engine.state.notchConversation)
        }
        defer { notch.stop() }

        for attempt in 0..<2 {
            let opening: [BuddyEngine.Effect]
            if attempt == 0 {
                let taps: [BuddyEngine.Event] = [
                    .modifiersChanged(.control, at: .milliseconds(0)), .modifiersChanged([], at: .milliseconds(100)),
                    .modifiersChanged(.control, at: .milliseconds(250)), .modifiersChanged([], at: .milliseconds(350))
                ]
                opening = taps.flatMap { engine.handle($0) }
            } else {
                _ = engine.handle(.shortcutChosen(.textBox, .held([.shift, .command])))
                opening = engine.handle(.modifiersChanged([.shift, .command], at: .milliseconds(1000)))
            }
            #expect(opening == [.hideBuddy, .showTextBox])
            #expect(engine.state.notchConversation.isOpen == true)
            #expect(engine.state.notchConversation.focused == true)
            notch.update(engine.state.notchConversation)
            notch.focusTextBox()
            await Task.yield()
            let window = try #require(NSApp.keyWindow)
            window.contentView?.layoutSubtreeIfNeeded()
            let editor = try #require(window.firstResponder as? NSTextView)
            #expect(editor.isFieldEditor)
            for (characters, keyCode) in [("x", UInt16(7)), ("\r", UInt16(36))] {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: keyCode
                ))
                NSApp.sendEvent(event)
            }
            #expect(submitted == "x")
            #expect(submissionEffects == [.hideTextBox, .showBuddy, .showNotch(.thinking), .captureScreens])
            let image = ScreenCapture(
                jpeg: Data([1, 2, 3]), display: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
                pixelWidth: 1280, pixelHeight: 800, containsCursor: true
            )
            #expect(engine.handle(.screensCaptured([image])) == [.sendTurn(TurnRequest(
                transcript: "x", captures: [image], recentTurns: [TurnRecord(transcript: "Where is Settings?", reply: "Click the gear.")]
            ))])
            _ = engine.handle(.interrupted)
            notch.update(engine.state.notchConversation)
            #expect(!window.isKeyWindow)
            submitted = nil
        }
    }
}
