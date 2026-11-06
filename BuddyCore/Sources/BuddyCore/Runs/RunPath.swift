import Foundation

/// Resolves existing symlinks even when the file being created does not exist yet.
public enum RunPath {
    public static func resolve(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        var remaining = path.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var links = 0
        while !remaining.isEmpty {
            let part = remaining.removeFirst()
            if part == "." { continue }
            if part == ".." {
                _ = resolved.popLast()
                continue
            }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                links += 1
                guard links <= 40 else { return nil }
                if target.hasPrefix("/") { resolved = [] }
                remaining = target.split(separator: "/").map(String.init) + remaining
            } else {
                resolved.append(part)
            }
        }
        return "/" + resolved.joined(separator: "/")
    }
}
