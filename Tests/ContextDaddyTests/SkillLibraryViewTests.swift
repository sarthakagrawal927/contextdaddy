import AppKit
@testable import ContextCore
import SwiftUI
import Testing
@testable import ContextDaddy

@MainActor
@Suite(.serialized)
struct SkillLibraryViewTests {
    @Test func rendersLibraryAtSupportedWidthsWithoutLiveData() throws {
        // AppKit caches this preference per process. Run the suite separately for each style.
        let scrollbarPreference = ProcessInfo.processInfo.environment["CONTEXTDADDY_TEST_SCROLLBARS"] ?? "Always"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "AppleShowScrollBars")
        defaults.set(scrollbarPreference, forKey: "AppleShowScrollBars")
        defer {
            if let previous { defaults.set(previous, forKey: "AppleShowScrollBars") }
            else { defaults.removeObject(forKey: "AppleShowScrollBars") }
        }
        #expect(NSScroller.preferredScrollerStyle == (scrollbarPreference == "Always" ? .legacy : .overlay))
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
            let scroll = try #require(scrolls.first)
            #expect(scroll.frame.height <= hosting.bounds.height + 1)
            #expect(scroll.frame.width <= hosting.bounds.width + 1)
            let document = try #require(scroll.documentView)
            if document.bounds.height > scroll.contentView.bounds.height {
                let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
                #expect(abs(scroll.contentView.bounds.maxY - document.bounds.maxY) < 2)
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("library-\(width).png"))
        }
    }

    @Test func rootKeepsSkillsInsideTheActualWindow() throws {
        let model = ContextDaddyModel(discover: { _ in throw CancellationError() })
        model.show(.skills)
        for width in [960, 1180, 1440] {
            let host = NSHostingView(rootView: RootView().environment(model))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let scroll = try #require(scrollViews(host).first)
            let viewport = scroll.convert(scroll.bounds, to: host)
            #expect(viewport.minX >= -1)
            #expect(viewport.minY >= -1)
            #expect(viewport.maxX <= host.bounds.maxX + 1)
            #expect(viewport.maxY <= host.bounds.maxY + 1)
            #expect(viewport.height > 400)
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
