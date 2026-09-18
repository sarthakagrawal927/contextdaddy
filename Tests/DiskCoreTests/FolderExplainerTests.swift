import Foundation
import XCTest
@testable import DiskCore

final class FolderExplainerTests: XCTestCase {
    private let home = "/Users/test"

    private func exists(_ paths: [String]) -> (String) -> Bool {
        let set = Set(paths)
        return { set.contains($0) }
    }

    func testDetectsClaudeAndCodexInPreferenceOrder() {
        let agents = FolderExplainer.detectAgents(
            exists: exists(["/opt/homebrew/bin/claude", "/usr/local/bin/codex"]),
            environment: [:], home: home,
        )
        XCTAssertEqual(agents.map(\.0), [.claude, .codex])
        XCTAssertEqual(agents[0].1.path, "/opt/homebrew/bin/claude")
        XCTAssertEqual(agents[1].1.path, "/usr/local/bin/codex")
    }

    func testDetectsNativeInstallLocationsAndPath() {
        let local = FolderExplainer.detectAgents(
            exists: exists(["/Users/test/.local/bin/claude", "/Users/test/.claude/local/claude"]),
            environment: [:], home: home,
        )
        XCTAssertEqual(local.count, 1)
        XCTAssertEqual(local[0].1.path, "/Users/test/.local/bin/claude")

        let onPath = FolderExplainer.detectAgents(
            exists: exists(["/custom/bin/codex"]),
            environment: ["PATH": "/usr/bin:/custom/bin"], home: home,
        )
        XCTAssertEqual(onPath.map(\.0), [.codex])
        XCTAssertEqual(onPath[0].1.path, "/custom/bin/codex")
    }

    func testDetectsNothingWhenNoAgentExists() {
        XCTAssertTrue(FolderExplainer.detectAgents(exists: exists([]), environment: [:], home: home).isEmpty)
    }

    func testAgentArgumentsAreNonInteractiveAndReadOnly() {
        let prompt = "explain this folder"
        XCTAssertEqual(
            FolderAgent.claude.arguments(prompt: prompt),
            ["-p", prompt, "--allowedTools", "Read,Glob,Grep,LS"],
        )
        XCTAssertEqual(
            FolderAgent.codex.arguments(prompt: prompt),
            ["exec", "--sandbox", "read-only", prompt],
        )
    }

    func testPromptCarriesMeasurementsAndSafetyBoundary() {
        let prompt = FolderExplainer.prompt(
            path: "/Users/test/Library/Caches",
            allocatedBytes: 1_500_000_000,
            logicalBytes: 1_200_000_000,
            children: 42,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
        )
        XCTAssertTrue(prompt.contains("/Users/test/Library/Caches"))
        XCTAssertTrue(prompt.contains(DiskFormat.bytes(1_500_000_000)))
        XCTAssertTrue(prompt.contains("42"))
        XCTAssertTrue(prompt.contains("Do not delete or modify anything"))
    }

    private func task(_ executable: String, argv: [String], timeout: TimeInterval = 10) throws -> FolderExplainTask {
        try FolderExplainTask(
            agent: .claude, executable: URL(fileURLWithPath: executable),
            argv: argv, timeout: timeout, maxOutputBytes: 65_536,
        )
    }

    func testRunReturnsAgentOutput() throws {
        let result = try self.task("/bin/echo", argv: ["hello"]).wait()
        XCTAssertEqual(result.text, "hello")
        XCTAssertGreaterThanOrEqual(result.elapsed, 0)
    }

    func testRunSurfacesNonZeroExit() throws {
        XCTAssertThrowsError(try self.task("/usr/bin/false", argv: []).wait()) { error in
            guard case .nonZeroExit(let code, _) = error as? FolderExplanationError else {
                return XCTFail("expected nonZeroExit, got \(error)")
            }
            XCTAssertEqual(code, 1)
        }
    }

    func testRunTimesOutAndTerminates() throws {
        XCTAssertThrowsError(try self.task("/bin/sleep", argv: ["30"], timeout: 0.1).wait()) { error in
            XCTAssertEqual(error as? FolderExplanationError, .timedOut)
        }
    }

    func testCancelTerminatesTheProcess() throws {
        let task = try self.task("/bin/sleep", argv: ["30"], timeout: 30)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { task.cancel() }
        XCTAssertThrowsError(try task.wait()) { error in
            XCTAssertEqual(error as? FolderExplanationError, .cancelled)
        }
    }

    func testRunRejectsEmptyOutput() throws {
        XCTAssertThrowsError(try self.task("/usr/bin/true", argv: []).wait()) { error in
            XCTAssertEqual(error as? FolderExplanationError, .emptyOutput)
        }
    }

    func testRunCapsLargeOutput() throws {
        let result = try self.task("/bin/sh", argv: ["-c", "yes X | head -c 200000"], timeout: 15).wait()
        XCTAssertGreaterThan(result.text.count, 60_000)
        XCTAssertLessThanOrEqual(result.text.count, 65_536)
    }
}
