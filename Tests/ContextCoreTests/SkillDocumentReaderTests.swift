import Foundation
import Testing
@testable import ContextCore

struct SkillDocumentReaderTests {
    @Test func previewsEligibleTextAndCapsLargeDocuments() throws {
        let fixture = try TemporaryFixture()
        let url = try fixture.write(name: "SKILL.md", data: Data(repeating: 97, count: SkillDocumentReader.maximumBytes + 12))
        let document = try SkillDocumentReader.read(url: url)
        #expect(document.truncated)
        #expect(document.bytesRead == SkillDocumentReader.maximumBytes)
    }

    @Test func selectedAgentDefinitionsAreAllowedButArbitraryConfigIsNot() throws {
        let fixture = try TemporaryFixture()
        let url = try fixture.write(name: "reviewer.toml", data: Data("description = \"Review\"".utf8))
        #expect(throws: SkillDocumentReadError.unsupportedFile) { try SkillDocumentReader.read(url: url) }
        #expect(try SkillDocumentReader.read(url: url, documentKind: .agentDefinition).text == "description = \"Review\"")
    }

    @Test func rejectsBinaryAndSymlinkedDocuments() throws {
        let fixture = try TemporaryFixture()
        let binary = try fixture.write(name: "SKILL.md", data: Data([35, 0, 10]))
        #expect(throws: SkillDocumentReadError.binary) { try SkillDocumentReader.read(url: binary) }

        let target = try fixture.write(name: "target.md", data: Data("safe".utf8))
        let link = fixture.root.appendingPathComponent("AGENTS.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: SkillDocumentReadError.self) { try SkillDocumentReader.read(url: link) }
    }
}

private final class TemporaryFixture {
    let root: URL

    init() throws {
        let physicalTemporaryPath = FileManager.default.temporaryDirectory.path
            .replacingOccurrences(of: "/var/", with: "/private/var/")
        root = URL(fileURLWithPath: physicalTemporaryPath, isDirectory: true)
            .appendingPathComponent("contextdaddy-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(name: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
