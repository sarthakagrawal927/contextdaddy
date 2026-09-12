import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ApplicationRemovalPlanError: Error, LocalizedError, Sendable {
    case ineligiblePath(String)
    case incompleteScan(String)

    public var errorDescription: String? {
        switch self {
        case let .ineligiblePath(path):
            return "Only a non-symlink .app directly in Applications can be removed: \(path)"
        case let .incompleteScan(path):
            return "The application scan was incomplete and cannot be used for removal: \(path)"
        }
    }
}

/// An immutable, safety-checked record for removing one installed application.
/// This type only prepares and validates the removal candidate; it never moves
/// or deletes any filesystem item.
public struct ApplicationRemovalPlan: Sendable {
    public let url: URL
    public let allocatedBytes: Int64
    private let scan: ScanResult
    private let allowedRoots: [URL]

    private init(url: URL, scan: ScanResult, allowedRoots: [URL]) {
        self.url = url
        self.scan = scan
        self.allowedRoots = allowedRoots
        self.allocatedBytes = scan.nodes[1].allocatedBytes
    }

    public static func prepare(url: URL) async throws -> Self {
        let manager = FileManager.default
        return try await prepare(
            url: url,
            allowedRoots: [
                URL(fileURLWithPath: "/Applications"),
                manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            ]
        )
    }

    /// Test-only root injection keeps production policy limited to the two
    /// Applications directories while allowing isolated temporary fixtures.
    static func prepare(
        url: URL,
        allowedRoots: [URL],
        scanBackend: ScanBackend = .parallel
    ) async throws -> Self {
        try Task.checkCancellation()
        let candidate = try eligibleURL(url, allowedRoots: allowedRoots)
        let parent = candidate.deletingLastPathComponent().standardizedFileURL

        let bundleScan = try await DiskScanner.scan(root: candidate, backend: scanBackend)
        guard bundleScan.skipped == 0, bundleScan.errors.isEmpty, bundleScan.nodes.count > 0 else {
            throw ApplicationRemovalPlanError.incompleteScan(candidate.path)
        }

        let scan = try makeCandidateScan(bundleScan, candidate: candidate, parent: parent)
        try CleanupSafety.validate(url: candidate, expected: scan.nodes[1], root: parent)
        try Task.checkCancellation()
        let plan = Self(url: candidate, scan: scan, allowedRoots: allowedRoots)
        try plan.validateIdentity()
        return plan
    }

    public func validate() async throws {
        try Task.checkCancellation()
        try validateIdentity()
        try await CleanupPreflight.validate(ids: [1], in: scan)
        try Task.checkCancellation()
    }

    /// Performs the non-suspending path and identity checks immediately before
    /// a caller hands this candidate to a filesystem mutation API.
    public func validateIdentity() throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        _ = try Self.eligibleURL(url, allowedRoots: allowedRoots)
        try CleanupSafety.validate(url: url, expected: scan.nodes[1], root: parent)
    }

    private static func makeCandidateScan(_ bundleScan: ScanResult, candidate: URL, parent: URL) throws -> ScanResult {
        guard let bundleRoot = bundleScan.nodes.first,
              bundleRoot.id == 0,
              bundleRoot.parent == nil else {
            throw ApplicationRemovalPlanError.incompleteScan(candidate.path)
        }

        var nodes = bundleScan.nodes
        for index in nodes.indices {
            nodes[index].id += 1
            nodes[index].parent = nodes[index].parent.map { $0 + 1 } ?? 0
            nodes[index].children = nodes[index].children.map { $0 + 1 }
        }
        let syntheticParent = DiskNode(
            id: 0,
            parent: nil,
            name: parent.lastPathComponent,
            isDirectory: true,
            children: [1]
        )
        nodes.insert(syntheticParent, at: 0)

        guard nodes[1].name == candidate.lastPathComponent else {
            throw ApplicationRemovalPlanError.incompleteScan(candidate.path)
        }
        return ScanResult(
            rootPath: parent.path,
            nodes: nodes,
            started: bundleScan.started,
            elapsed: bundleScan.elapsed,
            processDiskReadBytes: bundleScan.processDiskReadBytes,
            errors: bundleScan.errors,
            skipped: bundleScan.skipped,
            incompleteEvidence: bundleScan.incompleteEvidence,
            incompleteEvidenceTruncated: bundleScan.incompleteEvidenceTruncated
        )
    }

    private static func eligibleURL(_ url: URL, allowedRoots: [URL]) throws -> URL {
        let candidate = url.standardizedFileURL
        guard candidate.pathExtension.lowercased() == "app",
              let allowedRoot = containingRoot(for: candidate, allowedRoots: allowedRoots),
              !containsSymlink(from: allowedRoot, through: candidate),
              !hasApplicationAncestor(of: candidate, above: allowedRoot),
              isDirectory(candidate) else {
            throw ApplicationRemovalPlanError.ineligiblePath(candidate.path)
        }
        return candidate
    }

    private static func containingRoot(for candidate: URL, allowedRoots: [URL]) -> URL? {
        allowedRoots
            .map(\.standardizedFileURL)
            .filter { root in
                let path = candidate.path
                return path != root.path && path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
            }
            .max { $0.path.count < $1.path.count }
    }

    private static func hasApplicationAncestor(of candidate: URL, above root: URL) -> Bool {
        var current = candidate.deletingLastPathComponent().standardizedFileURL
        while current.path != root.path {
            if current.pathExtension.lowercased() == "app" { return true }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else { return true }
            current = parent
        }
        return false
    }

    private static func containsSymlink(from root: URL, through candidate: URL) -> Bool {
        let rootPath = root.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else { return true }
        var path = rootPath
        if isSymlink(path) { return true }
        let suffix = candidatePath.dropFirst(rootPath.count).split(separator: "/")
        for component in suffix {
            path += "/" + component
            if isSymlink(path) { return true }
        }
        return false
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var value: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &value) && value.boolValue
    }

    private static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }
}
