import Foundation
import Testing
@testable import ContextCore

struct SkillSharingTests {
    @Test func createsOneLinkAndNeverReplacesAnOccupiedDestination() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("contextdaddy-share-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("source/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: demo\n---\n".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let record = skill(at: source)

        #expect(SkillSharing.plan(for: record, target: .claude, home: home).status == .available)
        let destination = try SkillSharing.createLink(for: record, target: .claude, home: home)
        #expect(destination.resolvingSymlinksInPath().standardizedFileURL == source.standardizedFileURL)
        let report = try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: []))
        #expect(report.items.contains {
            $0.path == destination.appendingPathComponent("SKILL.md").path
                && $0.resolvedPath == source.appendingPathComponent("SKILL.md").path
        })
        #expect(SkillSharing.plan(for: record, target: .claude, home: home).status == .alreadyShared)
        #expect(throws: SkillShareError.self) {
            try SkillSharing.createLink(for: record, target: .claude, home: home)
        }

        let occupied = home.appendingPathComponent(".codex/skills/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        #expect(SkillSharing.plan(for: record, target: .codex, home: home).status == .occupied)
        #expect(throws: SkillShareError.self) {
            try SkillSharing.createLink(for: record, target: .codex, home: home)
        }
        #expect(try String(contentsOf: source.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("demo"))
    }

    @Test func refusesManagedCacheAndLinkedDestinationParent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("contextdaddy-share-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("source/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "demo".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        #expect(SkillSharing.plan(for: skill(at: source, installedOnly: true), target: .grok, home: home).status
                == .unavailable("This definition belongs to a managed installation or cache."))
        let cacheSource = home.appendingPathComponent(".codex/plugins/cache/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheSource, withIntermediateDirectories: true)
        try "demo".write(to: cacheSource.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        #expect(SkillSharing.plan(for: skill(at: cacheSource), target: .grok, home: home).status
                == .unavailable("This definition belongs to a managed installation or cache."))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".cursor"), withDestinationURL: source)
        #expect(SkillSharing.plan(for: skill(at: source), target: .cursor, home: home).status
                == .unavailable("A destination parent is a link or is not a directory."))
    }

    private func skill(at source: URL, installedOnly: Bool = false) -> SkillRecord {
        let file = source.appendingPathComponent("SKILL.md").path
        return SkillRecord(id: file, name: source.lastPathComponent, description: "Fixture", logicalBytes: 12,
                           modified: .distantPast,
                           exposures: [SkillExposure(logicalPath: file, resolvedPath: file, source: "Fixture",
                                                     scope: .global, provider: .codex,
                                                     applicability: installedOnly ? .installedOnly : .conditional)],
                           policies: [])
    }
}
