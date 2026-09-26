import Foundation
import Darwin

public enum SkillShareTarget: String, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
    case cursor = "Cursor"
    case devin = "Devin"
    case grok = "Grok"

    public var id: String { rawValue }

    var relativeRoot: String {
        switch self {
        case .codex: ".codex/skills"
        case .claude: ".claude/skills"
        case .cursor: ".cursor/skills"
        case .devin: ".config/devin/skills"
        case .grok: ".grok/skills"
        }
    }
}

public enum SkillShareStatus: Equatable, Sendable {
    case available
    case alreadyShared
    case occupied
    case unavailable(String)
}

public struct SkillSharePlan: Sendable {
    public let sourceDirectory: URL
    public let destination: URL
    public let target: SkillShareTarget
    public let status: SkillShareStatus
}

public enum SkillShareError: LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        if case .unavailable(let message) = self { return message }
        return nil
    }
}

/// Creates one directory link. It never replaces an occupied destination or
/// changes the source skill. A fresh assessment is required immediately before
/// writing because the inventory may be stale.
public enum SkillSharing {
    public static func plan(for record: SkillRecord, target: SkillShareTarget,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SkillSharePlan {
        let sourceFile = URL(fileURLWithPath: record.id).standardizedFileURL
        let sourceDirectory = sourceFile.deletingLastPathComponent()
        let root = home.standardizedFileURL.appendingPathComponent(target.relativeRoot, isDirectory: true)
        let destination = root.appendingPathComponent(sourceDirectory.lastPathComponent, isDirectory: true)
        let status: SkillShareStatus
        if record.activeExposures.isEmpty || sourceFile.path.contains("/.codex/plugins/cache/")
            || sourceFile.path.contains("/.claude/plugins/cache/")
            || sourceFile.path.contains("/.codex/skills/.system/") {
            status = .unavailable("This definition belongs to a managed installation or cache.")
        } else if sourceFile.lastPathComponent != "SKILL.md" || !validName(sourceDirectory.lastPathComponent) {
            status = .unavailable("The source is not a named skill directory with SKILL.md.")
        } else if fileKind(sourceFile.path) != S_IFREG || fileKind(sourceDirectory.path) != S_IFDIR {
            status = .unavailable("The source skill is no longer a regular local file and directory.")
        } else if unsafeParent(for: root, home: home.standardizedFileURL) {
            status = .unavailable("A destination parent is a link or is not a directory.")
        } else if let kind = fileKind(destination.path) {
            let sameSource = destination.resolvingSymlinksInPath().standardizedFileURL.path
                == sourceDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            status = sameSource && (kind == S_IFLNK || kind == S_IFDIR) ? .alreadyShared : .occupied
        } else {
            status = .available
        }
        return SkillSharePlan(sourceDirectory: sourceDirectory, destination: destination, target: target, status: status)
    }

    @discardableResult
    public static func createLink(for record: SkillRecord, target: SkillShareTarget,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let current = plan(for: record, target: target, home: home)
        guard current.status == .available else {
            throw SkillShareError.unavailable(message(for: current.status))
        }
        let root = current.destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checked = plan(for: record, target: target, home: home)
        guard checked.status == .available else {
            throw SkillShareError.unavailable(message(for: checked.status))
        }
        try FileManager.default.createSymbolicLink(at: checked.destination, withDestinationURL: checked.sourceDirectory)
        return checked.destination
    }

    private static func message(for status: SkillShareStatus) -> String {
        switch status {
        case .available: "Ready to share."
        case .alreadyShared: "This agent already has a route to the same skill directory."
        case .occupied: "The destination already contains a different file or directory. Review it before changing anything."
        case .unavailable(let reason): reason
        }
    }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }

    private static func unsafeParent(for root: URL, home: URL) -> Bool {
        guard fileKind(home.path) == S_IFDIR else { return true }
        var current = home
        for component in root.pathComponents.dropFirst(home.pathComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            if let kind = fileKind(current.path), kind != S_IFDIR { return true }
        }
        return false
    }

    private static func fileKind(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }
}
