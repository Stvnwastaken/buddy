import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let manager: CompanionManager

    init(manager: CompanionManager) {
        self.manager = manager
        let available = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: min(710, available.height - 80)),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "Buddy"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            ScrollView { CompanionPanelView(manager: manager) }
                .background(DS.Colors.background)
        )
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        manager.refreshSystemState()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
