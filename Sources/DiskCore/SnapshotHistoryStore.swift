import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SavedScanSnapshot: Codable, Sendable, Identifiable {
    public let id: UUID
    public let savedAt: Date
    public let scan: ScanResult

    public init(id: UUID, savedAt: Date, scan: ScanResult) {
        self.id = id
        self.savedAt = savedAt
        self.scan = scan
    }
}

public struct SnapshotHistoryListing: Sendable {
    public let snapshots: [SavedScanSnapshot]
    public let unreadableCount: Int
    public let limitReached: Bool

    public init(snapshots: [SavedScanSnapshot], unreadableCount: Int, limitReached: Bool) {
        self.snapshots = snapshots
        self.unreadableCount = unreadableCount
        self.limitReached = limitReached
    }
}

public enum SnapshotHistoryStore {
    private static let maximumEntries = 512
    private static let maximumFileBytes: Int64 = 8 * 1024 * 1024

    public static func save(scan: ScanResult, directory: URL, savedAt: Date = Date()) throws -> SavedScanSnapshot {
        try prepare(directory: directory)
        let saved = SavedScanSnapshot(id: UUID(), savedAt: savedAt, scan: SnapshotArchive.compact(scan))
        try SnapshotArchive.validate(saved.scan)
        let data = try JSONEncoder().encode(saved)
        guard data.count <= maximumFileBytes else { throw error("Compact snapshot exceeds the history file limit.") }

        let timestamp = Int64(savedAt.timeIntervalSince1970 * 1_000_000)
        let filename = String(format: "%020lld-%@.json", timestamp, saved.id.uuidString)
        let temporary = directory.appendingPathComponent(".\(saved.id.uuidString).tmp")
        let destination = directory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeTemporary(data, to: temporary)
        guard link(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return saved
    }

    public static func load(directory: URL) throws -> SnapshotHistoryListing {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return SnapshotHistoryListing(snapshots: [], unreadableCount: 0, limitReached: false)
        }
        try validateDirectory(directory)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted {
            let left = filenameIdentity($0)?.timestamp ?? Int64.min
            let right = filenameIdentity($1)?.timestamp ?? Int64.min
            return left == right ? $0.lastPathComponent > $1.lastPathComponent : left > right
        }
        let limitReached = entries.count > maximumEntries
        var snapshots: [SavedScanSnapshot] = []
        var unreadable = 0

        for url in entries.prefix(maximumEntries) {
            do {
                guard let identity = filenameIdentity(url) else { throw error("Invalid history filename.") }
                let value = try JSONDecoder().decode(SavedScanSnapshot.self, from: readBounded(url))
                guard identity.id == value.id else {
                    throw error("Snapshot identity does not match its filename.")
                }
                try SnapshotArchive.validate(value.scan)
                snapshots.append(SavedScanSnapshot(id: value.id, savedAt: value.savedAt, scan: SnapshotArchive.compact(value.scan)))
            } catch {
                unreadable += 1
            }
        }
        snapshots.sort { $0.savedAt == $1.savedAt ? $0.id.uuidString < $1.id.uuidString : $0.savedAt > $1.savedAt }
        return SnapshotHistoryListing(snapshots: snapshots, unreadableCount: unreadable, limitReached: limitReached)
    }

    private static func prepare(directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validateDirectory(directory)
    }

    private static func validateDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw error("Snapshot history location is not a regular directory.")
        }
    }

    private static func filenameIdentity(_ url: URL) -> (timestamp: Int64, id: UUID)? {
        guard url.pathExtension.lowercased() == "json" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count > 37 else { return nil }
        let idStart = name.index(name.endIndex, offsetBy: -36)
        guard name[name.index(before: idStart)] == "-",
              let id = UUID(uuidString: String(name[idStart...])),
              let timestamp = Int64(name[..<name.index(before: idStart)]) else { return nil }
        return (timestamp, id)
    }

    private static func writeTemporary(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(descriptor, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func readBounded(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              Int64(before.st_size) <= maximumFileBytes else { throw error("Invalid or oversized history entry.") }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let count = read(descriptor, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw error("History entry changed while reading.") }
                offset += count
            }
        }
        var after = stat(), pathInfo = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &pathInfo) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              after.st_dev == pathInfo.st_dev, after.st_ino == pathInfo.st_ino, after.st_size == pathInfo.st_size,
              pathInfo.st_mode & S_IFMT == S_IFREG else { throw error("History entry changed while reading.") }
        return data
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SnapshotHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
