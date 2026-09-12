import XCTest
@testable import DiskCore

final class AIContextProjectsTests: XCTestCase {
    func testCollapsesProviderRowsGroupsStorageRootsAndOmitsSharedLocations() throws {
        let app = "/work/app"
        let local = item(app + "/AGENTS.md", provider: .codex, kind: .instruction)
        let rule = item(app + "/.claude/rules/swift/style.md", provider: .claude, kind: .rule)
        let inherited = item("/work/AGENTS.md", provider: .codex, kind: .instruction)
        let global = item("/home/.codex/skills/global/SKILL.md", scope: .global, provider: .codex, kind: .skill)
        let plugin = item("/home/.codex/plugins/cache/vendor/tool/SKILL.md", scope: .global, provider: .codex, kind: .skill, applicability: .installedOnly)
        let report = report([
            ranking(app, provider: .codex, sources: [contribution(local, .local), contribution(inherited, .inherited), contribution(global, .conditional), contribution(plugin, .installedOnly)]),
            ranking(app, provider: .claude, sources: [contribution(rule, .conditional), contribution(global, .conditional)]),
        ])

        let project = try XCTUnwrap(AIContextProjectCatalog.projects(from: report).only)

        XCTAssertEqual(project.path, app)
        XCTAssertEqual(project.providers, [.claude, .codex])
        XCTAssertEqual(project.projectItemCount, 2)
        XCTAssertEqual(project.projectLogicalBytes, 20)
        XCTAssertFalse(project.locations.contains { $0.scope == .global || $0.scope == .installed })
        XCTAssertEqual(project.locations.first { $0.path == app + "/.claude/rules" }?.items, [rule])
        XCTAssertEqual(project.locations.first { $0.path == "/work" }?.scope, .inherited)
    }

    func testGlobalOrInheritedOnlyRankingDoesNotCreateProject() {
        let global = item("/home/.agents/skills/shared/SKILL.md", scope: .global, provider: .agents, kind: .skill)
        let inherited = item("/work/AGENTS.md", provider: .codex, kind: .instruction)
        let report = report([
            ranking("/work/empty", provider: .codex, sources: [contribution(global, .conditional), contribution(inherited, .inherited)]),
        ])

        XCTAssertTrue(AIContextProjectCatalog.projects(from: report).isEmpty)
    }

    func testSiblingPathsStayIsolatedAndLinkedAliasesRemainDistinct() throws {
        let target = "/shared/skill/SKILL.md"
        let appAlias = item("/work/app/.agents/skills/shared/SKILL.md", resolvedPath: target, provider: .agents, kind: .skill)
        let secondAlias = item("/work/app/.codex/skills/shared/SKILL.md", resolvedPath: target, provider: .codex, kind: .skill)
        let sibling = item("/work/application/AGENTS.md", provider: .codex, kind: .instruction)
        let report = report([
            ranking("/work/app", provider: .codex, sources: [contribution(appAlias, .conditional), contribution(secondAlias, .conditional)]),
            ranking("/work/application", provider: .codex, sources: [contribution(sibling, .local)]),
        ])

        let projects = AIContextProjectCatalog.projects(from: report)
        let app = try XCTUnwrap(projects.first { $0.path == "/work/app" })

        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(app.locations.flatMap(\.items).map(\.path).sorted(), [appAlias.path, secondAlias.path].sorted())
        XCTAssertFalse(app.locations.flatMap(\.items).contains { $0.path.contains("/application/") })
    }

    func testOwnedNestedRulesAndAgentDefinitionsContributeToProjectRanking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        try write("rule", to: root.appendingPathComponent("repo/.claude/rules/nested/style.md"))
        try write("agent", to: root.appendingPathComponent("repo/.codex/agents/reviewer.toml"))

        let report = try AIContextDiscovery.discover(configuration: .init(home: root, projectRoots: [root]))
        let row = try XCTUnwrap(report.folderRankings.first { $0.path.hasSuffix("/repo") && $0.provider == .codex })
        let claude = try XCTUnwrap(report.folderRankings.first { $0.path.hasSuffix("/repo") && $0.provider == .claude })

        XCTAssertTrue(row.sources.contains { $0.item.kind == .agentDefinition && $0.origin == .conditional })
        XCTAssertTrue(claude.sources.contains { $0.item.kind == .rule && $0.origin == .conditional })
    }

    func testProjectProvidersExcludeAgentsPresentOnlyGloballyAndRootRuleIsOwned() throws {
        let rule = item("/work/app/.cursorrules", provider: .cursor, kind: .rule)
        let global = item("/home/.claude/CLAUDE.md", scope: .global, provider: .claude, kind: .instruction)
        let project = try XCTUnwrap(AIContextProjectCatalog.projects(from: report([
            ranking("/work/app", provider: .cursor, sources: [contribution(rule, .conditional)]),
            ranking("/work/app", provider: .claude, sources: [contribution(global, .global)]),
        ])).only)
        XCTAssertEqual(project.providers, [.cursor])
        XCTAssertEqual(project.projectItemCount, 1)
        XCTAssertEqual(project.locations.first?.path, "/work/app")
    }

    func testRealDiscoveryRetainsBothLocalStorageAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-project-aliases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let shared = root.appendingPathComponent("library/demo")
        try write("shared skill", to: shared.appendingPathComponent("SKILL.md"))
        for folder in [".agents", ".codex"] {
            let skills = repo.appendingPathComponent(folder + "/skills")
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: skills.appendingPathComponent("demo"), withDestinationURL: shared)
        }
        let discovered = try AIContextDiscovery.discover(configuration: .init(home: root, projectRoots: [repo]))
        let project = try XCTUnwrap(AIContextProjectCatalog.projects(from: discovered).first { $0.path == repo.path })
        XCTAssertEqual(project.projectItemCount, 2)
        XCTAssertEqual(Set(project.locations.map(\.path)), Set([repo.path + "/.agents/skills", repo.path + "/.codex/skills"]))
    }

    func testAgentLoadsUseExactDirectoryAndExcludeLibraryOnlyOrGenericProviders() {
        let local = item("/work/app/AGENTS.md", provider: .codex, kind: .instruction)
        let global = item("/home/.claude/CLAUDE.md", scope: .global, provider: .claude, kind: .instruction)
        let plugin = item("/home/.codex/plugins/cache/tool/SKILL.md", scope: .global, provider: .codex, kind: .skill, applicability: .installedOnly)
        let rows = [
            ranking("/work/app", provider: .codex, sources: [contribution(local, .local)], bytes: 400),
            ranking("/work/app", provider: .claude, sources: [contribution(global, .global)], bytes: 800),
            ranking("/work/application", provider: .codex, sources: [contribution(local, .inherited)], bytes: 900),
            ranking("/work/app", provider: .cursor, sources: [contribution(plugin, .installedOnly)]),
            ranking("/work/app", provider: .agents, sources: [contribution(local, .local)]),
        ]
        let loads = AIContextProjectCatalog.agentLoads(in: "/work/app", rankings: rows)
        XCTAssertEqual(loads.map(\.provider), [.claude, .codex])
        XCTAssertEqual(loads.map(\.estimatedStartupTokens), [200, 100])
        XCTAssertTrue(loads.allSatisfy { $0.path == "/work/app" })
        XCTAssertTrue(AIContextProjectCatalog.agentLoads(in: "/work/missing", rankings: rows).isEmpty)
    }

    private func item(
        _ path: String,
        resolvedPath: String? = nil,
        scope: AIContextScope = .project,
        provider: AIContextProvider,
        kind: AIContextKind,
        applicability: AIContextOrigin = .conditional
    ) -> AIContextItem {
        AIContextItem(id: path, path: path, resolvedPath: resolvedPath, name: URL(fileURLWithPath: path).lastPathComponent,
                      scope: scope, kind: kind, provider: provider, logicalBytes: 10, allocatedBytes: 4096,
                      modified: .distantPast, applicability: applicability)
    }

    private func contribution(_ item: AIContextItem, _ origin: AIContextOrigin) -> AIContextContribution {
        AIContextContribution(item: item, origin: origin)
    }

    private func ranking(_ path: String, provider: AIContextProvider, sources: [AIContextContribution], bytes: Int64 = 0) -> AIContextFolderRanking {
        AIContextFolderRanking(id: provider.rawValue + ":" + path, path: path, provider: provider,
                               instructionBytes: bytes, globalBytes: 0, inheritedBytes: 0, localBytes: bytes,
                               skillCount: 0, skillBytes: 0, conditionalCount: 0, installedOnlyCount: 0,
                               sources: sources, notes: [])
    }

    private func report(_ rankings: [AIContextFolderRanking]) -> AIContextDiscoveryReport {
        AIContextDiscoveryReport(items: [], folderRankings: rankings,
                                 coverage: AIContextCoverage(roots: [], visitedEntries: 0, itemLimitReached: false,
                                                            entryLimitReached: false, unreadableCount: 0, skippedLinks: 0, notes: []),
                                 elapsed: 0)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
