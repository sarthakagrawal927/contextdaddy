import XCTest
@testable import DiskCore

final class ArchiveRankingTests: XCTestCase {
    func testBoundedRankingMatchesFullSort() {
        let values = (0..<1000).map { DiskNode(id: $0, parent: 0, name: "\($0)", isDirectory: false, logicalBytes: Int64(($0 * 37) % 997), allocatedBytes: Int64($0)) }
        var ranking = NodeRanking(limit: 25, allocated: false)
        for n in values { ranking.insert(n) }
        XCTAssertEqual(ranking.sorted.map(\.logicalBytes), values.map(\.logicalBytes).sorted(by: >).prefix(25).map { $0 })
    }
    func testArchiveRejectsDuplicateNamesAndOrphans() throws {
        let root = DiskNode(id: 0, parent: nil, name: "root", isDirectory: true, children: [1, 2])
        let a = DiskNode(id: 1, parent: 0, name: "same", isDirectory: false)
        let b = DiskNode(id: 2, parent: 0, name: "same", isDirectory: false)
        XCTAssertThrowsError(try SnapshotArchive.validate(ScanResult(rootPath: "/fixture", nodes: [root, a, b])))
        var orphanRoot = root; orphanRoot.children = []
        XCTAssertThrowsError(try SnapshotArchive.validate(ScanResult(rootPath: "/fixture", nodes: [orphanRoot, a])))
    }
    func testCompactArchivePreservesTopLevelTotals() throws {
        let nodes = [DiskNode(id: 0, parent: nil, name: "root", isDirectory: true, allocatedBytes: 8192, children: [1]), DiskNode(id: 1, parent: 0, name: "folder", isDirectory: true, allocatedBytes: 8192, children: [2]), DiskNode(id: 2, parent: 1, name: "file", isDirectory: false, allocatedBytes: 8192)]
        let compact = SnapshotArchive.compact(ScanResult(rootPath: "/fixture", nodes: nodes))
        try SnapshotArchive.validate(compact)
        XCTAssertEqual(compact.nodes.count, 2); XCTAssertEqual(compact.nodes[1].allocatedBytes, 8192)
    }
}
