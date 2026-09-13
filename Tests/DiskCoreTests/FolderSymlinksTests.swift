import Darwin
@testable import DiskCore
import Foundation
import XCTest

final class FolderSymlinksTests: XCTestCase {
    func testInsideOutsidePrefixCollisionAndChainedTargets() async throws {
        let root = try fixture()
        try write("ok", at: root.appendingPathComponent("inside.txt"))
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-other"), withIntermediateDirectories: true)
        try write("no", at: root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-other/outside.txt"))
        XCTAssertEqual(symlink("inside.txt", root.appendingPathComponent("inside").path), 0)
        XCTAssertEqual(symlink("../\(root.lastPathComponent)-other/outside.txt", root.appendingPathComponent("outside").path), 0)
        XCTAssertEqual(symlink("inside", root.appendingPathComponent("chain").path), 0)
        let scan = try await DiskScanner.scan(root: root, backend: .foundation)
        let index = try FolderSymlinks.index(in: scan, folderID: 0)
        XCTAssertEqual(index.totalCount, 3)
        let details = try index.candidates.map { try FolderSymlinks.resolve($0, folder: root) }
        XCTAssertEqual(details.first { $0.relativePath == "inside" }?.status, .inside)
        XCTAssertEqual(details.first { $0.relativePath == "chain" }?.status, .inside)
        XCTAssertEqual(details.first { $0.relativePath == "outside" }?.status, .outside)
    }

    func testBrokenCycleChangedLinkAndChangedAncestor() async throws {
        let root = try fixture()
        try write("ok", at: root.appendingPathComponent("nested/file"))
        XCTAssertEqual(symlink("missing", root.appendingPathComponent("broken").path), 0)
        XCTAssertEqual(symlink("cycle-b", root.appendingPathComponent("cycle-a").path), 0)
        XCTAssertEqual(symlink("cycle-a", root.appendingPathComponent("cycle-b").path), 0)
        XCTAssertEqual(symlink("nested/file", root.appendingPathComponent("changed").path), 0)
        XCTAssertEqual(symlink("file", root.appendingPathComponent("nested/ancestor-changed").path), 0)
        let scan = try await DiskScanner.scan(root: root, backend: .foundation)
        let index = try FolderSymlinks.index(in: scan, folderID: 0)
        let byName = Dictionary(uniqueKeysWithValues: index.candidates.map { ($0.relativePath, $0) })
        XCTAssertEqual(try FolderSymlinks.resolve(try XCTUnwrap(byName["broken"]), folder: root).status, .broken)
        XCTAssertEqual(try FolderSymlinks.resolve(try XCTUnwrap(byName["cycle-a"]), folder: root).status, .unavailable)
        try FileManager.default.moveItem(at: root.appendingPathComponent("changed"), to: root.appendingPathComponent("changed-original"))
        XCTAssertEqual(symlink("missing", root.appendingPathComponent("changed").path), 0)
        XCTAssertEqual(try FolderSymlinks.resolve(try XCTUnwrap(byName["changed"]), folder: root).status, .changed)
        try FileManager.default.moveItem(at: root.appendingPathComponent("nested"), to: root.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        XCTAssertEqual(try FolderSymlinks.resolve(try XCTUnwrap(byName["nested/ancestor-changed"]), folder: root).status, .changed)
    }

    func testScanIdentityDetectsChangeBeforeIndexAndNestedSubtree() async throws {
        let root = try fixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/deeper"), withIntermediateDirectories: true)
        XCTAssertEqual(symlink("missing", root.appendingPathComponent("root-link").path), 0)
        XCTAssertEqual(symlink("missing", root.appendingPathComponent("nested/deeper/nested-link").path), 0)
        let scan = try await DiskScanner.scan(root: root, backend: .foundation)
        let nestedNode = try XCTUnwrap(scan.nodes.first { $0.name == "nested" })
        let nestedID = nestedNode.id
        let nestedIndex = try FolderSymlinks.index(in: scan, folderID: nestedID)
        XCTAssertEqual(nestedIndex.totalCount, 1)
        XCTAssertEqual(nestedIndex.candidates.first?.relativePath, "deeper/nested-link")
        try FileManager.default.moveItem(at: root.appendingPathComponent("root-link"), to: root.appendingPathComponent("root-link-original"))
        XCTAssertEqual(symlink("still-missing", root.appendingPathComponent("root-link").path), 0)
        let index = try FolderSymlinks.index(in: scan, folderID: 0)
        let candidate = try XCTUnwrap(index.candidates.first { $0.relativePath == "root-link" })
        XCTAssertEqual(try FolderSymlinks.resolve(candidate, folder: root).status, .changed)
    }

    func testRootAliasAndSymlinkParentDotDotUseCanonicalResolution() async throws {
        let root = try fixture()
        let external = root.deletingLastPathComponent().appendingPathComponent("folder-links-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: external.appendingPathComponent("real"), withIntermediateDirectories: true)
        try write("ok", at: external.appendingPathComponent("target.txt"))
        XCTAssertEqual(symlink(external.appendingPathComponent("real").path, root.appendingPathComponent("linkdir").path), 0)
        XCTAssertEqual(symlink("linkdir/../target.txt", root.appendingPathComponent("dotdot").path), 0)
        let alias = root.deletingLastPathComponent().appendingPathComponent("folder-links-alias-\(UUID().uuidString)")
        XCTAssertEqual(symlink(root.path, alias.path), 0)
        let scan = try await DiskScanner.scan(root: root, backend: .foundation)
        let candidate = try XCTUnwrap(FolderSymlinks.index(in: scan, folderID: 0).candidates.first { $0.relativePath == "dotdot" })
        let detail = try FolderSymlinks.resolve(candidate, folder: alias)
        XCTAssertEqual(detail.status, .outside)
        XCTAssertEqual(detail.targetPath, try canonical(external.appendingPathComponent("target.txt")))
    }

    func testInvalidFolderIsRejected() async throws {
        let root = try fixture()
        let scan = try await DiskScanner.scan(root: root, backend: .foundation)
        XCTAssertThrowsError(try FolderSymlinks.index(in: scan, folderID: 99)) { error in
            XCTAssertEqual(error as? FolderSymlinkError, .invalidFolder)
        }
    }

    func testCandidateCapAndIncompleteScan() async throws {
        let root = try fixture()
        for number in 0...1_000 {
            XCTAssertEqual(symlink("missing", root.appendingPathComponent(String(format: "link-%04d", number)).path), 0)
        }
        let scan = try await DiskScanner.scan(root: root, backend: .foundation)
        let index = try FolderSymlinks.index(in: scan, folderID: 0)
        XCTAssertEqual(index.totalCount, 1_001)
        XCTAssertEqual(index.candidates.count, 1_000)
        XCTAssertTrue(index.truncated)
        var incomplete = scan; incomplete.skipped = 1
        XCTAssertTrue(try FolderSymlinks.index(in: incomplete, folderID: 0).incompleteScan)
    }

    func testIndexObservesCancellation() async throws {
        let root = try fixture()
        XCTAssertEqual(symlink("missing", root.appendingPathComponent("link").path), 0)
        let scan = try await DiskScanner.scan(root: root, backend: .foundation)
        let gate = CancellationGate()
        let task = Task { () throws -> FolderSymlinkIndex in
            await gate.wait()
            return try FolderSymlinks.index(in: scan, folderID: 0)
        }
        await gate.waitUntilTaskIsReady()
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
    }

    func testUnknownScanIdentityIsUnavailable() async throws {
        let root = try fixture()
        XCTAssertEqual(symlink("missing", root.appendingPathComponent("link").path), 0)
        let scan = try await DiskScanner.scan(root: root, backend: .foundation)
        let original = try XCTUnwrap(FolderSymlinks.index(in: scan, folderID: 0).candidates.first)
        let unknown = FolderSymlinkCandidate(id: original.id, relativePath: original.relativePath, path: original.path,
            expectedLinkIdentity: FolderSymlinkPathIdentity(device: 0, inode: 0, mode: original.expectedLinkIdentity.mode),
            expectedAncestors: original.expectedAncestors)
        XCTAssertEqual(try FolderSymlinks.resolve(unknown, folder: root).status, .unavailable)
    }

    func testResolveObservesCancellation() async throws {
        let root = try fixture()
        XCTAssertEqual(symlink("missing", root.appendingPathComponent("link").path), 0)
        let scan = try await DiskScanner.scan(root: root, backend: .foundation)
        let candidate = try XCTUnwrap(FolderSymlinks.index(in: scan, folderID: 0).candidates.first)
        let gate = CancellationGate()
        let task = Task { () throws -> FolderSymlinkDetail in
            await gate.wait()
            return try FolderSymlinks.resolve(candidate, folder: root)
        }
        await gate.waitUntilTaskIsReady()
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diskbuddy-folder-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func canonical(_ url: URL) throws -> String {
        guard let path = realpath(url.path, nil) else { throw POSIXError(.EIO) }
        defer { free(path) }
        return String(cString: path)
    }
}

private actor CancellationGate {
    private var opened = false
    private var taskWaiter: CheckedContinuation<Void, Never>?
    private var readinessWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        readinessWaiter?.resume(); readinessWaiter = nil
        if opened { return }
        await withCheckedContinuation { taskWaiter = $0 }
    }

    func waitUntilTaskIsReady() async {
        if taskWaiter != nil || opened { return }
        await withCheckedContinuation { readinessWaiter = $0 }
    }

    func open() { opened = true; taskWaiter?.resume(); taskWaiter = nil }
}
