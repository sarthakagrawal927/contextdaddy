import XCTest
@testable import DiskCore

final class CleanupGuidanceTests: XCTestCase {
    func testBatchSuggestionsExcludeInstalledToolsAndAmbiguousStores() {
        XCTAssertTrue(CleanupGuidance.isSuggestedCache(category: .packageCaches, path: "/Users/test/Library/Caches/uv", home: "/Users/test"))
        XCTAssertTrue(CleanupGuidance.isSuggestedCache(category: .packageCaches, path: "/Users/test/.cache/pip", home: "/Users/test"))
        for path in ["/Users/test/copy/Library/Caches/pip", "/Users/other/Library/Caches/pip", "/Users/test/.local/share/uv", "/Users/test/.m2/repository", "/Users/test/.cargo/registry", "/Users/test/project/build", "/Users/test/Library/Caches/unknown"] {
            XCTAssertFalse(CleanupGuidance.isSuggestedCache(category: .packageCaches, path: path, home: "/Users/test"), path)
        }
        XCTAssertFalse(CleanupGuidance.isSuggestedCache(category: .pythonEnvironments, path: "/Users/test/.cache/uv", home: "/Users/test"))
        XCTAssertFalse(CleanupGuidance.isSuggestedCache(category: .claudeSessions, path: "/Users/test/.cache/uv", home: "/Users/test"))
    }

    func testGuidanceDoesNotPromiseBuildsOrSessionsAreDisposable() {
        XCTAssertEqual(CleanupGuidance.label(for: .buildOutputs), "Possible rebuild")
        XCTAssertEqual(CleanupGuidance.label(for: .claudeSessions), "Archive first")
        XCTAssertEqual(CleanupGuidance.label(for: .containerStorage), "Review first")
        XCTAssertEqual(CleanupGuidance.label(for: nil), "Review first")
    }
}
