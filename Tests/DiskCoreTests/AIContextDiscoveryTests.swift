import XCTest
@testable import DiskCore

final class AIContextDiscoveryTests: XCTestCase {
    func testDiscoversWithoutStorageScanAndDoesNotLeakSiblingInstructions() throws {
        let fixture = try Fixture()
        try fixture.write("global", at: ".codex/AGENTS.md")
        try fixture.write("parent", at: "Projects/repo/AGENTS.md")
        try fixture.write("child", at: "Projects/repo/app/AGENTS.md")
        try fixture.write("sibling", at: "Projects/other/AGENTS.md")
        try fixture.directory("Projects/repo/.git")
        let report = try AIContextDiscovery.discover(configuration: fixture.configuration())
        let app = try XCTUnwrap(report.folderRankings.first { $0.path.hasSuffix("/Projects/repo") && $0.provider == .codex })
        XCTAssertTrue(app.sources.contains { $0.item.path.hasSuffix("repo/AGENTS.md") })
        XCTAssertFalse(app.sources.contains { $0.item.path.hasSuffix("other/AGENTS.md") })
        XCTAssertTrue(report.items.contains { $0.path.hasSuffix(".codex/AGENTS.md") })
    }

    func testCodexOverrideDoesNotDoubleCountDirectoryAgentsFile() throws {
        let fixture = try Fixture()
        try fixture.directory("Projects/repo/.git")
        try fixture.write(String(repeating: "a", count: 10), at: "Projects/repo/AGENTS.md")
        try fixture.write(String(repeating: "b", count: 20), at: "Projects/repo/AGENTS.override.md")
        let report = try AIContextDiscovery.discover(configuration: fixture.configuration())
        let row = try XCTUnwrap(report.folderRankings.first { $0.path.hasSuffix("/Projects/repo") && $0.provider == .codex })
        XCTAssertEqual(row.localBytes, 20)
        XCTAssertEqual(row.sources.filter { $0.item.path.hasSuffix("AGENTS.md") || $0.item.path.hasSuffix("AGENTS.override.md") }.count, 1)
    }

    func testSkillSymlinkIsDeduplicatedAndRetainsResolvedPath() throws {
        let fixture = try Fixture()
        try fixture.write("---\nname: x\n---", at: "tooling/skills/example/SKILL.md")
        try fixture.directory(".agents")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(".agents/skills"), withDestinationURL: fixture.root.appendingPathComponent("tooling/skills"))
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("tooling/skills/cycle"), withDestinationURL: fixture.root.appendingPathComponent("tooling/skills"))
        let report = try AIContextDiscovery.discover(configuration: fixture.configuration())
        let skills = report.items.filter { $0.kind == .skill }
        XCTAssertEqual(skills.count, 1)
        XCTAssertTrue(try XCTUnwrap(skills.first?.path).hasSuffix(".agents/skills/example/SKILL.md"))
        XCTAssertTrue(try XCTUnwrap(skills.first?.resolvedPath).hasSuffix("tooling/skills/example/SKILL.md"))
    }

    func testLinkedSkillFolderOutsideSkillsRootPreservesAliasAndPhysicalTarget() throws {
        let fixture = try Fixture()
        let external = fixture.root.appendingPathComponent("shared/external-skill")
        try fixture.write("---\nname: external\n---", at: "shared/external-skill/SKILL.md")
        try fixture.directory(".agents/skills")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(".agents/skills/external"),
            withDestinationURL: external
        )

        let report = try AIContextDiscovery.discover(configuration: fixture.configuration(projectRoots: []))
        let skill = try XCTUnwrap(report.items.first { $0.name == "external" })

        XCTAssertTrue(skill.path.hasSuffix(".agents/skills/external/SKILL.md"))
        XCTAssertEqual(skill.resolvedPath, external.appendingPathComponent("SKILL.md").path)
    }

    func testLinkedSkillFilePreservesAliasAndPhysicalTarget() throws {
        let fixture = try Fixture()
        try fixture.write("---\nname: file-link\n---", at: "shared/SKILL.md")
        try fixture.directory(".agents/skills/file-link")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(".agents/skills/file-link/SKILL.md"),
            withDestinationURL: fixture.root.appendingPathComponent("shared/SKILL.md")
        )

        let report = try AIContextDiscovery.discover(configuration: fixture.configuration(projectRoots: []))
        let skill = try XCTUnwrap(report.items.first { $0.name == "file-link" })

        XCTAssertTrue(skill.path.hasSuffix(".agents/skills/file-link/SKILL.md"))
        XCTAssertEqual(skill.resolvedPath, fixture.root.appendingPathComponent("shared/SKILL.md").path)
    }

    func testDiscoversProviderPluginsAgentsAndNestedRulesWithoutReadingBodies() throws {
        let fixture = try Fixture()
        try fixture.write("codex plugin", at: ".codex/plugins/cache/vendor/plugin/skills/codex/SKILL.md")
        try fixture.write("claude plugin", at: ".claude/plugins/cache/vendor/plugin/skills/claude/SKILL.md")
        try fixture.write("agent", at: ".claude/agents/review.md")
        try fixture.write("agent", at: ".codex/agents/review.toml")
        try fixture.write("rule", at: ".claude/rules/nested/swift.md")

        let report = try AIContextDiscovery.discover(configuration: fixture.configuration(projectRoots: []))

        XCTAssertTrue(report.items.contains { $0.path.hasSuffix("codex/SKILL.md") && $0.provider == .codex && $0.applicability == .installedOnly })
        XCTAssertTrue(report.items.contains { $0.path.hasSuffix("claude/SKILL.md") && $0.provider == .claude && $0.applicability == .installedOnly })
        XCTAssertEqual(report.items.filter { $0.kind == .agentDefinition }.count, 2)
        XCTAssertTrue(report.items.contains { $0.path.hasSuffix("rules/nested/swift.md") && $0.kind == .rule && $0.scope == .global })
    }

    func testPluginRootSymlinkToSensitiveDirectoryIsRejected() throws {
        let fixture = try Fixture()
        try fixture.write("secret skill", at: ".ssh/plugin-cache/tool/SKILL.md")
        try fixture.directory(".codex/plugins")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(".codex/plugins/cache"),
            withDestinationURL: fixture.root.appendingPathComponent(".ssh/plugin-cache")
        )

        let report = try AIContextDiscovery.discover(configuration: fixture.configuration(projectRoots: []))

        XCTAssertFalse(report.items.contains { $0.resolvedPath?.contains("/.ssh/") == true })
        XCTAssertGreaterThan(report.coverage.skippedLinks, 0)
        XCTAssertTrue(report.coverage.isPartial)
    }

    func testDiscoveryReportsDepthAndPluginCaps() throws {
        let fixture = try Fixture()
        try fixture.directory("Projects/one/two")
        try fixture.write("deep", at: "Projects/one/two/AGENTS.md")
        try fixture.write("one", at: ".codex/plugins/cache/a/SKILL.md")
        try fixture.write("two", at: ".codex/plugins/cache/b/SKILL.md")
        var limits = AIContextDiscovery.Limits()
        limits.maximumProjectDepth = 0
        limits.maximumPluginEntries = 20
        limits.maximumPluginItems = 1

        let report = try AIContextDiscovery.discover(configuration: fixture.configuration(limits: limits))

        XCTAssertTrue(report.coverage.projectDepthReached)
        XCTAssertTrue(report.coverage.pluginItemLimitReached)
        XCTAssertTrue(report.coverage.isPartial)
    }

    func testAvailableSkillAliasWinsOverInstalledPluginAliasInRanking() throws {
        let fixture = try Fixture()
        try fixture.directory("Projects/repo/.git")
        try fixture.write("skill", at: "shared/skill/SKILL.md")
        try fixture.directory(".agents/skills")
        try fixture.directory(".codex/plugins/cache/plugin/skills")
        let target = fixture.root.appendingPathComponent("shared/skill")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(".agents/skills/shared"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(".codex/plugins/cache/plugin/skills/shared"), withDestinationURL: target)

        let report = try AIContextDiscovery.discover(configuration: fixture.configuration())
        let codex = try XCTUnwrap(report.folderRankings.first { $0.path.hasSuffix("Projects/repo") && $0.provider == .codex })

        XCTAssertEqual(codex.skillCount, 1)
        XCTAssertEqual(codex.installedOnlyCount, 0)
        XCTAssertTrue(codex.sources.contains { $0.item.path.hasSuffix(".agents/skills/shared/SKILL.md") })
    }

    func testEntryBudgetAndSensitiveTreesAreReported() throws {
        let fixture = try Fixture()
        try fixture.write("ignored", at: "Projects/repo/.ssh/AGENTS.md")
        try fixture.write("kept", at: "Projects/repo/AGENTS.md")
        var limits = AIContextDiscovery.Limits(); limits.maximumEntries = 1
        let report = try AIContextDiscovery.discover(configuration: fixture.configuration(limits: limits))
        XCTAssertTrue(report.coverage.entryLimitReached)
        XCTAssertFalse(report.items.contains { $0.path.contains(".ssh") })
    }

    func testCancellationIsObservedBeforeFilesystemWork() async throws {
        let fixture = try Fixture()
        let task = Task { try AIContextDiscovery.discover(configuration: fixture.configuration()) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testProjectSkillAppliesToProjectAndGlobalAgentsSkillIsAvailableToCodex() throws {
        let fixture = try Fixture()
        try fixture.directory("Projects/repo/.git")
        try fixture.write("project", at: "Projects/repo/.agents/skills/project/SKILL.md")
        try fixture.write("global", at: ".agents/skills/global/SKILL.md")
        let report = try AIContextDiscovery.discover(configuration: fixture.configuration())
        let codex = try XCTUnwrap(report.folderRankings.first { $0.path.hasSuffix("Projects/repo") && $0.provider == .codex })
        XCTAssertEqual(codex.skillCount, 2)
        XCTAssertEqual(codex.instructionBytes, 0)
    }

    func testClaudeDotDirectoryBelongsToContainingProjectAndRepoBoundaryStopsParent() throws {
        let fixture = try Fixture()
        try fixture.directory("Projects/outer/.git")
        try fixture.write("outer", at: "Projects/outer/CLAUDE.md")
        try fixture.directory("Projects/outer/nested/.git")
        try fixture.write("nested", at: "Projects/outer/nested/.claude/CLAUDE.md")
        let report = try AIContextDiscovery.discover(configuration: fixture.configuration())
        let nested = try XCTUnwrap(report.folderRankings.first { $0.path.hasSuffix("outer/nested") && $0.provider == .claude })
        XCTAssertEqual(nested.localBytes, 6)
        XCTAssertEqual(nested.inheritedBytes, 5)
    }

    func testManuallyAddedNestedFolderIncludesParentAndLocalInstructionsWithoutSiblingWalk() throws {
        let fixture = try Fixture()
        try fixture.directory("Projects/repo/.git")
        try fixture.write("parent-codex", at: "Projects/repo/AGENTS.md")
        try fixture.write("local-codex", at: "Projects/repo/app/AGENTS.md")
        try fixture.write("parent-claude", at: "Projects/repo/CLAUDE.md")
        try fixture.write("local-claude", at: "Projects/repo/app/CLAUDE.md")
        try fixture.write("sibling", at: "Projects/sibling/AGENTS.md")

        let selected = fixture.root.appendingPathComponent("Projects/repo/app")
        let report = try AIContextDiscovery.discover(configuration: fixture.configuration(
            projectRoots: [], additionalRoots: [selected]
        ))

        let codex = try XCTUnwrap(report.folderRankings.first { $0.path == selected.path && $0.provider == .codex })
        XCTAssertTrue(codex.sources.contains { $0.item.path.hasSuffix("repo/AGENTS.md") && $0.origin == .inherited })
        XCTAssertTrue(codex.sources.contains { $0.item.path.hasSuffix("repo/app/AGENTS.md") && $0.origin == .local })
        XCTAssertFalse(report.items.contains { $0.path.hasSuffix("sibling/AGENTS.md") })

        let claude = try XCTUnwrap(report.folderRankings.first { $0.path == selected.path && $0.provider == .claude })
        XCTAssertTrue(claude.sources.contains { $0.item.path.hasSuffix("repo/CLAUDE.md") && $0.origin == .inherited })
        XCTAssertTrue(claude.sources.contains { $0.item.path.hasSuffix("repo/app/CLAUDE.md") && $0.origin == .local })
    }

    func testManuallyAddedFolderKeepsCodexInheritanceInsideNearestGitRoot() throws {
        let fixture = try Fixture()
        try fixture.directory("Projects/outer/.git")
        try fixture.write("outer", at: "Projects/outer/AGENTS.md")
        try fixture.directory("Projects/outer/nested/.git")
        try fixture.write("nested", at: "Projects/outer/nested/AGENTS.md")
        try fixture.write("local", at: "Projects/outer/nested/app/AGENTS.md")
        let selected = fixture.root.appendingPathComponent("Projects/outer/nested/app")

        let report = try AIContextDiscovery.discover(configuration: fixture.configuration(
            projectRoots: [], additionalRoots: [selected]
        ))
        let codex = try XCTUnwrap(report.folderRankings.first { $0.path == selected.path && $0.provider == .codex })

        XCTAssertFalse(codex.sources.contains { $0.item.path.hasSuffix("outer/AGENTS.md") })
        XCTAssertTrue(codex.sources.contains { $0.item.path.hasSuffix("outer/nested/AGENTS.md") && $0.origin == .inherited })
        XCTAssertTrue(codex.sources.contains { $0.item.path.hasSuffix("nested/app/AGENTS.md") && $0.origin == .local })
    }

    func testManuallyAddedFolderOutsideHomeDiscoversExactAncestors() throws {
        let fixture = try Fixture()
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("storagedaddy-external-context-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(at: external.appendingPathComponent("repo/app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        try Data("external".utf8).write(to: external.appendingPathComponent("repo/AGENTS.md"))
        let selected = external.appendingPathComponent("repo/app")

        let report = try AIContextDiscovery.discover(configuration: fixture.configuration(
            projectRoots: [], additionalRoots: [selected]
        ))
        let codex = try XCTUnwrap(report.folderRankings.first { $0.path == selected.path && $0.provider == .codex })

        XCTAssertTrue(codex.sources.contains { $0.item.path == external.appendingPathComponent("repo/AGENTS.md").path })
    }

    func testAncestorClaudeDirectorySymlinkDoesNotContributeInstructions() throws {
        let fixture = try Fixture()
        try fixture.directory("Projects/repo/app")
        try fixture.write("outside", at: "Elsewhere/CLAUDE.md")
        try fixture.write("local", at: "Projects/repo/app/CLAUDE.md")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("Projects/repo/.claude"),
            withDestinationURL: fixture.root.appendingPathComponent("Elsewhere")
        )
        let selected = fixture.root.appendingPathComponent("Projects/repo/app")
        let report = try AIContextDiscovery.discover(configuration: fixture.configuration(projectRoots: [], additionalRoots: [selected]))
        let row = try XCTUnwrap(report.folderRankings.first { $0.path == selected.path && $0.provider == .claude })
        XCTAssertFalse(row.sources.contains { $0.item.path.contains("repo/.claude/") })
        XCTAssertTrue(row.sources.contains { $0.item.path.hasSuffix("app/CLAUDE.md") && $0.origin == .local })
    }

    func testStartupContextPressureUsesApproximateInstructionTokens() {
        XCTAssertEqual(AIContextPressure.classify(estimatedTokens: 7_999), .light)
        XCTAssertEqual(AIContextPressure.classify(estimatedTokens: 8_000), .elevated)
        XCTAssertEqual(AIContextPressure.classify(estimatedTokens: 19_999), .elevated)
        XCTAssertEqual(AIContextPressure.classify(estimatedTokens: 20_000), .heavy)

        let ranking = AIContextFolderRanking(
            id: "Codex:/tmp/project", path: "/tmp/project", provider: .codex,
            instructionBytes: 32_001, globalBytes: 1, inheritedBytes: 16_000, localBytes: 16_000,
            skillCount: 40, skillBytes: 1_000_000, conditionalCount: 40, installedOnlyCount: 0,
            sources: [AIContextContribution(item: AIContextItem(
                id: "local", path: "/tmp/project/AGENTS.md", name: "AGENTS.md", scope: .project,
                kind: .instruction, provider: .codex, logicalBytes: 16_000, allocatedBytes: 16_384,
                modified: .distantPast
            ), origin: .local)],
            notes: []
        )
        XCTAssertEqual(ranking.estimatedStartupTokens, 8_001)
        XCTAssertEqual(ranking.pressure, .elevated)
        XCTAssertEqual(ranking.automaticInstructionSourceCount, 1)
    }

    func testConditionalInstructionsDoNotInflateStartupContextPressure() throws {
        let fixture = try Fixture()
        try fixture.directory("Projects/repo/.git")
        try fixture.write("automatic", at: "Projects/repo/CLAUDE.md")
        try fixture.write(String(repeating: "c", count: 100_000), at: "Projects/repo/CLAUDE.local.md")

        let report = try AIContextDiscovery.discover(configuration: fixture.configuration())
        let row = try XCTUnwrap(report.folderRankings.first {
            $0.path.hasSuffix("Projects/repo") && $0.provider == .claude
        })
        XCTAssertEqual(row.instructionBytes, 9)
        XCTAssertEqual(row.estimatedStartupTokens, 3)
        XCTAssertEqual(row.pressure, .light)
        XCTAssertEqual(row.automaticInstructionSourceCount, 1)
        XCTAssertTrue(row.sources.contains { $0.item.path.hasSuffix("CLAUDE.local.md") && $0.origin == .conditional })
    }
}

private final class Fixture {
    let root: URL
    init() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func directory(_ path: String) throws { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
    func write(_ text: String, at path: String) throws { let url = root.appendingPathComponent(path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: url) }
    func configuration(
        projectRoots: [URL]? = nil,
        additionalRoots: [URL] = [],
        limits: AIContextDiscovery.Limits = .init()
    ) -> AIContextDiscovery.Configuration {
        AIContextDiscovery.Configuration(
            home: root,
            projectRoots: projectRoots ?? [root.appendingPathComponent("Projects")],
            additionalRoots: additionalRoots,
            limits: limits
        )
    }
}
