import Darwin
import Foundation

/// The small, non-content-bearing portion of a local AI session record.
/// `project` is the recorded working directory and is not inferred from a
/// filename or decoded session path.
public struct AISessionDetails: Sendable, Equatable {
    public let project: String?
    public let sessionID: String?

    public init(project: String? = nil, sessionID: String? = nil) {
        self.project = project
        self.sessionID = sessionID
    }

    /// Reads at most the first 64 KiB of a recognized Claude or Codex session
    /// JSONL file. Unsafe, malformed, or unrecognized input returns empty
    /// fields. Prompt and message fields are neither retained nor exposed.
    public static func read(url: URL, tool: String) -> AISessionDetails {
        guard url.isFileURL,
              let kind = SessionTool(tool),
              isRecognizedSessionPath(url, kind: kind) else {
            return AISessionDetails()
        }
        // Foundation aliases /private/var back to /var on macOS. Preserve the
        // supplied physical path, reject traversal components, and let lstat
        // verify every component instead of normalizing through an alias.
        let candidatePath = url.path
        guard !candidatePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return AISessionDetails()
        }
        guard !hasSymlinkAncestor(at: candidatePath),
              let before = fileIdentity(at: candidatePath),
              before.isRegular else {
            return AISessionDetails()
        }

        let descriptor = open(candidatePath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return AISessionDetails() }
        defer { close(descriptor) }

        guard let opened = fileIdentity(for: descriptor), opened == before,
              let details = readDetails(from: descriptor, kind: kind),
              let afterDescriptor = fileIdentity(for: descriptor), afterDescriptor == before,
              let afterPath = fileIdentity(at: candidatePath), afterPath == before,
              !hasSymlinkAncestor(at: candidatePath) else {
            return AISessionDetails()
        }
        return details
    }

    private static let maximumReadBytes = 64 * 1024
    // Current Codex session_meta lines include base instructions and commonly
    // exceed 16 KiB. The line remains bounded by the overall 64 KiB read cap.
    private static let maximumLineBytes = maximumReadBytes
    private static let maximumLines = 256
    private static let maximumFieldCharacters = 4 * 1024

    private static func parse(_ data: Data, kind: SessionTool) -> AISessionDetails {
        var project: String?
        var sessionID: String?
        var lineStart = data.startIndex
        var lineCount = 0

        while lineStart < data.endIndex, lineCount < maximumLines {
            guard let lineEnd = data[lineStart...].firstIndex(of: 0x0A) else { break }
            let lineLength = data.distance(from: lineStart, to: lineEnd)
            guard lineLength <= maximumLineBytes else { return AISessionDetails() }
            defer {
                lineStart = data.index(after: lineEnd)
                lineCount += 1
            }

            let line = data[lineStart..<lineEnd]
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let record = object as? [String: Any] else { continue }
            let fields = fields(in: record, kind: kind)
            project = project ?? validProject(fields.project)
            sessionID = sessionID ?? validField(fields.sessionID)
            if project != nil, sessionID != nil { break }
        }
        return AISessionDetails(project: project, sessionID: sessionID)
    }

    private static func fields(in record: [String: Any], kind: SessionTool) -> (project: String?, sessionID: String?) {
        switch kind {
        case .codex:
            guard record["type"] as? String == "session_meta",
                  let payload = record["payload"] as? [String: Any] else {
                return (nil, nil)
            }
            return (payload["cwd"] as? String, payload["id"] as? String)
        case .claude:
            return (record["cwd"] as? String, record["sessionId"] as? String)
        }
    }

    private static func validField(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= maximumFieldCharacters,
              !containsControlCharacter(value) else { return nil }
        return value
    }

    private static func validProject(_ value: String?) -> String? {
        guard let value = validField(value), value.hasPrefix("/") else { return nil }
        return value
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0...31).contains(scalar.value) || (127...159).contains(scalar.value)
        }
    }

    private static func readDetails(from descriptor: Int32, kind: SessionTool) -> AISessionDetails? {
        let chunkSize = 4 * 1024
        var data = Data()
        data.reserveCapacity(chunkSize)
        var bytes = [UInt8](repeating: 0, count: chunkSize)
        while data.count < maximumReadBytes {
            let requested = min(chunkSize, maximumReadBytes - data.count)
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, requested)
            }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(Int(count)))
            let details = parse(data, kind: kind)
            if details.project != nil, details.sessionID != nil { return details }
        }
        return parse(data, kind: kind)
    }

    private static func isRecognizedSessionPath(_ url: URL, kind: SessionTool) -> Bool {
        guard url.pathExtension.lowercased() == "jsonl" else { return false }
        let components = url.path.split(separator: "/").map { $0.lowercased() }
        switch kind {
        case .claude:
            guard let home = components.lastIndex(of: ".claude") else { return false }
            return home + 1 < components.count && components[home + 1] == "projects"
        case .codex:
            guard let home = components.lastIndex(of: ".codex") else { return false }
            guard home + 1 < components.count else { return false }
            return components[home + 1] == "sessions" || components[home + 1] == "archived_sessions"
        }
    }

    private static func hasSymlinkAncestor(at path: String) -> Bool {
        let components = path.split(separator: "/")
        var path = ""
        for component in components {
            path += "/" + component
            var info = stat()
            guard lstat(path, &info) == 0 else { return true }
            if info.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    private static func fileIdentity(at path: String) -> AISessionFileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return AISessionFileIdentity(info)
    }

    private static func fileIdentity(for descriptor: Int32) -> AISessionFileIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return AISessionFileIdentity(info)
    }
}

private enum SessionTool {
    case claude
    case codex

    init?(_ value: String) {
        let normalized = value.lowercased()
        if normalized.contains("claude") { self = .claude }
        else if normalized.contains("codex") { self = .codex }
        else { return nil }
    }
}

private struct AISessionFileIdentity: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int
    let isRegular: Bool

    init(_ info: stat) {
        device = Int32(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int(info.st_mtimespec.tv_nsec)
        isRegular = info.st_mode & S_IFMT == S_IFREG
    }
}
