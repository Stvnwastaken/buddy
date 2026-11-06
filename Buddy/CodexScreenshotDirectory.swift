import Foundation

/// Each manager owns one directory. Constructing or releasing another manager cannot remove its images.
final class CodexScreenshotDirectory {
    let url: URL

    init(root: URL) {
        url = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
