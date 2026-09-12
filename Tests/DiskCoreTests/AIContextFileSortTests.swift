import XCTest
@testable import DiskCore

final class AIContextFileSortTests: XCTestCase {
    func testSortKeysDirectionsAndDeterministicTies() {
        let a = item("/a", name: "item2", kind: .skill, size: 20, modified: 3)
        let b = item("/b", name: "item10", kind: .instruction, size: 10, modified: 1)
        let c = item("/c", name: "item1", kind: .rule, size: 20, modified: 2)
        let input = [b, c, a]
        XCTAssertEqual(AIContextFileSort.sorted(input, by: .name, ascending: true).map(\.id), ["/c", "/a", "/b"])
        XCTAssertEqual(AIContextFileSort.sorted(input, by: .size, ascending: false).map(\.id), ["/a", "/c", "/b"])
        XCTAssertEqual(AIContextFileSort.sorted(input, by: .size, ascending: true).map(\.id), ["/b", "/a", "/c"])
        XCTAssertEqual(AIContextFileSort.sorted(input, by: .modified, ascending: false).map(\.id), ["/a", "/c", "/b"])
        XCTAssertEqual(AIContextFileSort.sorted(input, by: .kind, ascending: true).map(\.id), ["/b", "/c", "/a"])
    }
    private func item(_ path: String, name: String, kind: AIContextKind, size: Int64, modified: TimeInterval) -> AIContextItem {
        AIContextItem(id: path, path: path, name: name, scope: .project, kind: kind,
                      logicalBytes: size, allocatedBytes: size, modified: Date(timeIntervalSince1970: modified))
    }
}
