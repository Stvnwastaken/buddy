import Foundation
import Testing
import BuddyCore

private func capture(cursor: Bool) -> ScreenCapture {
    ScreenCapture(
        jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1512, height: 982),
        pixelWidth: 1280, pixelHeight: 827, containsCursor: cursor
    )
}

struct RunBriefTests {
    @Test func briefDocumentNamesTheRequestAndTheSavedScreens() {
        let brief = RunBrief(request: "make a folder on my Desktop", captures: [capture(cursor: false), capture(cursor: true)])
        #expect(brief.document == """
        # Brief

        The owner asked: make a folder on my Desktop

        Screens when they asked: screen-1.jpg, screen-2.jpg (with the cursor).

        """)
    }

    @Test func briefDocumentWithoutScreensHasOnlyTheRequest() {
        #expect(RunBrief(request: "list my open apps", captures: []).document == "# Brief\n\nThe owner asked: list my open apps\n")
    }
}
