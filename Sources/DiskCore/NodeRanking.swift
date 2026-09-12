import Foundation

/// Keeps only k nodes: O(n log k) work and O(k) extra memory.
public struct NodeRanking: Sendable {
    private var heap: [DiskNode] = []
    private let limit: Int
    private let allocated: Bool
    public init(limit: Int, allocated: Bool) { self.limit = max(0, limit); self.allocated = allocated }
    private func size(_ n: DiskNode) -> Int64 { allocated ? n.allocatedBytes : n.logicalBytes }
    public mutating func insert(_ n: DiskNode) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(n); var i = heap.count - 1
            while i > 0 { let p = (i - 1) / 2; guard size(heap[i]) < size(heap[p]) else { break }; heap.swapAt(i, p); i = p }
        } else if size(n) > size(heap[0]) {
            heap[0] = n; var i = 0
            while i * 2 + 1 < heap.count {
                var child = i * 2 + 1
                if child + 1 < heap.count, size(heap[child + 1]) < size(heap[child]) { child += 1 }
                guard size(heap[child]) < size(heap[i]) else { break }; heap.swapAt(child, i); i = child
            }
        }
    }
    public var sorted: [DiskNode] { heap.sorted { size($0) > size($1) } }
}
