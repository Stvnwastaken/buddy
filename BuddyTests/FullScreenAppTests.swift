import CoreGraphics
import Testing
@testable import Buddy

/// Window lists recorded from the window server on a 14-inch MacBook Pro, whose 1329-point display has a 39-point menu
/// bar around its camera housing, with the Dock hidden.
@MainActor
struct FullScreenAppTests {
    private let display = CGRect(x: 0, y: 0, width: 2056, height: 1329)
    private let buddy: pid_t = 63_119

    private func window(_ owner: pid_t, _ bounds: CGRect, layer: Int = 0, alpha: Double = 1) -> OnScreenWindow {
        OnScreenWindow(owner: owner, layer: layer, alpha: alpha, bounds: bounds)
    }

    private var menuBar: OnScreenWindow { window(175, CGRect(x: 0, y: 0, width: 2056, height: 39), layer: 24) }
    private var betterDisplay: OnScreenWindow { window(3204, CGRect(x: 0, y: 1328, width: 1, height: 1), alpha: 0) }

    @Test func anAppInFullScreenBelowTheCameraHousingCoversTheDisplay() {
        let windows = [
            window(23_978, CGRect(x: 0, y: 0, width: 2056, height: 71), layer: 26, alpha: 0), menuBar,
            window(23_978, CGRect(x: 0, y: 39, width: 2056, height: 32)),
            window(23_978, CGRect(x: 0, y: 39, width: 2056, height: 1290)), betterDisplay
        ]
        #expect(OnScreenWindow.fullScreenApp(in: windows, covers: display, below: 39, ignoring: buddy))
    }

    @Test func zoomedWindowsOfSeveralAppsOnTheDesktopDoNot() {
        let windows = [
            menuBar,
            window(86_256, CGRect(x: 0, y: 39, width: 2056, height: 1290)),
            window(58_058, CGRect(x: 0, y: 39, width: 2056, height: 1290)),
            window(7201, CGRect(x: 164, y: 142, width: 1728, height: 1084)),
            window(buddy, CGRect(x: 838, y: 176, width: 397, height: 742)), betterDisplay
        ]
        #expect(!OnScreenWindow.fullScreenApp(in: windows, covers: display, below: 39, ignoring: buddy))
    }

    @Test func aZoomedAppAloneOnTheDesktopLooksTheSameAndAlsoHidesTheIcon() {
        let windows = [
            menuBar, window(86_256, CGRect(x: 0, y: 39, width: 2056, height: 1290)),
            window(buddy, CGRect(x: 838, y: 176, width: 397, height: 742))
        ]
        #expect(OnScreenWindow.fullScreenApp(in: windows, covers: display, below: 39, ignoring: buddy))
    }

    @Test func aSmallerWindowAloneDoesNot() {
        let windows = [menuBar, window(7201, CGRect(x: 164, y: 142, width: 1728, height: 1084))]
        #expect(!OnScreenWindow.fullScreenApp(in: windows, covers: display, below: 39, ignoring: buddy))
    }

    @Test func aBorderlessGameOverTheWholeExternalDisplayCovers() {
        let external = CGRect(x: 2056, y: -200, width: 2560, height: 1440)
        let windows = [
            window(86_256, CGRect(x: 0, y: 39, width: 2056, height: 1290)),
            window(7201, CGRect(x: 164, y: 142, width: 1728, height: 1084)),
            window(4242, external)
        ]
        #expect(OnScreenWindow.fullScreenApp(in: windows, covers: external, below: 25, ignoring: buddy))
        #expect(!OnScreenWindow.fullScreenApp(in: windows, covers: display, below: 39, ignoring: buddy))
    }
}
