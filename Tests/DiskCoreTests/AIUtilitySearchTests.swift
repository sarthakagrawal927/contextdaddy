import Foundation
import XCTest
@testable import DiskCore

final class AIUtilitySearchTests: XCTestCase {
    func testDistinguishesSessionsInTheSameProjectByIdentifier() {
        let first = session(id: "alpha-session-123")
        let second = session(id: "beta-session-456")
        XCTAssertTrue(first.matches(search: " ALPHA-SESSION-123\n"))
        XCTAssertFalse(second.matches(search: "alpha-session-123"))
        XCTAssertTrue(first.matches(search: "my-project"))
        XCTAssertTrue(first.matches(search: "codex"))
        XCTAssertTrue(first.matches(search: " \n"))
    }

    func testMissingIdentifierUsesFilenameAndStillFindsFullFilename() {
        let record = session(id: "  ", path: "/history/rollout-2026-unique.jsonl")
        XCTAssertEqual(record.historyIdentifier, "rollout-2026-unique")
        XCTAssertTrue(record.matches(search: "rollout-2026-unique.jsonl"))
        XCTAssertFalse(record.matches(search: "not-found"))
    }

    func testLongIdentifierRemainsSearchableAfterDisplayShortening() {
        let id = "12345678-1234-5678-90ab-123456789012"
        let record = session(id: id)
        XCTAssertEqual(record.historyIdentifier, id)
        XCTAssertLessThan(record.shortHistoryIdentifier.count, id.count)
        XCTAssertTrue(record.matches(search: "5678-90ab"))
    }

    func testFolderSearchFindsOnlyFoldersWithMatchingContributions() {
        let instructions = item(name: "AGENTS.md", path: "/repo/AGENTS.md", kind: .instruction)
        let skill = item(name: "SKILL.md", path: "/skills/diagram-maker/SKILL.md", kind: .skill)
        let affected = ranking(sources: [instructions, skill])
        let unrelated = ranking(sources: [item(name: "CLAUDE.md", path: "/elsewhere/CLAUDE.md", kind: .instruction)])
        XCTAssertTrue(affected.matches(search: " AGENTS.md "))
        XCTAssertFalse(unrelated.matches(search: "AGENTS.md"))
        XCTAssertTrue(affected.matches(search: "diagram-maker"))
        XCTAssertFalse(unrelated.matches(search: "diagram-maker"))
        XCTAssertTrue(affected.matches(search: "team instructions"))
        XCTAssertTrue(affected.matches(search: "codex"))
        XCTAssertTrue(affected.matches(search: " \n"))
    }

    private func session(id: String?, path: String = "/history/session.jsonl") -> AISessionRecord {
        AISessionRecord(path: path, provider: .codex, isArchived: false, project: "/repo/my-project", sessionID: id,
                        modified: .distantPast, allocatedBytes: 4096, logicalBytes: 100)
    }

    private func item(name: String, path: String, kind: AIContextKind) -> AIContextItem {
        AIContextItem(id: path, path: path, name: name, scope: .project, kind: kind, provider: .codex,
                      source: "Team instructions", logicalBytes: 100, allocatedBytes: 4096, modified: .distantPast)
    }

    private func ranking(sources: [AIContextItem]) -> AIContextFolderRanking {
        AIContextFolderRanking(id: "folder", path: "/repo/app", provider: .codex, instructionBytes: 100,
                               globalBytes: 0, inheritedBytes: 100, localBytes: 0, skillCount: 1, skillBytes: 100,
                               conditionalCount: 0, installedOnlyCount: 0,
                               sources: sources.map { AIContextContribution(item: $0, origin: .inherited) }, notes: [])
    }
}
