import Darwin
@testable import DiskCore
import Foundation
import XCTest

final class ScannerTests: XCTestCase {
    func testFoundationScanAggregatesSparseFilesAndDeduplicatesHardLinks() async throws {
        let fixture = try makeFixture()
        let ordinary = fixture.appendingPathComponent("ordinary.bin")
        let sparse = fixture.appendingPathComponent("nested/sparse.bin")
        let linked = fixture.appendingPathComponent("nested/ordinary-link.bin")

        try write([0xA5], to: ordinary)
        try writeSparseFile(at: sparse, size: 16 * 1024 * 1024)
        XCTAssertEqual(link(ordinary.path, linked.path), 0)

        let result = try await DiskScanner.scan(root: fixture, backend: .foundation)
        let ordinaryNode = try node(named: "ordinary.bin", in: result)
        let linkNode = try node(named: "ordinary-link.bin", in: result)
        let sparseNode = try node(named: "sparse.bin", in: result)
        let nested = try node(named: "nested", in: result)

        XCTAssertEqual(ordinaryNode.logicalBytes, 1)
        XCTAssertEqual(linkNode.logicalBytes, 1, "logical size counts each directory entry")
        XCTAssertEqual(ordinaryNode.inode, linkNode.inode)
        XCTAssertEqual(sparseNode.logicalBytes, 16 * 1024 * 1024)
        try XCTSkipIf(
            sparseNode.allocatedBytes >= sparseNode.logicalBytes,
            "the temporary test volume does not expose sparse allocation"
        )
        XCTAssertLessThan(sparseNode.allocatedBytes, sparseNode.logicalBytes)
        XCTAssertEqual(nested.logicalBytes, sparseNode.logicalBytes + linkNode.logicalBytes)
        XCTAssertEqual(result.nodes[0].logicalBytes, 16 * 1024 * 1024 + 2)
        let hardLinkAllocation = ordinaryNode.allocatedBytes + linkNode.allocatedBytes
        XCTAssertTrue(
            ordinaryNode.allocatedBytes == 0 || linkNode.allocatedBytes == 0,
            "exactly one directory entry owns the physical allocation"
        )
        XCTAssertEqual(result.nodes[0].allocatedBytes, hardLinkAllocation + sparseNode.allocatedBytes)
    }

    func testBulkAndFoundationProduceEquivalentMetadataAndSkipSensitivePaths() async throws {
        let fixture = try makeFixture()
        try write([1, 2, 3], to: fixture.appendingPathComponent("visible.txt"))
        try write([4], to: fixture.appendingPathComponent(".env.local"))
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent(".ssh"), withIntermediateDirectories: false)
        try write([5], to: fixture.appendingPathComponent(".ssh/id_rsa"))
        try write([6], to: fixture.appendingPathComponent("credentials.json"))
        XCTAssertEqual(symlink("visible.txt", fixture.appendingPathComponent("visible-link").path), 0)

        let foundation = try await DiskScanner.scan(root: fixture, backend: .foundation)
        DiskScannerDiagnostics.shared.reset()
        let bulk = try await DiskScanner.scan(root: fixture, backend: .bulk)
        let counters = DiskScannerDiagnostics.shared.snapshot()

        XCTAssertEqual(signature(of: bulk), signature(of: foundation))
        XCTAssertEqual(bulk.errors, [])
        XCTAssertGreaterThan(counters.bulkDirectories, 0, "bulk scans must execute getattrlistbulk")
        XCTAssertEqual(counters.bulkFallbacks, 0, "a malformed bulk parser must not be disguised by Foundation")
        XCTAssertEqual(counters.foundationDirectories, 0)
        XCTAssertEqual(foundation.skipped, 3)
        XCTAssertEqual(foundation.incompleteEvidence?.map(\.reason), [
            "excluded by sensitive path policy",
            "excluded by sensitive path policy",
            "excluded by sensitive path policy"
        ])
        XCTAssertTrue(foundation.incompleteEvidence?.allSatisfy { $0.path.hasPrefix(fixture.path + "/") } == true)
        XCTAssertFalse(foundation.nodes.contains { [".env.local", ".ssh", "credentials.json"].contains($0.name) })
        let symlinkNode = try node(named: "visible-link", in: foundation)
        XCTAssertTrue(symlinkNode.isSymlink)
        XCTAssertEqual(symlinkNode.logicalBytes, 0)
        XCTAssertEqual(symlinkNode.allocatedBytes, 0)

        let protectedRoot = try await DiskScanner.scan(root: fixture.appendingPathComponent(".ssh"))
        XCTAssertEqual(protectedRoot.skipped, 1)
        XCTAssertTrue(protectedRoot.nodes.isEmpty)

        let protectedAlias = fixture.appendingPathComponent("ssh-alias")
        XCTAssertEqual(symlink(".ssh", protectedAlias.path), 0)
        let protectedThroughSymlink = try await DiskScanner.scan(root: protectedAlias)
        XCTAssertEqual(protectedThroughSymlink.skipped, 1)
        XCTAssertTrue(protectedThroughSymlink.nodes.isEmpty)
    }

    func testProgressStartsAtRootAndCancellationIsObserved() async throws {
        let fixture = try makeFixture()
        try write([7], to: fixture.appendingPathComponent("one"))
        let progress = ProgressSink()
        _ = try await DiskScanner.scan(root: fixture, backend: .foundation) { update in
            progress.append(update)
        }
        XCTAssertEqual(progress.values.first?.entries, 1)
        XCTAssertEqual(progress.values.first?.path, fixture.path)

        let task = Task {
            try await DiskScanner.scan(root: fixture, backend: .foundation)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: the scanner checks cancellation before it reads the root.
        }
    }

    func testLiveTotalsMatchCompletedScanWithoutDoubleCountingLinks() async throws {
        let fixture = try makeFixture()
        try write([1, 2, 3], to: fixture.appendingPathComponent("nested/data"))
        XCTAssertEqual(link(fixture.appendingPathComponent("nested/data").path, fixture.appendingPathComponent("alias").path), 0)
        XCTAssertEqual(symlink("nested", fixture.appendingPathComponent("shortcut").path), 0)
        try write([9], to: fixture.appendingPathComponent(".env.test"))
        let sink = ProgressSink()
        let result = try await DiskScanner.scan(root: fixture) { sink.append($0) }
        let final = try XCTUnwrap(sink.values.last)
        XCTAssertEqual(final.entries, result.nodes.count)
        XCTAssertEqual(final.allocatedBytes, result.nodes[0].allocatedBytes)
        XCTAssertEqual(final.logicalBytes, result.nodes[0].logicalBytes)
        XCTAssertEqual(final.files, 2)
        XCTAssertEqual(final.skipped, 1)
        XCTAssertEqual(final.locations.reduce(Int64(0)) { $0 + $1.allocatedBytes }, final.allocatedBytes)
        XCTAssertLessThanOrEqual(final.locations.count, 8)
        XCTAssertFalse(final.locations.contains { $0.name == ".env.test" })
        for (earlier, later) in zip(sink.values, sink.values.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.allocatedBytes, later.allocatedBytes)
            XCTAssertLessThanOrEqual(earlier.entries, later.entries)
        }
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskbuddy-scanner-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        return root
    }

    private func write(_ bytes: [UInt8], to url: URL) throws {
        try Data(bytes).write(to: url, options: .atomic)
    }

    private func writeSparseFile(at url: URL, size: Int64) throws {
        try Data(repeating: 1, count: Int(size)).write(to: url)
        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else { throw POSIXError.fromErrno() }
        defer { close(descriptor) }
        var hole = fpunchhole_t()
        hole.fp_offset = 4 * 1024
        hole.fp_length = size - 8 * 1024
        guard fcntl(descriptor, F_PUNCHHOLE, &hole) == 0 else {
            throw XCTSkip("the temporary test volume does not support hole punching")
        }
    }

    private func node(named name: String, in result: ScanResult) throws -> DiskNode {
        try XCTUnwrap(result.nodes.first { $0.name == name })
    }

    private func signature(of result: ScanResult) -> [String] {
        result.nodes.map {
            "\($0.name)|\($0.isDirectory)|\($0.isSymlink)|\($0.logicalBytes)|\($0.allocatedBytes)|\($0.modified.timeIntervalSince1970)|\($0.device)|\($0.inode)"
        }.sorted()
    }
}

private final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ScanProgress] = []

    var values: [ScanProgress] {
        lock.withLock { updates }
    }

    func append(_ update: ScanProgress) {
        lock.withLock { updates.append(update) }
    }
}

private extension POSIXError {
    static func fromErrno() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
