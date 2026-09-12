import Darwin
import Foundation
import XCTest
@testable import DiskCore

final class AISessionInventoryTests: XCTestCase {
    func testDiscoversStandardClaudeAndCodexLocations() throws {
        let home = try fixture()
        let claude = home.appendingPathComponent(".claude/projects/encoded/claude.jsonl")
        let codex = home.appendingPathComponent(".codex/sessions/2026/codex.jsonl")
        let archived = home.appendingPathComponent(".codex/archived_sessions/old.jsonl")
        let claudeContents = #"{"cwd":"/Users/ada/claude-app","sessionId":"claude-one"}"# + "\n"
        let codexContents = #"{"type":"session_meta","payload":{"cwd":"/Users/ada/codex-app","id":"codex-one"}}"# + "\n"
        let archivedContents = #"{"type":"session_meta","payload":{"cwd":"/Users/ada/old-app","id":"codex-old"}}"# + "\n"
        try write(claudeContents, to: claude)
        try write(codexContents, to: codex)
        try write(archivedContents, to: archived)
        try write("ignore", to: home.appendingPathComponent(".codex/sessions/readme.txt"))

        let report = try AISessionInventory.discover(configuration: .init(home: home))

        XCTAssertEqual(report.sessions.count, 3)
        XCTAssertEqual(report.sessions.first(where: { $0.path == claude.path })?.provider, .claude)
        XCTAssertEqual(report.sessions.first(where: { $0.path == claude.path })?.project, "/Users/ada/claude-app")
        XCTAssertEqual(report.sessions.first(where: { $0.path == codex.path })?.sessionID, "codex-one")
        XCTAssertEqual(report.sessions.first(where: { $0.path == archived.path })?.isArchived, true)
        XCTAssertEqual(
            report.sessions.reduce(0) { $0 + $1.logicalBytes },
            Int64(claudeContents.utf8.count + codexContents.utf8.count + archivedContents.utf8.count)
        )
        XCTAssertFalse(report.coverage.entryLimitReached)
        XCTAssertFalse(report.coverage.sessionLimitReached)
        XCTAssertEqual(report.coverage.existingRoots.count, 3)
        XCTAssertTrue(report.coverage.missingRoots.isEmpty)
    }

    func testSkipsSymlinkedFilesAndRoots() throws {
        let home = try fixture()
        let outside = home.appendingPathComponent("outside")
        let real = outside.appendingPathComponent("real.jsonl")
        try write(#"{"cwd":"/outside","sessionId":"unsafe"}"# + "\n", to: real)
        let claudeRoot = home.appendingPathComponent(".claude/projects")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(real.path, claudeRoot.appendingPathComponent("link.jsonl").path), 0)
        let actualCodex = home.appendingPathComponent("actual-codex")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actualCodex, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(actualCodex.path, home.appendingPathComponent(".codex/sessions").path), 0)

        let report = try AISessionInventory.discover(configuration: .init(home: home))

        XCTAssertTrue(report.sessions.isEmpty)
        XCTAssertEqual(report.coverage.skippedLinks, 2)
        XCTAssertTrue(report.coverage.isPartial)
    }

    func testReportsTraversalAndSessionLimits() throws {
        let home = try fixture()
        for index in 0..<4 {
            try write("{}\n", to: home.appendingPathComponent(".codex/sessions/\(index).jsonl"))
        }

        let entryLimited = try AISessionInventory.discover(configuration: .init(home: home, limits: .init(maximumEntries: 2, maximumSessions: 20)))
        XCTAssertTrue(entryLimited.coverage.entryLimitReached)
        XCTAssertLessThanOrEqual(entryLimited.coverage.visitedEntries, 2)

        let sessionLimited = try AISessionInventory.discover(configuration: .init(home: home, limits: .init(maximumEntries: 20, maximumSessions: 2)))
        XCTAssertEqual(sessionLimited.sessions.count, 2)
        XCTAssertTrue(sessionLimited.coverage.sessionLimitReached)
    }

    func testMissingRootsReturnCompleteEmptyInventory() throws {
        let report = try AISessionInventory.discover(configuration: .init(home: try fixture()))
        XCTAssertTrue(report.sessions.isEmpty)
        XCTAssertFalse(report.coverage.isPartial)
        XCTAssertEqual(report.coverage.roots.count, 3)
        XCTAssertTrue(report.coverage.existingRoots.isEmpty)
        XCTAssertEqual(report.coverage.missingRoots.count, 3)
    }

    private func fixture() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory.path
        let physicalTemporary = temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
        let root = URL(fileURLWithPath: physicalTemporary).appendingPathComponent("storagedaddy-session-inventory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
