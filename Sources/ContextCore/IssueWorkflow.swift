import Foundation

public struct SkillIssueBaseline: Sendable {
    public let findings: [SkillRedundancyFinding]

    public init(findings: [SkillRedundancyFinding]) {
        self.findings = findings.filter { !$0.isManagedCacheOnly }
    }

    public func verify(against current: SkillRedundancySummary?, scannedRecordIDs: Set<String>?) -> SkillIssueVerification {
        guard let current, let scannedRecordIDs else {
            return SkillIssueVerification(stillDetected: [], cleared: [], unverified: findings)
        }
        let currentFindings = current.actionableFindings
        var stillDetected: [SkillRedundancyFinding] = []
        var cleared: [SkillRedundancyFinding] = []
        var unverified: [SkillRedundancyFinding] = []
        for finding in findings {
            let originalMembers = Set(finding.members.map(\.id))
            let sameConflictStillPresent = currentFindings.contains { candidate in
                candidate.id == finding.id
                    || candidate.members.reduce(0) { $0 + (originalMembers.contains($1.id) ? 1 : 0) } >= 2
            }
            if sameConflictStillPresent {
                stillDetected.append(finding)
            } else if finding.members.allSatisfy({ scannedRecordIDs.contains($0.id) }) {
                cleared.append(finding)
            } else {
                unverified.append(finding)
            }
        }
        return SkillIssueVerification(stillDetected: stillDetected, cleared: cleared, unverified: unverified)
    }
}

public struct SkillIssueVerification: Sendable {
    public let stillDetected: [SkillRedundancyFinding]
    /// The same definitions were scanned and this finding is absent. This
    /// verifies the detector outcome, not the safety of the edit or run behavior.
    public let cleared: [SkillRedundancyFinding]
    public let unverified: [SkillRedundancyFinding]
}

public struct ConfigurationIssueBaseline: Sendable {
    public let issues: [ConfigurationHealthIssue]

    public init(issues: [ConfigurationHealthIssue]) { self.issues = issues }

    public func verify(against report: ConfigurationHealthReport) -> ConfigurationIssueVerification {
        let activeIDs = Set(report.issues.map(\.id))
        let scannedFiles = Set(report.scannedFiles)
        return ConfigurationIssueVerification(
            stillDetected: issues.filter { activeIDs.contains($0.id) },
            cleared: issues.filter { !activeIDs.contains($0.id) && scannedFiles.contains($0.path) },
            unverified: issues.filter { !activeIDs.contains($0.id) && !scannedFiles.contains($0.path) })
    }
}

public struct ConfigurationIssueVerification: Sendable {
    public let stillDetected: [ConfigurationHealthIssue]
    public let cleared: [ConfigurationHealthIssue]
    public let unverified: [ConfigurationHealthIssue]
}

public enum IssueBriefFormatter {
    public static func configuration(_ issues: [ConfigurationHealthIssue]) -> String {
        var lines = [
            "# ContextDaddy configuration review — \(issues.count) issues",
            "",
            "Review current agent documentation and the exact file before any edit. This brief contains structural findings only, never config values, credentials, headers, environment variables, or MCP arguments. Do not touch secrets or production configuration. If the target is outside your writable scope, report it blocked. Preserve existing values and unrelated settings. Verify the CLI startup after each confirmed change; ContextDaddy will independently rescan.",
            "",
        ]
        for (index, issue) in issues.enumerated() {
            lines += [
                "## \(index + 1). \(issue.title)",
                "Issue ID: \(issue.id)",
                "Severity: \(issue.severity.rawValue); agent: \(issue.runtime.rawValue)",
                "Location: \(issue.path):\(issue.line)",
                "Evidence: \(issue.detail)",
                "Suggested review: \(issue.remediation)",
                "",
            ]
        }
        return lines.joined(separator: "\n")
    }

    public static func skills(_ findings: [SkillRedundancyFinding]) -> String {
        let actionable = findings.filter { !$0.isManagedCacheOnly }
        var lines = [
            "# ContextDaddy skill review — \(actionable.count) findings",
            "",
            "Review each finding against the current files before editing. Exact-copy evidence covers SKILL.md only; inspect supporting files before consolidating directories. Fix confirmed conflicts in writable source locations only. Do not delete files, change managed caches, touch secrets or production configuration, or assume duplicate bytes equal token savings. Preserve distinct skills when their responsibilities differ. Run the smallest relevant checks. Report each issue ID as changed, intentionally kept, blocked, or unverified with file evidence. ContextDaddy will independently rescan; do not claim success solely from this brief.",
            "",
        ]
        for (index, finding) in actionable.enumerated() {
            lines += [
                "## \(index + 1). \(finding.kind.rawValue) — \(finding.members.map(\.name).joined(separator: " ↔ "))",
                "Issue ID: \(finding.id)",
                "Confidence: \(finding.confidence.rawValue); agents: \(finding.affectedRuntimes.map(\.rawValue).joined(separator: ", "))",
                "Evidence: \(finding.evidence.joined(separator: " | "))",
                "Suggested review: \(finding.recommendation)",
                "Definitions:",
            ]
            for member in finding.members {
                lines.append("- \(member.id) [\(member.source)]\(member.isManagedCache ? " (managed cache; do not edit)" : "")")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func telemetry(_ opportunities: [EfficiencyOpportunity]) -> String {
        var lines = [
            "# ContextDaddy OTEL review — \(opportunities.count) signals",
            "",
            "Investigate representative runs and source counters before changing retry, tool, MCP, model, or skill policy. These are review signals, not proven waste. Do not infer a fix from a lower rolling 24-hour count alone. Report changes and a new observation window with comparable activity before claiming improvement.",
            "",
        ]
        for (index, item) in opportunities.enumerated() {
            lines += [
                "## \(index + 1). \(item.title)",
                "Issue ID: \(item.id)",
                "Scope: \(item.scope)",
                "Evidence: \(item.evidence)",
                "Suggested review: \(item.action)",
                "Limit: \(item.limitation)",
                "",
            ]
        }
        return lines.joined(separator: "\n")
    }
}
