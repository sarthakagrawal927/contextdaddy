import Foundation
import XCTest
@testable import DiskCore

final class SkillDocumentReaderTests: XCTestCase {
    func testSelectedAgentDefinitionCanBePreviewedWithoutAllowingArbitraryConfigReads() throws {
        let url = try fixture(name: "reviewer.toml", data: Data("description = \"Review changes\"".utf8))
        XCTAssertThrowsError(try SkillDocumentReader.read(url: url))
        XCTAssertEqual(try SkillDocumentReader.read(url: url, documentKind: .agentDefinition).text,
                       "description = \"Review changes\"")
    }

    func testSelectedNestedRuleCanBePreviewed() throws {
        let url = try fixture(name: "style.md", data: Data("Use readable names.".utf8))
        XCTAssertEqual(try SkillDocumentReader.read(url: url, documentKind: .rule).text, "Use readable names.")
    }

    func testReadsAllowedTextAndReportsByteLimit() throws {
        let url = try fixture(name: "SKILL.md", data: Data(repeating: 97, count: SkillDocumentReader.maximumBytes + 19))

        let document = try SkillDocumentReader.read(url: url)

        XCTAssertEqual(document.bytesRead, SkillDocumentReader.maximumBytes)
        XCTAssertTrue(document.truncated)
        XCTAssertEqual(document.text.utf8.count, SkillDocumentReader.maximumBytes)
    }

    func testRejectsBinaryContent() throws {
        let url = try fixture(name: "SKILL.md", data: Data([35, 32, 0, 10]))

        XCTAssertThrowsError(try SkillDocumentReader.read(url: url)) { error in
            XCTAssertEqual(error as? SkillDocumentReadError, .binary)
        }
    }

    func testTrimsIncompleteUnicodeScalarAtCap() throws {
        let prefix = String(repeating: "a", count: SkillDocumentReader.maximumBytes - 3)
        let url = try fixture(name: "SKILL.md", data: Data((prefix + "😀").utf8))

        let document = try SkillDocumentReader.read(url: url)

        XCTAssertTrue(document.truncated)
        XCTAssertEqual(document.text, prefix)
        XCTAssertEqual(document.bytesRead, SkillDocumentReader.maximumBytes - 3)
    }

    func testReadsEmptyFile() throws {
        let url = try fixture(name: "SKILL.md", data: Data())

        let document = try SkillDocumentReader.read(url: url)

        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.bytesRead, 0)
        XCTAssertFalse(document.truncated)
    }

    func testRejectsDirectory() throws {
        let directory = try fixtureDirectory()
        let url = directory.appendingPathComponent("SKILL.md", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        XCTAssertThrowsError(try SkillDocumentReader.read(url: url)) { error in
            XCTAssertEqual(error as? SkillDocumentReadError, .notRegularFile)
        }
    }

    func testRejectsUnsupportedFiles() throws {
        let url = try fixture(name: "settings.json", data: Data("{}".utf8))

        XCTAssertThrowsError(try SkillDocumentReader.read(url: url)) { error in
            XCTAssertEqual(error as? SkillDocumentReadError, .unsupportedFile)
        }
    }

    func testReadsClaudeRulesButRejectsArbitraryMarkdown() throws {
        let directory = try fixtureDirectory()
        let rules = directory.appendingPathComponent(".claude/rules", isDirectory: true)
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        let rule = rules.appendingPathComponent("testing.md")
        try Data("Use focused tests.".utf8).write(to: rule)
        XCTAssertEqual(try SkillDocumentReader.read(url: rule).text, "Use focused tests.")

        let arbitrary = directory.appendingPathComponent("notes.md")
        try Data("private notes".utf8).write(to: arbitrary)
        XCTAssertThrowsError(try SkillDocumentReader.read(url: arbitrary)) { error in
            XCTAssertEqual(error as? SkillDocumentReadError, .unsupportedFile)
        }
    }

    func testRejectsSymlinkedSkill() throws {
        let directory = try fixtureDirectory()
        let target = directory.appendingPathComponent("real.md")
        let link = directory.appendingPathComponent("SKILL.md")
        try Data("safe".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SkillDocumentReader.read(url: link)) { error in
            XCTAssertTrue(error as? SkillDocumentReadError == .symlink || error as? SkillDocumentReadError == .changedDuringRead)
        }
    }

    private func fixture(name: String, data: Data) throws -> URL {
        let directory = try fixtureDirectory()
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func fixtureDirectory() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
            .replacingOccurrences(of: "/var/", with: "/private/var/")
        let directory = URL(fileURLWithPath: temporaryPath, isDirectory: true)
            .appendingPathComponent("storagedaddy-skill-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
