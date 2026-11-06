import AppKit
import BuddyCore
import Carbon.HIToolbox

/// Types text for the owner: a click into the field at a spot, then Command-V from a pasteboard item that clipboard
/// managers skip, then the owner's clipboard put back. While secure input is on, as in a password field, it types
/// nothing. Requests run one after another, so one paste never overwrites the clipboard another is still restoring.
final class PasteInserter: Inserter {
    /// Set on every event Buddy posts, so the event tap can tell them from the owner's own input.
    nonisolated static let postedEventMarker: Int64 = 0x4255_4459

    private var queue: Task<Void, Never>?
    private var generation = 0

    func type(_ text: String, at spot: DisplayPoint, onRefused: @escaping () -> Void) {
        let previous = queue
        let requested = generation
        queue = Task { [weak self] in
            await previous?.value
            guard let self, generation == requested else { return }
            guard await paste(text, at: spot, requested: requested) else { return onRefused() }
        }
    }

    func cancelPending() {
        generation += 1
    }

    /// Returns false only when secure input refused the text.
    private func paste(_ text: String, at spot: DisplayPoint, requested: Int) async -> Bool {
        guard !IsSecureEventInputEnabled() else { return false }
        click(at: spot)
        try? await Task.sleep(for: .milliseconds(150))
        guard generation == requested else { return true }
        // The click may have focused a password field.
        guard !IsSecureEventInputEnabled() else { return false }

        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map(Self.copy)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
        let pasted = pasteboard.changeCount
        pressCommandV()

        // The app reads the pasteboard when it handles Command-V, which can take a moment.
        try? await Task.sleep(for: .milliseconds(500))
        guard pasteboard.changeCount == pasted else { return true }
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        return true
    }

    private func click(at spot: DisplayPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: spot.quartz, mouseButton: .left))
        }
    }

    private func pressCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
            event?.flags = .maskCommand
            post(event)
        }
    }

    private func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: Self.postedEventMarker)
        event?.post(tap: .cghidEventTap)
    }

    private static func copy(_ item: NSPasteboardItem) -> NSPasteboardItem {
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    }
}

extension DisplayPoint {
    // Quartz event locations count y down from the top of the main display, AppKit up from its bottom.
    private static var mainHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }

    init(quartz location: CGPoint) {
        self.init(x: location.x, y: Self.mainHeight - location.y)
    }

    var quartz: CGPoint { CGPoint(x: x, y: Self.mainHeight - y) }
}
