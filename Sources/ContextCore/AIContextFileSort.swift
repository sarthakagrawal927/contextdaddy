import Foundation

public enum AIContextFileSort: String, CaseIterable, Sendable {
    case name = "Name"
    case kind = "Kind"
    case size = "Size"
    case modified = "Last modified"

    public static func sorted(_ items: [AIContextItem], by key: Self, ascending: Bool) -> [AIContextItem] {
        items.sorted { a, b in
            let comparison: ComparisonResult
            switch key {
            case .name: comparison = a.name.localizedStandardCompare(b.name)
            case .kind: comparison = a.kind.rawValue.localizedStandardCompare(b.kind.rawValue)
            case .size: comparison = a.logicalBytes == b.logicalBytes ? .orderedSame : a.logicalBytes < b.logicalBytes ? .orderedAscending : .orderedDescending
            case .modified: comparison = a.modified == b.modified ? .orderedSame : a.modified < b.modified ? .orderedAscending : .orderedDescending
            }
            if comparison == .orderedSame { return a.path < b.path }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
}
