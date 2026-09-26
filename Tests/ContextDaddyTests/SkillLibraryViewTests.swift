import AppKit
@testable import ContextCore
import SwiftUI
import Testing
@testable import ContextDaddy

@MainActor
struct SkillLibraryViewTests {
    @Test func rendersLibraryAtSupportedWidthsWithoutLiveData() throws {
        let model = ContextDaddyModel()
        let records = [
            record("design-workflow", "Design and review Fleet product interfaces.", path: "/Users/demo/skills/design-workflow/SKILL.md", providers: [.codex, .claude]),
            record("xcodebuildmcp", "Build, test, and inspect native Apple applications.", path: "/Users/demo/.codex/plugins/cache/apple/skills/xcodebuildmcp/SKILL.md", providers: []),
            record("skill-creator", "Create focused skills with clear invocation guidance.", path: "/Users/demo/.agents/skills/skill-creator/SKILL.md", providers: [.codex]),
            record("cloudflare", "Choose services and build Cloudflare applications.", path: "/Users/demo/skills/cloudflare/SKILL.md", providers: [.claude]),
        ]
        let coverage = AIContextCoverage(roots: ["/Users/demo/.agents/skills"], visitedEntries: 12, itemLimitReached: false, entryLimitReached: false, unreadableCount: 0, skippedLinks: 0, notes: [])
        model.catalog = SkillCatalogSnapshot(records: records, coverage: coverage, generatedAt: Date())
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/design/skill-management")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [390, 768, 960, 1440] {
            let height = 900
            let view = SkillLibraryView().environment(model).preferredColorScheme(.dark).background(DaddyTheme.canvas)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = hosting
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let scrolls = scrollViews(hosting)
            #expect(scrolls.count == 1)
            #expect(scrolls.first?.hasVerticalScroller == true)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("library-\(width).png"))
        }
    }

    private func record(_ name: String, _ description: String, path: String, providers: [AgentRuntime]) -> SkillRecord {
        SkillRecord(id: path, name: name, description: description, logicalBytes: 800, modified: Date(),
            exposures: providers.map { runtime in
                SkillExposure(logicalPath: "/Users/demo/.\(runtime.rawValue.lowercased())/skills/\(name)/SKILL.md", resolvedPath: path, source: "\(runtime.rawValue) · Personal skills", scope: .global, provider: AIContextProvider(rawValue: runtime.rawValue)!, applicability: .conditional)
            },
            policies: AgentRuntime.allCases.map { runtime in
                SkillRuntimePolicy(runtime: runtime, mode: providers.contains(runtime) ? .automatic : .unsupported, explicit: false,
                    reason: providers.contains(runtime) ? "Derived from the discovered skill route." : "No active route found.", invocation: "$\(name)", isExposed: providers.contains(runtime))
            })
    }
    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
