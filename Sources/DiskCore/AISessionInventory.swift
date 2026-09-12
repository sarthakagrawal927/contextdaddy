import Darwin
import Foundation

public enum AISessionProvider: String, CaseIterable, Sendable {
    case claude = "Claude"
    case codex = "Codex"
}

public struct AISessionRecord: Identifiable, Sendable, Equatable {
    public let path: String
    public let provider: AISessionProvider
    public let isArchived: Bool
    public let project: String?
    public let sessionID: String?
    public let modified: Date
    public let allocatedBytes: Int64
    public let logicalBytes: Int64

    public var id: String { path }

    public var historyIdentifier: String {
        if let value = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    public var shortHistoryIdentifier: String {
        let value = historyIdentifier
        return value.count > 22 ? String(value.prefix(12)) + "…" + String(value.suffix(6)) : value
    }

    public func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [provider.rawValue, project ?? "Unknown project", historyIdentifier, URL(fileURLWithPath: path).lastPathComponent]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

public struct AISessionInventoryCoverage: Sendable, Equatable {
    public let roots: [String]
    public let existingRoots: [String]
    public let missingRoots: [String]
    public let visitedEntries: Int
    public let unreadableCount: Int
    public let skippedLinks: Int
    public let entryLimitReached: Bool
    public let sessionLimitReached: Bool

    public var isPartial: Bool {
        unreadableCount > 0 || skippedLinks > 0 || entryLimitReached || sessionLimitReached
    }
}

public struct AISessionInventoryReport: Sendable, Equatable {
    public let sessions: [AISessionRecord]
    public let coverage: AISessionInventoryCoverage
    public let elapsed: TimeInterval
}

public enum AISessionInventory {
    public struct Limits: Sendable, Equatable {
        public var maximumEntries: Int
        public var maximumSessions: Int

        public init(maximumEntries: Int = 250_000, maximumSessions: Int = 20_000) {
            self.maximumEntries = max(1, maximumEntries)
            self.maximumSessions = max(1, maximumSessions)
        }
    }

    public struct Configuration: Sendable {
        public var home: URL
        public var limits: Limits

        public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, limits: Limits = Limits()) {
            self.home = home
            self.limits = limits
        }
    }

    private struct Root {
        let url: URL
        let provider: AISessionProvider
        let archived: Bool
    }

    /// Inventories only the standard Claude and Codex session locations. Directory
    /// traversal and results are bounded, discovered symlink entries are skipped, and the
    /// bounded metadata reader never retains prompts or messages.
    public static func discover(configuration: Configuration = Configuration()) throws -> AISessionInventoryReport {
        let started = ContinuousClock.now
        let roots = [
            Root(url: configuration.home.appendingPathComponent(".claude/projects", isDirectory: true), provider: .claude, archived: false),
            Root(url: configuration.home.appendingPathComponent(".codex/sessions", isDirectory: true), provider: .codex, archived: false),
            Root(url: configuration.home.appendingPathComponent(".codex/archived_sessions", isDirectory: true), provider: .codex, archived: true),
        ]
        var pending: [Root] = []
        var sessions: [AISessionRecord] = []
        var visited = 0
        var unreadable = 0
        var skippedLinks = 0
        var entryLimitReached = false
        var sessionLimitReached = false
        var existingRoots: [String] = []
        var missingRoots: [String] = []

        for root in roots {
            var info = stat()
            if lstat(root.url.path, &info) != 0 {
                if errno == ENOENT {
                    missingRoots.append(root.url.path)
                } else {
                    unreadable += 1
                }
                continue
            }
            guard !hasSymlinkComponent(root.url.path), info.st_mode & S_IFMT == S_IFDIR else {
                skippedLinks += 1
                continue
            }
            existingRoots.append(root.url.path)
            pending.append(root)
        }

        while let directory = pending.popLast() {
            try Task.checkCancellation()
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory.url,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                unreadable += 1
                continue
            }
            for child in children {
                try Task.checkCancellation()
                if visited >= configuration.limits.maximumEntries {
                    entryLimitReached = true
                    pending.removeAll()
                    break
                }
                visited += 1
                var info = stat()
                guard lstat(child.path, &info) == 0 else {
                    unreadable += 1
                    continue
                }
                let type = info.st_mode & S_IFMT
                if type == S_IFLNK {
                    skippedLinks += 1
                    continue
                }
                if type == S_IFDIR {
                    pending.append(Root(url: child, provider: directory.provider, archived: directory.archived))
                    continue
                }
                guard type == S_IFREG, child.pathExtension.lowercased() == "jsonl" else { continue }
                guard sessions.count < configuration.limits.maximumSessions else {
                    sessionLimitReached = true
                    continue
                }
                let details = AISessionDetails.read(url: child, tool: directory.provider.rawValue)
                sessions.append(AISessionRecord(
                    path: child.path,
                    provider: directory.provider,
                    isArchived: directory.archived,
                    project: details.project,
                    sessionID: details.sessionID,
                    modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000),
                    allocatedBytes: Int64(info.st_blocks) * 512,
                    logicalBytes: Int64(info.st_size)
                ))
            }
        }

        sessions.sort {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        let duration = started.duration(to: .now)
        let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return AISessionInventoryReport(
            sessions: sessions,
            coverage: AISessionInventoryCoverage(
                roots: roots.map(\.url.path),
                existingRoots: existingRoots,
                missingRoots: missingRoots,
                visitedEntries: visited,
                unreadableCount: unreadable,
                skippedLinks: skippedLinks,
                entryLimitReached: entryLimitReached,
                sessionLimitReached: sessionLimitReached
            ),
            elapsed: elapsed
        )
    }

    private static func hasSymlinkComponent(_ path: String) -> Bool {
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            var info = stat()
            guard lstat(current, &info) == 0 else { return true }
            if info.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }
}
