import Darwin
import Foundation
import XCTest
@testable import DiskCore

final class AISessionDetailsTests: XCTestCase {
    func testReadsOnlyCodexAndClaudeMetadataFields() throws {
        let root = try fixture()
        let codex = root.appendingPathComponent(".codex/sessions/run.jsonl")
        try write("{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/Users/ada/work\",\"id\":\"codex-1\"}}\n", to: codex)
        let claude = root.appendingPathComponent(".claude/projects/hash/session.jsonl")
        try write("{\"cwd\":\"/Users/ada/app\",\"sessionId\":\"claude-1\",\"message\":\"not exposed\"}\n", to: claude)

        XCTAssertEqual(AISessionDetails.read(url: codex, tool: "Codex"), .init(project: "/Users/ada/work", sessionID: "codex-1"))
        XCTAssertEqual(AISessionDetails.read(url: claude, tool: "Claude"), .init(project: "/Users/ada/app", sessionID: "claude-1"))
    }

    func testReturnsEmptyFieldsForMalformedOrUnrecognizedInput() throws {
        let root = try fixture()
        let malformed = root.appendingPathComponent(".codex/sessions/bad.jsonl")
        try write("{not json}\n", to: malformed)
        let other = root.appendingPathComponent("notes.jsonl")
        try write("{\"cwd\":\"/Users/ada/private\"}\n", to: other)

        XCTAssertEqual(AISessionDetails.read(url: malformed, tool: "Codex"), .init())
        XCTAssertEqual(AISessionDetails.read(url: other, tool: "Claude"), .init())
        XCTAssertEqual(AISessionDetails.read(url: malformed, tool: "Unknown"), .init())

        let invalidCWD = root.appendingPathComponent(".codex/sessions/control.jsonl")
        try write("{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/Users/ada\\nbad\",\"id\":\"safe-id\"}}\n", to: invalidCWD)
        XCTAssertEqual(AISessionDetails.read(url: invalidCWD, tool: "Codex"), .init(project: nil, sessionID: "safe-id"))
    }

    func testRejectsSymlinkLeafAndAncestor() throws {
        let root = try fixture()
        let codexRoot = root.appendingPathComponent(".codex")
        let actualSessions = codexRoot.appendingPathComponent("actual-sessions")
        try FileManager.default.createDirectory(at: actualSessions, withIntermediateDirectories: true)
        let actual = actualSessions.appendingPathComponent("run.jsonl")
        try write("{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/safe\",\"id\":\"one\"}}\n", to: actual)

        let alias = codexRoot.appendingPathComponent("sessions")
        XCTAssertEqual(symlink("actual-sessions", alias.path), 0)
        XCTAssertEqual(AISessionDetails.read(url: alias.appendingPathComponent("run.jsonl"), tool: "Codex"), .init())

        let direct = root.appendingPathComponent(".codex/archived_sessions")
        try FileManager.default.createDirectory(at: direct, withIntermediateDirectories: true)
        let leaf = direct.appendingPathComponent("real.jsonl")
        try write("{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/safe\",\"id\":\"two\"}}\n", to: leaf)
        let leafAlias = direct.appendingPathComponent("link.jsonl")
        XCTAssertEqual(symlink("real.jsonl", leafAlias.path), 0)
        XCTAssertEqual(AISessionDetails.read(url: leafAlias, tool: "Codex"), .init())
    }

    func testReadCapDoesNotSearchPastFirst64KiB() throws {
        let root = try fixture()
        let session = root.appendingPathComponent(".claude/projects/hash/large.jsonl")
        var data = Data(repeating: 0x78, count: 64 * 1024)
        data.append(Data("\n{\"cwd\":\"/after-cap\",\"sessionId\":\"late\"}\n".utf8))
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: session)

        XCTAssertEqual(AISessionDetails.read(url: session, tool: "Claude"), .init())
    }

    func testReadsCurrentCodexMetadataLineLargerThan16KiB() throws {
        let root = try fixture()
        let session = root.appendingPathComponent(".codex/sessions/current.jsonl")
        let instructions = String(repeating: "x", count: 20 * 1024)
        let line = #"{"type":"session_meta","payload":{"base_instructions":"\#(instructions)","cwd":"/Users/ada/current","id":"current-id"}}"# + "\n"
        try write(line, to: session)

        XCTAssertEqual(
            AISessionDetails.read(url: session, tool: "Codex"),
            .init(project: "/Users/ada/current", sessionID: "current-id")
        )
    }

    private func fixture() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory.path
        let physicalTemporary = temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
        let root = URL(fileURLWithPath: physicalTemporary)
            .appendingPathComponent("storagedaddy-ai-session-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }
}
