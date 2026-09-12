import Foundation
import Darwin

public struct ConversationArchiveReceipt: Decodable, Sendable {
    public let format: String
    public let sourceFiles: Int
    public let sourceBytes: Int64
    public let sessions: Int
    public let prompts: Int
    public let messages: Int
    public let skippedFiles: Int
    public let peakRSSBytes: UInt64?
    public let sources: [ArchivedSource]?

    public static func read(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 1_048_576 else { throw ArchivePublicationError.invalidReceipt }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.format == "memory-pack-receipt/1",
              value.sourceFiles >= 0, value.sourceBytes >= 0, value.sessions >= 0,
              value.prompts >= 0, value.messages >= 0, value.skippedFiles >= 0 else {
            throw ArchivePublicationError.invalidReceipt
        }
        return value
    }
}

public enum ArchivePublicationError: Error, LocalizedError {
    case invalidReceipt, invalidArchive, unsafeDestination, publishFailed
    public var errorDescription: String? {
        switch self {
        case .invalidReceipt: "The export did not produce a valid completion report. Your sessions are unchanged."
        case .invalidArchive: "The archive is incomplete. Your sessions and existing exports are unchanged."
        case .unsafeDestination: "Choose a regular file location for the archive, outside your agent’s session folders."
        case .publishFailed: "The archive could not be saved there. Check access and available space, then try another folder."
        }
    }
}

public enum ArchivePublisher {
    /// The caller has obtained replacement consent using NSSavePanel. The
    /// temporary archive is on the same filesystem for an atomic rename.
    public static func publish(staged: URL, destination: URL) throws {
        var input = stat()
        guard lstat(staged.path, &input) == 0, input.st_mode & S_IFMT == S_IFREG,
              input.st_size >= 22 else { throw ArchivePublicationError.invalidArchive }
        let handle = try FileHandle(forReadingFrom: staged)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw ArchivePublicationError.invalidArchive
        }
        try validateDestination(destination)
        guard rename(staged.path, destination.path) == 0 else { throw ArchivePublicationError.publishFailed }
    }

    public static func validateDestination(_ destination: URL) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "zip" else {
            throw ArchivePublicationError.unsafeDestination
        }
        let components = destination.pathComponents.map { $0.lowercased() }
        guard !components.contains(where: { [".codex", ".claude", ".ssh", ".aws", ".kube", ".gnupg"].contains($0) }) else {
            throw ArchivePublicationError.unsafeDestination
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in destination.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard info.st_mode & S_IFMT != S_IFLNK else { throw ArchivePublicationError.unsafeDestination }
                if current.path == destination.path, info.st_mode & S_IFMT != S_IFREG {
                    throw ArchivePublicationError.unsafeDestination
                }
            } else if current.path != destination.path || errno != ENOENT {
                throw ArchivePublicationError.unsafeDestination
            }
        }
    }
}
