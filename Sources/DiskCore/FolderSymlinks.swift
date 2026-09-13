import Darwin
import Foundation

/// A read-only inventory of symbolic links already discovered by a scan.
public enum FolderSymlinks {
    public static let maximumCandidates = 1_000

    /// Builds a bounded, deterministic list of symlinks in `folderID`'s scanned subtree.
    /// This only inspects immutable scan metadata; indexing performs no I/O.
    public static func index(in scan: ScanResult, folderID: Int) throws -> FolderSymlinkIndex {
        try Task.checkCancellation()
        guard validNodeID(folderID, in: scan), scan.nodes[folderID].isDirectory, !scan.nodes[folderID].isSymlink else {
            throw FolderSymlinkError.invalidFolder
        }
        let folder = scan.url(for: folderID).standardizedFileURL
        var retained: [RetainedCandidate] = []
        var totalCount = 0
        var stack: [(id: Int, nextChild: Int)] = [(folderID, 0)]
        while !stack.isEmpty {
            try Task.checkCancellation()
            let frameIndex = stack.index(before: stack.endIndex)
            let parentID = stack[frameIndex].id
            guard validNodeID(parentID, in: scan) else { stack.removeLast(); continue }
            let children = scan.nodes[parentID].children
            guard stack[frameIndex].nextChild < children.count else { stack.removeLast(); continue }
            let childID = children[stack[frameIndex].nextChild]
            stack[frameIndex].nextChild += 1
            guard validNodeID(childID, in: scan), childID > parentID, scan.nodes[childID].parent == parentID else { continue }
            let child = scan.nodes[childID]
            if child.isSymlink {
                totalCount += 1
                guard let relative = relativePath(for: childID, from: folderID, in: scan) else { continue }
                insert(RetainedCandidate(id: childID, relativePath: relative), into: &retained)
            } else if child.isDirectory {
                stack.append((childID, 0))
            }
        }
        var candidates: [FolderSymlinkCandidate] = []
        candidates.reserveCapacity(retained.count)
        for retainedCandidate in retained {
            try Task.checkCancellation()
            let node = scan.nodes[retainedCandidate.id]
            let path = folder.appendingPathComponent(retainedCandidate.relativePath).path
            guard let ancestors = ancestors(for: retainedCandidate.id, from: folderID, folderPath: folder.path, scan: scan) else { continue }
            candidates.append(FolderSymlinkCandidate(id: node.id, relativePath: retainedCandidate.relativePath,
                path: path, expectedLinkIdentity: identity(for: node), expectedAncestors: ancestors))
        }
        return FolderSymlinkIndex(
            totalCount: totalCount,
            candidates: candidates,
            truncated: totalCount > maximumCandidates,
            incompleteScan: scan.skipped > 0 || !scan.errors.isEmpty || scan.incompleteEvidenceTruncated == true
        )
    }

    /// Reads only link metadata. It never opens or reads the link target's contents.
    public static func resolve(_ candidate: FolderSymlinkCandidate, folder: URL) throws -> FolderSymlinkDetail {
        try Task.checkCancellation()
        if let status = sourceFailureStatus(candidate) {
            return FolderSymlinkDetail(candidate: candidate, targetPath: nil, rawTarget: nil, status: status)
        }

        let rawTarget: String
        do {
            rawTarget = try readLink(at: candidate.path)
        } catch {
            return FolderSymlinkDetail(candidate: candidate, targetPath: nil, rawTarget: nil, status: .unavailable)
        }
        try Task.checkCancellation()

        // Recheck both before using a target computed from the source path.
        if let status = sourceFailureStatus(candidate) {
            return FolderSymlinkDetail(candidate: candidate, targetPath: nil, rawTarget: rawTarget, status: status)
        }

        let sourceParent = URL(fileURLWithPath: candidate.path).deletingLastPathComponent().path
        let rawAbsoluteTarget = rawTarget.hasPrefix("/") ? rawTarget : sourceParent + "/" + rawTarget
        let outcome = resolveTarget(rawAbsoluteTarget)
        try Task.checkCancellation()
        if let status = sourceFailureStatus(candidate) {
            return FolderSymlinkDetail(candidate: candidate, targetPath: nil, rawTarget: rawTarget, status: status)
        }

        switch outcome {
        case let .available(target):
            guard let selectedFolder = canonicalPath(folder.path) else {
                return FolderSymlinkDetail(candidate: candidate, targetPath: target, rawTarget: rawTarget, status: .unavailable)
            }
            let status: FolderSymlinkStatus = isWithin(target, selectedFolder) ? .inside : .outside
            return FolderSymlinkDetail(candidate: candidate, targetPath: target, rawTarget: rawTarget, status: status)
        case let .broken(target):
            return FolderSymlinkDetail(candidate: candidate, targetPath: target, rawTarget: rawTarget, status: .broken)
        case .unavailable:
            return FolderSymlinkDetail(candidate: candidate, targetPath: nil, rawTarget: rawTarget, status: .unavailable)
        }
    }

    private struct RetainedCandidate {
        let id: Int
        let relativePath: String
    }

    private static func insert(_ candidate: RetainedCandidate, into candidates: inout [RetainedCandidate]) {
        var lower = 0
        var upper = candidates.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if precedes(candidate, candidates[middle]) { upper = middle }
            else { lower = middle + 1 }
        }
        let position = lower
        guard position < maximumCandidates || candidates.count < maximumCandidates else { return }
        candidates.insert(candidate, at: position)
        if candidates.count > maximumCandidates { candidates.removeLast() }
    }

    private static func precedes(_ left: RetainedCandidate, _ right: RetainedCandidate) -> Bool {
        if left.relativePath != right.relativePath {
            return left.relativePath.utf8.lexicographicallyPrecedes(right.relativePath.utf8)
        }
        return left.id < right.id
    }

    private static func identity(for node: DiskNode) -> FolderSymlinkPathIdentity {
        let mode: UInt32 = node.isSymlink ? UInt32(S_IFLNK) : node.isDirectory ? UInt32(S_IFDIR) : UInt32(S_IFREG)
        return FolderSymlinkPathIdentity(device: node.device, inode: node.inode, mode: mode)
    }

    private static func validNodeID(_ id: Int, in scan: ScanResult) -> Bool {
        scan.nodes.indices.contains(id) && scan.nodes[id].id == id
    }

    private static func relativePath(for id: Int, from folderID: Int, in scan: ScanResult) -> String? {
        var parts: [String] = []
        var current = id
        while current != folderID {
            guard validNodeID(current, in: scan), let parent = scan.nodes[current].parent, parent < current else { return nil }
            parts.append(scan.nodes[current].name)
            current = parent
        }
        return parts.reversed().joined(separator: "/")
    }

    private static func ancestors(for id: Int, from folderID: Int, folderPath: String, scan: ScanResult) -> [FolderSymlinkAncestorIdentity]? {
        var ids: [Int] = []
        var current = id
        while current != folderID {
            guard validNodeID(current, in: scan), let parent = scan.nodes[current].parent, parent < current else { return nil }
            ids.append(parent)
            current = parent
        }
        var path = folderPath
        var result: [FolderSymlinkAncestorIdentity] = [FolderSymlinkAncestorIdentity(path: path, identity: identity(for: scan.nodes[folderID]))]
        for ancestorID in ids.reversed().dropFirst() {
            path = URL(fileURLWithPath: path).appendingPathComponent(scan.nodes[ancestorID].name).path
            result.append(FolderSymlinkAncestorIdentity(path: path, identity: identity(for: scan.nodes[ancestorID])))
        }
        return result
    }

    private enum TargetOutcome { case available(String), broken(String), unavailable }
    private enum IdentityCheck { case matches, changed, unavailable }

    private static func resolveTarget(_ rawAbsolutePath: String) -> TargetOutcome {
        guard let resolved = realpath(rawAbsolutePath, nil) else {
            if errno == ENOENT || errno == ENOTDIR { return .broken(lexicalPath(rawAbsolutePath)) }
            return .unavailable
        }
        defer { free(resolved) }
        return .available(String(cString: resolved))
    }

    private static func isWithin(_ path: String, _ folder: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }

    private static func lexicalPath(_ input: String) -> String {
        var components: [Substring] = []
        for component in input.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func readLink(at path: String) throws -> String {
        var capacity = 256
        while capacity <= 65_536 {
            var bytes = [CChar](repeating: 0, count: capacity)
            let length = path.withCString { readlink($0, &bytes, capacity) }
            if length < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if length < capacity { return String(decoding: bytes.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self) }
            capacity *= 2
        }
        throw POSIXError(.ENAMETOOLONG)
    }

    private static func sourceFailureStatus(_ candidate: FolderSymlinkCandidate) -> FolderSymlinkStatus? {
        for ancestor in candidate.expectedAncestors {
            switch identityCheck(ancestor.identity, at: ancestor.path) {
            case .matches: continue
            case .changed: return .changed
            case .unavailable: return .unavailable
            }
        }
        switch identityCheck(candidate.expectedLinkIdentity, at: candidate.path) {
        case .matches: return nil
        case .changed: return .changed
        case .unavailable: return .unavailable
        }
    }

    private static func identityCheck(_ expected: FolderSymlinkPathIdentity, at path: String) -> IdentityCheck {
        guard expected.device != 0 || expected.inode != 0 else { return .unavailable }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .changed : .unavailable
        }
        let actual = FolderSymlinkPathIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), mode: UInt32(info.st_mode & S_IFMT))
        return actual == expected ? .matches : .changed
    }
}

public struct FolderSymlinkPathIdentity: Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32

    public init(device: UInt64, inode: UInt64, mode: UInt32) {
        self.device = device; self.inode = inode; self.mode = mode
    }
}

public struct FolderSymlinkAncestorIdentity: Sendable, Equatable {
    public let path: String
    public let identity: FolderSymlinkPathIdentity

    public init(path: String, identity: FolderSymlinkPathIdentity) {
        self.path = path; self.identity = identity
    }
}

public struct FolderSymlinkCandidate: Identifiable, Sendable, Equatable {
    public let id: Int
    public let relativePath: String
    public let path: String
    public let expectedLinkIdentity: FolderSymlinkPathIdentity
    public let expectedAncestors: [FolderSymlinkAncestorIdentity]

    public init(id: Int, relativePath: String, path: String, expectedLinkIdentity: FolderSymlinkPathIdentity, expectedAncestors: [FolderSymlinkAncestorIdentity]) {
        self.id = id; self.relativePath = relativePath; self.path = path
        self.expectedLinkIdentity = expectedLinkIdentity; self.expectedAncestors = expectedAncestors
    }
}

public struct FolderSymlinkIndex: Sendable, Equatable {
    public let totalCount: Int
    public let candidates: [FolderSymlinkCandidate]
    public let truncated: Bool
    public let incompleteScan: Bool

    public init(totalCount: Int, candidates: [FolderSymlinkCandidate], truncated: Bool, incompleteScan: Bool) {
        self.totalCount = totalCount; self.candidates = candidates; self.truncated = truncated; self.incompleteScan = incompleteScan
    }
}

public enum FolderSymlinkStatus: Sendable, Equatable { case inside, outside, broken, unavailable, changed }

public enum FolderSymlinkError: Error, Sendable, Equatable { case invalidFolder }

public struct FolderSymlinkDetail: Identifiable, Sendable, Equatable {
    public let id: Int
    public let relativePath: String
    public let path: String
    public let targetPath: String?
    /// The text stored in the symlink, before relative-target normalization.
    public let rawTarget: String?
    public let status: FolderSymlinkStatus

    public init(candidate: FolderSymlinkCandidate, targetPath: String?, rawTarget: String?, status: FolderSymlinkStatus) {
        self.id = candidate.id; self.relativePath = candidate.relativePath; self.path = candidate.path
        self.targetPath = targetPath; self.rawTarget = rawTarget; self.status = status
    }
}
