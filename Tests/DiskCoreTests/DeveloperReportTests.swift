import XCTest
@testable import DiskCore

final class DeveloperReportTests: XCTestCase {
    func testAttributesArtifactsToNearestProjectAndRejectsVendoredMarkers() {
        let scan = ScanResult(rootPath: "/workspace", nodes: [
            node(0, nil, "workspace", true, children: [1]),
            node(1, 0, "outer", true, children: [2, 3, 8]),
            node(2, 1, "package.json", false),
            node(3, 1, "inner", true, children: [4, 5]),
            node(4, 3, "pyproject.toml", false),
            node(5, 3, "node_modules", true, children: [6, 7]),
            node(6, 5, "package.json", false),
            node(7, 5, "index.js", false, allocated: 50),
            node(8, 1, "DerivedData", true, children: [9]),
            node(9, 8, "build.db", false, allocated: 20)
        ])
        let groups = [
            group(.nodeModules, root: 5, bytes: 50),
            group(.buildOutputs, root: 8, bytes: 20)
        ]

        let report = DeveloperReport.build(scan: scan, groups: groups)

        XCTAssertEqual(report.findings.map(\.id), [5, 8])
        XCTAssertEqual(report.findings.map(\.projectID), [3, 1])
        XCTAssertEqual(report.projects.map(\.id), [3, 1])
        XCTAssertEqual(report.projects.map(\.allocatedBytes), [50, 20])
        XCTAssertEqual(report.projects[0].categoryBytes, [.nodeModules: 50])
        XCTAssertEqual(report.projects[1].findingIDs, [8])
    }

    func testGitMetadataDefinesAndBelongsToItsContainingProject() {
        let scan = ScanResult(rootPath: "/workspace", nodes: [
            node(0, nil, "workspace", true, children: [1]),
            node(1, 0, "project", true, children: [2, 4]),
            node(2, 1, ".git", true, children: [3]),
            node(3, 2, "pack", false, allocated: 40),
            node(4, 1, "node_modules", true, children: [5]),
            node(5, 4, "index.js", false, allocated: 10)
        ])
        let report = DeveloperReport.build(scan: scan, groups: [
            group(.gitRepositories, root: 2, bytes: 40),
            group(.nodeModules, root: 4, bytes: 10)
        ])

        XCTAssertEqual(report.projects.map(\.id), [1])
        XCTAssertEqual(report.projects.first?.allocatedBytes, 50)
        XCTAssertEqual(report.findings.first { $0.category == .gitRepositories }?.projectID, 1)
        XCTAssertEqual(report.findings.first { $0.category == .nodeModules }?.projectID, 1)
        XCTAssertTrue(report.findings.first { $0.category == .gitRepositories }?.consequence.contains("Do not remove") == true)
    }

    func testKeepsSharedStorageUnassignedAndPreservesNonoverlappingTotals() {
        let scan = ScanResult(rootPath: "/Users/ada", nodes: [
            node(0, nil, "ada", true, children: [1, 3, 5, 7]),
            node(1, 0, "project", true, children: [2]),
            node(2, 1, "package.json", false),
            node(3, 0, ".npm", true, children: [4]),
            node(4, 3, "cache", false, allocated: 31),
            node(5, 0, "models", true, children: [6]),
            node(6, 5, "weights", false, allocated: 29),
            node(7, 0, "node_modules", true, children: [8]),
            node(8, 7, "index.js", false, allocated: 17)
        ])
        let groups = [
            group(.packageCaches, root: 3, bytes: 31),
            group(.modelCaches, root: 5, bytes: 29),
            group(.nodeModules, root: 7, bytes: 17)
        ]

        let report = DeveloperReport.build(scan: scan, groups: groups)

        XCTAssertEqual(report.findings.reduce(Int64.zero) { $0 + $1.allocatedBytes }, 77)
        XCTAssertEqual(report.findings.filter { $0.category == .packageCaches || $0.category == .modelCaches }.map(\.projectID), [nil, nil])
        XCTAssertEqual(report.projects.count, 0)
        XCTAssertEqual(report.findings.map(\.allocatedBytes), [31, 29, 17])
    }

    func testProjectsOnlyIncludeRecognizedArtifactsAndUseCautiousConsequences() {
        let scan = ScanResult(rootPath: "/workspace", nodes: [
            node(0, nil, "workspace", true, children: [1, 4, 6]),
            node(1, 0, "app", true, children: [2, 3, 8]),
            node(2, 1, "Package.swift", false),
            node(3, 1, ".build", true),
            node(4, 0, "sessions", false),
            node(5, 0, "unused", false),
            node(6, 0, "vms", true),
            node(7, 6, "disk", false),
            node(8, 1, "tmp", true),
            node(9, 8, "scratch", false)
        ])
        let groups = [
            group(.buildOutputs, root: 3, bytes: 10),
            group(.claudeSessions, root: 4, bytes: 20),
            group(.containerStorage, root: 6, bytes: 30),
            group(.temporary, root: 8, bytes: 5)
        ]

        let report = DeveloperReport.build(scan: scan, groups: groups)
        let byCategory = Dictionary(uniqueKeysWithValues: report.findings.map { ($0.category, $0) })

        XCTAssertEqual(report.projects.map(\.id), [1])
        XCTAssertEqual(report.projects[0].allocatedBytes, 15)
        XCTAssertEqual(byCategory[.buildOutputs]?.confidence, "Medium")
        XCTAssertEqual(byCategory[.temporary]?.projectID, 1)
        XCTAssertTrue(byCategory[.claudeSessions]?.consequence.contains("do not auto-delete") == true)
        XCTAssertTrue(byCategory[.containerStorage]?.consequence.contains("do not auto-delete") == true)
        XCTAssertTrue(byCategory[.buildOutputs]?.consequence.contains("source and required toolchains") == true)
        XCTAssertTrue(byCategory[.temporary]?.consequence.contains("unsaved work or active-process state") == true)
        XCTAssertFalse(byCategory[.temporary]?.consequence.contains("rebuild") == true)
    }

    func testTemporaryFallbackAllowsWorktreeMarkersButRejectsFakeMarkers() {
        let temporaryTree = ScanResult(rootPath: "/tmp", nodes: [
            node(0, nil, "tmp", true, children: [1]),
            node(1, 0, "worktrees", true, children: [2, 6]),
            node(2, 1, "feature", true, children: [3, 4]),
            node(3, 2, "composer.json", false),
            node(4, 2, "node_modules", true, children: [5]),
            node(5, 4, "index.js", false, allocated: 20),
            node(6, 1, "scratch", false, allocated: 6)
        ])
        let temporaryReport = DeveloperReport.build(scan: temporaryTree, groups: [
            group(.temporary, root: 1, bytes: 6),
            group(.nodeModules, root: 4, bytes: 20)
        ])
        XCTAssertEqual(temporaryReport.findings.first { $0.id == 4 }?.projectID, 2)
        XCTAssertEqual(temporaryReport.projects.map(\.id), [2])

        let fakeMarkers = ScanResult(rootPath: "/workspace", nodes: [
            node(0, nil, "workspace", true, children: [1]),
            node(1, 0, "app", true, children: [2, 3, 4]),
            node(2, 1, "package.json", false, symlink: true),
            node(3, 1, "pyproject.toml", true),
            node(4, 1, "node_modules", true, children: [5]),
            node(5, 4, "index.js", false, allocated: 10)
        ])
        let fakeReport = DeveloperReport.build(scan: fakeMarkers, groups: [group(.nodeModules, root: 4, bytes: 10)])
        XCTAssertNil(fakeReport.findings.first?.projectID)
        XCTAssertTrue(fakeReport.projects.isEmpty)
    }

    func testRecognizesAdditionalManifestNames() {
        let scan = ScanResult(rootPath: "/workspace", nodes: [
            node(0, nil, "workspace", true, children: [1]),
            node(1, 0, "ios-app", true, children: [2, 3, 4]),
            node(2, 1, "Podfile", false),
            node(3, 1, "build.gradle.kts", false),
            node(4, 1, "Pods", true, children: [5]),
            node(5, 4, "library", false, allocated: 9)
        ])
        let report = DeveloperReport.build(scan: scan, groups: [group(.installedModules, root: 4, bytes: 9)])
        XCTAssertEqual(report.projects.map(\.id), [1])
        XCTAssertEqual(report.findings.first?.tool, "CocoaPods")
    }

    func testObservesCancellation() {
        let scan = ScanResult(rootPath: "/workspace", nodes: [node(0, nil, "workspace", true)])
        XCTAssertThrowsError(try DeveloperReport.build(scan: scan, groups: [], cancellationCheck: {
            throw CancellationError()
        }))
    }

    private func group(_ category: DeveloperCategory, root: Int, bytes: Int64) -> DeveloperGroup {
        DeveloperGroup(
            category: category,
            allocatedBytes: bytes,
            logicalBytes: bytes,
            fileCount: 1,
            rootIDs: [root],
            rootAllocatedBytes: [root: bytes]
        )
    }

    private func node(
        _ id: Int,
        _ parent: Int?,
        _ name: String,
        _ directory: Bool,
        allocated: Int64 = 0,
        symlink: Bool = false,
        children: [Int] = []
    ) -> DiskNode {
        DiskNode(
            id: id,
            parent: parent,
            name: name,
            isDirectory: directory,
            isSymlink: symlink,
            allocatedBytes: allocated,
            children: children
        )
    }
}
