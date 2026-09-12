import Foundation
import DiskCore

// Retained baseline for classification profiling; not used by the app.
enum ReferenceDeveloperInsights {
    /// Classifies scanned metadata only. Every file belongs to at most one
    /// category, selected from the deepest matching path component, so a nested
    /// `node_modules` tree is not also counted as an AI session subtree.
    public static func analyze(_ scan: ScanResult) -> [DeveloperGroup] {
        var matchesByID: [Int: [PathMatch]] = [:]
        matchesByID.reserveCapacity(scan.nodes.count)
        for node in scan.nodes where scan.nodes.indices.contains(node.id) {
            matchesByID[node.id] = matches(for: node, in: scan)
        }

        var allocated = Dictionary(uniqueKeysWithValues: DeveloperCategory.allCases.map { ($0, Int64.zero) })
        var logical = Dictionary(uniqueKeysWithValues: DeveloperCategory.allCases.map { ($0, Int64.zero) })
        var files = Dictionary(uniqueKeysWithValues: DeveloperCategory.allCases.map { ($0, 0) })

        // Totals are assembled from files rather than directory aggregates,
        // avoiding repeated subtree sums and hard-link allocation double counts.
        for node in scan.nodes where !node.isDirectory && !node.isSymlink {
            guard let match = matchesByID[node.id]?.best else { continue }
            allocated[match.category] = saturatingAdd(allocated[match.category] ?? 0, node.allocatedBytes)
            logical[match.category] = saturatingAdd(logical[match.category] ?? 0, node.logicalBytes)
            files[match.category, default: 0] += 1
        }

        var roots = Dictionary(uniqueKeysWithValues: DeveloperCategory.allCases.map { ($0, [Int]()) })
        for node in scan.nodes {
            guard let match = matchesByID[node.id]?.best, isCategoryRoot(match, for: node, scan: scan, matchesByID: matchesByID) else {
                continue
            }
            roots[match.category, default: []].append(node.id)
        }

        return DeveloperCategory.allCases.map { category in
            let sortedRoots = (roots[category] ?? []).sorted {
                let left = scan.nodes[$0]
                let right = scan.nodes[$1]
                if left.allocatedBytes != right.allocatedBytes { return left.allocatedBytes > right.allocatedBytes }
                return left.id < right.id
            }
            return DeveloperGroup(
                category: category,
                allocatedBytes: allocated[category] ?? 0,
                logicalBytes: logical[category] ?? 0,
                fileCount: files[category] ?? 0,
                rootIDs: sortedRoots
            )
        }
    }

    private static func isCategoryRoot(
        _ match: PathMatch,
        for node: DiskNode,
        scan: ScanResult,
        matchesByID: [Int: [PathMatch]]
    ) -> Bool {
        guard node.isDirectory || match.isSessionFile else { return false }
        var parent = node.parent
        while let id = parent, scan.nodes.indices.contains(id) {
            if matchesByID[id]?.best?.category == match.category { return false }
            parent = scan.nodes[id].parent
        }
        return true
    }

    private static func matches(for node: DiskNode, in scan: ScanResult) -> [PathMatch] {
        let components = scan.url(for: node.id).standardizedFileURL.path
            .split(separator: "/")
            .map { $0.lowercased() }
        guard !components.isEmpty else { return [] }

        var result: [PathMatch] = []
        for index in components.indices {
            let component = components[index]
            let next = index + 1 < components.endIndex ? components[index + 1] : nil

            if component == "node_modules" {
                result.append(PathMatch(category: .nodeModules, depth: index, isSessionFile: false))
            }
            if [".build", ".next", "dist", "build", "deriveddata", "target"].contains(component) {
                // `build` and `dist` are intentionally heuristic names.
                result.append(PathMatch(category: .buildOutputs, depth: index, isSessionFile: false))
            }
            if ["tmp", "temp", "temporary"].contains(component) {
                result.append(PathMatch(category: .temporary, depth: index, isSessionFile: false))
            }
            if component == ".claude", next == "projects" {
                result.append(PathMatch(category: .claudeSessions, depth: index + 1, isSessionFile: false))
            }
            if component == ".codex", ["sessions", "archived_sessions"].contains(next ?? "") {
                result.append(PathMatch(category: .codexSessions, depth: index + 1, isSessionFile: false))
            }
            if [".claude", ".codex"].contains(component), (next ?? "").hasPrefix("cache") {
                result.append(PathMatch(category: .aiCaches, depth: index, isSessionFile: false))
            }
        }

        let fileName = components.last ?? ""
        if fileName == "sessions.jsonl", !components.contains(".codex") {
            result.append(PathMatch(category: .claudeSessions, depth: components.endIndex - 1, isSessionFile: true))
        }
        if fileName.hasSuffix(".jsonl") {
            if let claude = components.lastIndex(of: ".claude") {
                result.append(PathMatch(category: .claudeSessions, depth: claude + 1, isSessionFile: true))
            }
            if let codex = components.lastIndex(of: ".codex") {
                result.append(PathMatch(category: .codexSessions, depth: codex + 1, isSessionFile: true))
            }
        }
        return result
    }
}

private struct PathMatch {
    let category: DeveloperCategory
    let depth: Int
    let isSessionFile: Bool
}

private extension Array where Element == PathMatch {
    var best: PathMatch? {
        reduce(nil) { best, candidate in
            guard let best else { return candidate }
            if candidate.depth != best.depth { return candidate.depth > best.depth ? candidate : best }
            return candidate.category.rawValue < best.category.rawValue ? candidate : best
        }
    }
}

private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? (rhs >= 0 ? Int64.max : Int64.min) : value
}
