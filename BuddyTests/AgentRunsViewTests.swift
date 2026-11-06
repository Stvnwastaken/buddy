import AppKit
import BuddyCore
import SwiftUI
import Testing
@testable import Buddy

@MainActor
struct AgentRunsViewTests {
    @Test func clickingASegmentChoosesThatCLIOrModeForNewRuns() throws {
        var choices: [ProviderChoice] = []
        var modes: [ApprovalMode] = []
        let view = AgentRunsView(choice: .auto, mode: .auto, chooseProvider: { choices.append($0) }, chooseMode: { modes.append($0) })
        let host = NSHostingView(rootView: view.frame(width: 336))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 336, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let controls = Self.segmentedControls(in: host)
        #expect(controls.map { control in (0..<control.segmentCount).map { control.label(forSegment: $0) } } == [
            ["Auto", "Claude", "Codex"], ["Auto", "Approve only", "YOLO"]
        ])
        #expect(controls.map(\.selectedSegment) == [0, 0])

        click(controls[0], segment: 2)
        click(controls[0], segment: 0)
        click(controls[1], segment: 2)
        click(controls[1], segment: 1)
        #expect(choices == [.codex, .auto])
        #expect(modes == [.yolo, .approveOnly])
    }

    private func click(_ control: NSSegmentedControl, segment: Int) {
        control.selectedSegment = segment
        control.sendAction(control.action, to: control.target)
    }

    private static func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        if let control = view as? NSSegmentedControl { return [control] }
        return view.subviews.flatMap(segmentedControls)
    }
}
