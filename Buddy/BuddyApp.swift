import SwiftUI

@main
struct BuddyApp: App {
    @NSApplicationDelegateAdaptor(BuddyAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.showSettingsWindow() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

enum BuddyTestHostMode {
#if BUDDY_ISOLATED_TEST_HOST
    static let isIsolated = true
#else
    static let isIsolated = false
#endif
}

#if BUDDY_ISOLATED_TEST_HOST
@MainActor
final class BuddyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showSettingsWindow() {}
}
#else
@MainActor
final class BuddyAppDelegate: NSObject, NSApplicationDelegate {
    private let manager = CompanionManager()
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        settingsWindow = SettingsWindowController(manager: manager)
        // As the host of the app's tests, Buddy must not start Claude or summarize the owner's saved history.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { manager.start() }
        showSettingsWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showSettingsWindow() {
        settingsWindow?.showSettings()
    }
}
#endif
