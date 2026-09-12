import Foundation
import CryptoKit
import Darwin

public struct ArchivedSource: Codable, Sendable, Equatable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    func matches(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && UInt64(info.st_dev) == device && UInt64(info.st_ino) == inode &&
        info.st_size == size && info.st_mtimespec.tv_sec == modifiedSeconds &&
        info.st_mtimespec.tv_nsec == modifiedNanoseconds && info.st_ctimespec.tv_sec == changedSeconds &&
        info.st_ctimespec.tv_nsec == changedNanoseconds
    }
}

public struct VerifiedArchiveCleanup: Sendable {
    public struct Item: Sendable {
        public let source: ArchivedSource
        let digest: Data
    }
    public let archive: URL
    public let items: [Item]
    public let archiveDigest: Data
    let archiveIdentity: ArchivedSource
    public var sourceBytes: Int64 { items.reduce(0) { $0 + $1.source.size } }
}

public enum ArchiveCleanupError: Error, LocalizedError {
    case missingManifest, unsafeSource, changed, invalidZIP
    public var errorDescription: String? {
        switch self {
        case .missingManifest: "This export has no verifiable source list. Export again before reviewing originals."
        case .unsafeSource: "A source is outside the supported session folders or is not a regular, unchanged session file. Nothing moved."
        case .changed: "The archive or an original has changed since export. Export again before cleaning up."
        case .invalidZIP: "The saved ZIP failed its integrity check. Originals cannot be cleaned up from this export."
        }
    }
}

public enum ArchiveCleanupVerifier {
    /// No directory candidates. No discovery during cleanup: only files the helper
    /// reports as contributing conversations to this specific export are eligible.
    public static func prepare(receipt: ConversationArchiveReceipt, archive: URL, cutoff: Date,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> VerifiedArchiveCleanup {
        guard let sources = receipt.sources, !sources.isEmpty, sources.count <= receipt.sourceFiles,
              Set(sources.map(\.path)).count == sources.count else { throw ArchiveCleanupError.missingManifest }
        try ArchivePublisher.validateDestination(archive)
        var archiveInfo = stat()
        guard lstat(archive.path, &archiveInfo) == 0 else { throw ArchiveCleanupError.changed }
        let identity = ArchivedSource(path: archive.path, device: UInt64(archiveInfo.st_dev), inode: UInt64(archiveInfo.st_ino),
            size: archiveInfo.st_size, modifiedSeconds: Int64(archiveInfo.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(archiveInfo.st_mtimespec.tv_nsec), changedSeconds: Int64(archiveInfo.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(archiveInfo.st_ctimespec.tv_nsec))
        let archiveDigest = try digest(archive, expected: identity)
        try verifyZIP(archive)
        guard try digest(archive, expected: identity) == archiveDigest else { throw ArchiveCleanupError.changed }
        let items = try sources.map { source in
            try validateLocation(source, home: home)
            guard source.size >= 0, Double(source.modifiedSeconds) + Double(source.modifiedNanoseconds) / 1e9 < cutoff.timeIntervalSince1970 else {
                throw ArchiveCleanupError.unsafeSource
            }
            return VerifiedArchiveCleanup.Item(source: source, digest: try digest(URL(fileURLWithPath: source.path), expected: source))
        }
        return VerifiedArchiveCleanup(archive: archive, items: items, archiveDigest: archiveDigest, archiveIdentity: identity)
    }

    @discardableResult
    public static func validateArchive(_ plan: VerifiedArchiveCleanup) throws -> VerifiedArchiveCleanup {
        try ArchivePublisher.validateDestination(plan.archive)
        return try refreshArchiveIdentity(plan)
    }

    @discardableResult
    public static func validateArchiveIdentity(_ plan: VerifiedArchiveCleanup) throws -> VerifiedArchiveCleanup {
        try ArchivePublisher.validateDestination(plan.archive)
        var info = stat()
        guard lstat(plan.archive.path, &info) == 0 else { throw ArchiveCleanupError.changed }
        if plan.archiveIdentity.matches(info) { return plan }
        // Finder and macOS security metadata can update ctime/xattrs without
        // changing the archive bytes. A changed identity must earn trust again
        // through one complete stable hash before the refreshed identity is used.
        return try refreshArchiveIdentity(plan, current: info)
    }

    public static func validateItem(_ item: VerifiedArchiveCleanup.Item,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try validateLocation(item.source, home: home)
        guard try digest(URL(fileURLWithPath: item.source.path), expected: item.source) == item.digest else {
            throw ArchiveCleanupError.changed
        }
    }

    public static func validateIdentity(_ item: VerifiedArchiveCleanup.Item) throws {
        var info = stat()
        guard lstat(item.source.path, &info) == 0, item.source.matches(info) else { throw ArchiveCleanupError.changed }
    }

    @discardableResult
    public static func validate(_ plan: VerifiedArchiveCleanup,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> VerifiedArchiveCleanup {
        let refreshed = try validateArchive(plan)
        for item in refreshed.items { try validateItem(item, home: home) }
        return refreshed
    }

    private static func refreshArchiveIdentity(_ plan: VerifiedArchiveCleanup,
                                               current: stat? = nil) throws -> VerifiedArchiveCleanup {
        var info = current ?? stat()
        if current == nil {
            guard lstat(plan.archive.path, &info) == 0 else { throw ArchiveCleanupError.changed }
        }
        let identity = ArchivedSource(
            path: plan.archive.path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
        guard try digest(plan.archive, expected: identity) == plan.archiveDigest else {
            throw ArchiveCleanupError.changed
        }
        return VerifiedArchiveCleanup(
            archive: plan.archive,
            items: plan.items,
            archiveDigest: plan.archiveDigest,
            archiveIdentity: identity
        )
    }

    private static func validateLocation(_ source: ArchivedSource, home: URL) throws {
        let url = URL(fileURLWithPath: source.path)
        let roots = [".claude/projects", ".codex/sessions", ".codex/archived_sessions"]
            .map { home.appendingPathComponent($0).path + "/" }
        let parts = source.path.split(separator: "/", omittingEmptySubsequences: false)
        guard source.path.hasPrefix("/"), !parts.contains("."), !parts.contains(".."),
              !source.path.contains("//"), url.pathExtension == "jsonl",
              roots.contains(where: { source.path.hasPrefix($0) }) else { throw ArchiveCleanupError.unsafeSource }
    }

    /// Bounded reads, no symlink ancestors, opened descriptor identity before/after
    /// hashing, and a final path identity check. No conversation text is retained.
    private static func digest(_ url: URL, expected: ArchivedSource? = nil) throws -> Data {
        var component = URL(fileURLWithPath: "/")
        for part in url.pathComponents.dropFirst() {
            component.appendPathComponent(part)
            var info = stat()
            guard lstat(component.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw ArchiveCleanupError.changed }
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveCleanupError.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              expected.map({ $0.matches(before) }) ?? true else { throw ArchiveCleanupError.changed }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            hash.update(data: bytes)
        }
        var after = stat(); var pathInfo = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &pathInfo) == 0,
              same(before, after), same(before, pathInfo) else { throw ArchiveCleanupError.changed }
        return Data(hash.finalize())
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private static func verifyZIP(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tqq", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ArchiveCleanupError.invalidZIP }
    }
}
