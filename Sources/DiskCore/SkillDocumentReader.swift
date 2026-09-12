import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SkillDocument: Sendable, Equatable {
    public let text: String
    public let bytesRead: Int
    public let truncated: Bool

    public init(text: String, bytesRead: Int, truncated: Bool) {
        self.text = text
        self.bytesRead = bytesRead
        self.truncated = truncated
    }
}

public enum SkillDocumentReadError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedFile
    case symlink
    case notRegularFile
    case changedDuringRead
    case binary
    case invalidUTF8
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: return "This file type is not available in the text viewer."
        case .symlink: return "The file or one of its parent folders is a symbolic link."
        case .notRegularFile: return "This item is not a regular text file."
        case .changedDuringRead: return "The file changed while it was being read. Try again."
        case .binary: return "This file contains binary data and cannot be shown as text."
        case .invalidUTF8: return "This file is not valid UTF-8 text."
        case .unreadable: return "The file could not be read. It may have moved or become unavailable."
        }
    }
}

public enum SkillDocumentReader {
    public static let maximumBytes = 256 * 1024

    private static let allowedNames: Set<String> = [
        "skill.md", "agents.md", "agents.override.md", "claude.local.md", "claude.md", "gemini.md", ".cursorrules"
    ]

    public static func read(url: URL, maximumBytes: Int = maximumBytes, documentKind: AIContextKind? = nil) throws -> SkillDocument {
        let limit = max(1, min(maximumBytes, Self.maximumBytes))
        let fileURL = url.absoluteURL
        let parent = fileURL.deletingLastPathComponent()
        let isClaudeRule = fileURL.pathExtension.lowercased() == "md"
            && parent.lastPathComponent.lowercased() == "rules"
            && parent.deletingLastPathComponent().lastPathComponent.lowercased() == ".claude"
        // Additional types are accepted only for an explicitly selected inventory
        // item. Discovery never reads these bodies; all identity/size guards below
        // remain identical to the skill viewer.
        let selectedAgent = documentKind == .agentDefinition && ["md", "toml"].contains(fileURL.pathExtension.lowercased())
        let selectedRule = documentKind == .rule && ["md", "mdc"].contains(fileURL.pathExtension.lowercased())
        guard allowedNames.contains(fileURL.lastPathComponent.lowercased())
                || fileURL.pathExtension.lowercased() == "mdc" || isClaudeRule || selectedAgent || selectedRule else {
            throw SkillDocumentReadError.unsupportedFile
        }

        guard let before = try lstatInfo(at: fileURL) else { throw SkillDocumentReadError.unreadable }
        if (before.st_mode & S_IFMT) == S_IFLNK { throw SkillDocumentReadError.symlink }
        guard (before.st_mode & S_IFMT) == S_IFREG else { throw SkillDocumentReadError.notRegularFile }
        try rejectSymlinkAncestors(of: fileURL)

        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SkillDocumentReadError.unreadable }
        defer { close(descriptor) }

        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw SkillDocumentReadError.unreadable }
        guard (after.st_mode & S_IFMT) == S_IFREG else { throw SkillDocumentReadError.notRegularFile }
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw SkillDocumentReadError.changedDuringRead
        }

        var bytes = [UInt8](repeating: 0, count: limit + 1)
        var count = 0
        while count < bytes.count {
            let remaining = bytes.count - count
            let result = bytes.withUnsafeMutableBytes { buffer in
                #if canImport(Darwin)
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), remaining)
                #else
                Glibc.read(descriptor, buffer.baseAddress!.advanced(by: count), remaining)
                #endif
            }
            if result > 0 {
                count += result
            } else if result == 0 {
                break
            } else if errno != EINTR {
                throw SkillDocumentReadError.unreadable
            }
        }
        var afterRead = stat()
        guard fstat(descriptor, &afterRead) == 0 else { throw SkillDocumentReadError.unreadable }
        guard sameIdentity(before, afterRead), sameSizeAndModification(before, afterRead) else {
            throw SkillDocumentReadError.changedDuringRead
        }
        guard let afterPath = try lstatInfo(at: fileURL), sameIdentity(before, afterPath), sameSizeAndModification(before, afterPath) else {
            throw SkillDocumentReadError.changedDuringRead
        }

        let data = Data(bytes.prefix(min(count, limit)))
        guard !data.contains(0) else { throw SkillDocumentReadError.binary }
        let truncated = count > limit
        var textData = data
        if truncated, String(data: textData, encoding: .utf8) == nil {
            for trim in 1...3 where trim <= textData.count {
                let candidate = textData.dropLast(trim)
                if String(data: candidate, encoding: .utf8) != nil {
                    textData = Data(candidate)
                    break
                }
            }
        }
        guard let text = String(data: textData, encoding: .utf8) else {
            throw SkillDocumentReadError.invalidUTF8
        }
        return SkillDocument(text: text, bytesRead: textData.count, truncated: truncated)
    }

    private static func lstatInfo(at url: URL) throws -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw SkillDocumentReadError.unreadable
        }
        return info
    }

    private static func rejectSymlinkAncestors(of url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.path.split(separator: "/") {
            current.appendPathComponent(String(component))
            var info = stat()
            guard lstat(current.path, &info) == 0 else { throw SkillDocumentReadError.unreadable }
            if (info.st_mode & S_IFMT) == S_IFLNK { throw SkillDocumentReadError.symlink }
        }
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    private static func sameSizeAndModification(_ lhs: stat, _ rhs: stat) -> Bool {
        guard lhs.st_size == rhs.st_size else { return false }
        #if canImport(Darwin)
        return lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
        #else
        return lhs.st_mtim.tv_sec == rhs.st_mtim.tv_sec && lhs.st_mtim.tv_nsec == rhs.st_mtim.tv_nsec
        #endif
    }
}
