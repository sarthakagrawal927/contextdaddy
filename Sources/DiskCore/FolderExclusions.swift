import Foundation

/// Folder paths only, never glob patterns. Resolve aliases once per operation,
/// keeping traversal checks free of extra filesystem calls.
public struct FolderExclusions: Sendable {
    public let paths: [String]
    private let matches: Set<String>

    public init(paths: [String] = []) {
        self.paths = Array(Set(paths.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })).sorted()
        self.matches = Set(self.paths.flatMap { path in
            [Self.volumePath(path), Self.volumePath(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)]
        })
    }

    public func contains(_ path: String) -> Bool {
        guard !matches.isEmpty else { return false }
        var candidate = Self.volumePath(path)
        while true {
            if matches.contains(candidate) { return true }
            if candidate == "/" { return false }
            guard let slash = candidate.lastIndex(of: "/") else { return false }
            candidate = slash == candidate.startIndex ? "/" : String(candidate[..<slash])
        }
    }

    /// A parent move includes its excluded descendants, even if they were not scanned.
    public func blocksCleanup(_ url: URL) -> Bool {
        guard !matches.isEmpty else { return false }
        let candidates = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path].map(Self.volumePath)
        return candidates.contains { candidate in
            contains(candidate) || matches.contains { $0.hasPrefix(candidate == "/" ? "/" : candidate + "/") }
        }
    }

    private static func volumePath(_ path: String) -> String {
        let prefix = "/System/Volumes/Data"
        if path == prefix { return "/" }
        return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
    }
}
