import Foundation

public enum OpportunityConfidence: String, Sendable {
    case high = "High confidence"
    case review = "Review signal"
}

public struct EfficiencyOpportunity: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let scope: String
    public let evidence: String
    public let action: String
    public let limitation: String
    public let confidence: OpportunityConfidence
}

/// Decision support, not a savings calculator. Every rule preserves the
/// source's aggregation level and avoids claims about unused skills or cause.
public enum EfficiencyOpportunityAnalyzer {
    public static func skills(summary: SkillRedundancySummary?, runtime: AgentRuntime?,
                              telemetry: ObservabilitySnapshot?) -> [EfficiencyOpportunity] {
        guard let summary else { return [] }
        let observedInjections: [String: Double] = Dictionary(grouping:
            telemetry?.breakdowns?.first(where: { $0.title == "Skills injected · 24h" })?.items ?? [],
            by: { $0.name.lowercased() }
        ).mapValues { $0.reduce(0) { $0 + $1.value } }
        return summary.actionableFindings.filter { finding in
            runtime.map { finding.affectedRuntimes.contains($0) } ?? true
        }.sorted { left, right in
            let rank: (SkillRedundancyKind) -> Int = { kind in
                switch kind { case .versionDrift: 0; case .exactCopy: 1; case .semanticOverlap: 2 }
            }
            if rank(left.kind) != rank(right.kind) { return rank(left.kind) < rank(right.kind) }
            if left.affectedRuntimes.count != right.affectedRuntimes.count {
                return left.affectedRuntimes.count > right.affectedRuntimes.count
            }
            return left.id < right.id
        }.map { finding in
            let names = Set(finding.members.map { $0.name.lowercased() })
            let injections = names.reduce(0) { $0 + (observedInjections[$1] ?? 0) }
            let sawCodex = finding.affectedRuntimes.contains(.codex) && injections > 0
            let title: String = switch finding.kind {
            case .versionDrift: "Competing versions of \(finding.members.first?.name ?? "a skill")"
            case .exactCopy: "Duplicate skill definitions"
            case .semanticOverlap: "Possible skill responsibility overlap"
            }
            let runtimeNames = finding.affectedRuntimes.map(\.rawValue).joined(separator: ", ")
            let firstEvidence = finding.evidence.first ?? "Local definitions overlap."
            let injectionEvidence = sawCodex
                ? " Codex OTEL also reports \(Int(injections.rounded())) named injections in 24h; it cannot identify the physical copy."
                : ""
            return EfficiencyOpportunity(
                id: "skill:\(finding.id)", title: title,
                scope: "\(runtimeNames) · \(finding.members.count) definitions",
                evidence: firstEvidence + injectionEvidence,
                action: finding.recommendation,
                limitation: finding.kind == .exactCopy
                    ? "Duplicate bytes are disk bytes, not proven prompt tokens or cost savings."
                    : finding.kind == .semanticOverlap
                    ? "Purpose similarity is heuristic; these skills may have distinct operational roles."
                    : "A shared name does not prove which definition a run loaded.",
                confidence: finding.confidence == .high ? .high : .review
            )
        }
    }

    public static func telemetry(snapshot: ObservabilitySnapshot, runtime: AgentRuntime) -> [EfficiencyOpportunity] {
        guard snapshot.collectorReachable,
              snapshot.agents.first(where: { $0.runtime == runtime })?.connected == true,
              runtime == .codex else { return [] }
        let sections = snapshot.breakdowns ?? []
        func value(_ section: String, _ name: String) -> Double? {
            sections.first(where: { $0.title == section })?.items.first(where: { $0.name == name })?.value
        }
        var results: [EfficiencyOpportunity] = []
        if let failures = value("Reliability · 24h", "API failures"), failures > 0 {
            results.append(EfficiencyOpportunity(
                id: "otel:api-failures", title: "API failures observed", scope: "Codex · last 24h",
                evidence: "\(count(failures)) derived failed-request events in local Prometheus.",
                action: "Inspect the affected runs and provider errors before changing retry or model policy.",
                limitation: "Range-derived events may miss short-lived series; this is not a failure rate without a reliable denominator.",
                confidence: .high))
        }
        if let compactions = value("Reliability · 24h", "Compactions"), compactions > 0 {
            results.append(EfficiencyOpportunity(
                id: "otel:compactions", title: "Context compactions observed", scope: "Codex · last 24h",
                evidence: "\(count(compactions)) derived compaction events in local Prometheus.",
                action: "Review instruction pressure and long-running sessions; compare a specific run before changing skills.",
                limitation: "Compactions alone do not identify a responsible skill or prove waste.",
                confidence: .review))
        }
        for (sectionTitle, label, threshold) in [("MCP servers · 24h", "MCP", 20.0),
                                                  ("Tools · 24h", "tool", 50.0)] {
            guard let top = sections.first(where: { $0.title == sectionTitle })?.items.max(by: { $0.value < $1.value }),
                  top.value >= threshold else { continue }
            results.append(EfficiencyOpportunity(
                id: "otel:hotspot:\(sectionTitle):\(top.name)", title: "Repeated \(label) activity: \(top.name)",
                scope: "Codex · last 24h",
                evidence: "\(count(top.value)) range-derived \(label) calls; the busiest reported \(label) in this window.",
                action: "Inspect representative runs for retries, loops, or expected batch work before optimizing.",
                limitation: "High call volume is a review threshold, not proof of inefficiency; tool and MCP counters may overlap.",
                confidence: .review))
        }
        return results
    }

    private static func count(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.01 ? Int(value.rounded()).formatted() : String(format: "%.1f", value)
    }
}
