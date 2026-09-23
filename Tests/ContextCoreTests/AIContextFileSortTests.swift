import Foundation
import Testing
@testable import ContextCore

struct AIContextFileSortTests {
    @Test func sortsNaturallyAndUsesPathsAsDeterministicTies() {
        let input = [
            item("/b", name: "item10", kind: .instruction, size: 10, modified: 1),
            item("/c", name: "item1", kind: .rule, size: 20, modified: 2),
            item("/a", name: "item2", kind: .skill, size: 20, modified: 3),
        ]
        #expect(AIContextFileSort.sorted(input, by: .name, ascending: true).map(\.id) == ["/c", "/a", "/b"])
        #expect(AIContextFileSort.sorted(input, by: .size, ascending: false).map(\.id) == ["/a", "/c", "/b"])
        #expect(AIContextFileSort.sorted(input, by: .modified, ascending: false).map(\.id) == ["/a", "/c", "/b"])
    }

    private func item(_ path: String, name: String, kind: AIContextKind, size: Int64, modified: TimeInterval) -> AIContextItem {
        AIContextItem(id: path, path: path, name: name, scope: .project, kind: kind,
                      logicalBytes: size, allocatedBytes: size, modified: Date(timeIntervalSince1970: modified))
    }
}
