import Foundation
import XCTest
@testable import DiskCore

final class FolderExclusionsTests: XCTestCase {
    func testComponentBoundariesAndVolumeAliases() {
        let exclusions = FolderExclusions(paths: ["/Users/test/Keep", "/Users/test/Keep/../Keep", "relative"])
        XCTAssertEqual(exclusions.paths, ["/Users/test/Keep"])
        XCTAssertTrue(exclusions.contains("/Users/test/Keep/child"))
        XCTAssertTrue(exclusions.contains("/System/Volumes/Data/Users/test/Keep"))
        XCTAssertFalse(exclusions.contains("/Users/test/Keeper"))
        XCTAssertFalse(exclusions.contains("/Users/test/keep"))
        XCTAssertTrue(exclusions.blocksCleanup(URL(fileURLWithPath: "/Users/test")))
        XCTAssertFalse(exclusions.blocksCleanup(URL(fileURLWithPath: "/Users/test/Keeper")))
        XCTAssertTrue(FolderExclusions(paths: ["/"]).contains("/anything"))
    }

    func testAllBackendsSkipExcludedSubtreeAndRejectExcludedRoot() async throws {
        let root = try fixture()
        let keep = root.appendingPathComponent("parent/Keep")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: keep)
        for backend: ScanBackend in [.foundation, .bulk, .parallel] {
            let result = try await DiskScanner.scan(root: root, backend: backend, excludedFolders: [alias.path])
            XCTAssertFalse(result.nodes.contains { $0.name == "Keep" || $0.name == "private.txt" })
            XCTAssertTrue(result.nodes.contains { $0.name == "Keeper" })
            XCTAssertEqual(result.skipped, 2)
            XCTAssertTrue(result.incompleteEvidence?.allSatisfy { $0.reason == "excluded by folder settings" } == true)
            let excluded = try await DiskScanner.scan(root: keep, backend: backend, excludedFolders: [alias.path])
            XCTAssertTrue(excluded.nodes.isEmpty)
        }
    }

    func testCleanupRejectsExcludedParentEvenWithOlderCompleteScan() async throws {
        let root = try fixture()
        let scan = try await DiskScanner.scan(root: root)
        let parent = try XCTUnwrap(scan.nodes.first { $0.name == "parent" })
        let keep = root.appendingPathComponent("parent/Keep")
        do {
            try await CleanupPreflight.validate(ids: [parent.id], in: scan, excludedFolders: [keep.path])
            XCTFail("A parent move must not include an excluded folder")
        } catch CleanupPreflightError.excludedFolder { }
        let sibling = try XCTUnwrap(scan.nodes.first { $0.name == "Keeper" })
        try await CleanupPreflight.validate(ids: [sibling.id], in: scan, excludedFolders: [keep.path])
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageDaddy-exclusions-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("parent/Keep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("parent/Keeper"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("parent/Keep/private.txt"))
        return root
    }
}
