import Testing
@testable import Buddy

@MainActor
struct OverlayBesideTests {
    @Test func duringATakeoverTheWayToTakeBackControlWinsOverAPointsLabel() {
        let presence = BuddyPresence()
        presence.label = "Open Apps"
        #expect(presence.beside == .label("Open Apps"))

        presence.takingOver = true
        #expect(presence.beside == .takingOver)
        #expect(BuddyPresence.takingOverText == "Using your mouse and keyboard. Press Esc to take back control.")

        presence.takingOver = false
        #expect(presence.beside == .label("Open Apps"))
    }

    @Test func withoutALabelOrATakeoverNothingSitsBesideTheBuddy() {
        #expect(BuddyPresence().beside == nil)
    }
}
