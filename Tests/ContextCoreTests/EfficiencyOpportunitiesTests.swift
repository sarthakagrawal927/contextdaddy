import Foundation
import Testing
@testable import ContextCore

struct EfficiencyOpportunitiesTests {
    @Test func codexSignalsAreEvidenceBoundedAndClaudeDoesNotBorrowThem() {
        let sections = [
            TelemetryBreakdownSection(title: "Reliability · 24h", note: "", items: [
                TelemetryBreakdownItem(name: "API failures", value: 3, unit: "events"),
                TelemetryBreakdownItem(name: "Compactions", value: 2, unit: "events"),
            ]),
            TelemetryBreakdownSection(title: "MCP servers · 24h", note: "", items: [
                TelemetryBreakdownItem(name: "search", value: 25, unit: "calls"),
            ]),
        ]
        let snapshot = ObservabilitySnapshot(generatedAt: Date(), collectorReachable: true,
            agents: [AgentTelemetry(runtime: .codex, connected: true, source: "fixture", signals: [:]),
                     AgentTelemetry(runtime: .claude, connected: true, source: "fixture", signals: [:])],
            notes: [], breakdowns: sections)
        let codex = EfficiencyOpportunityAnalyzer.telemetry(snapshot: snapshot, runtime: .codex)
        #expect(codex.map(\.id).contains("otel:api-failures"))
        #expect(codex.map(\.id).contains("otel:compactions"))
        #expect(codex.count == 3)
        #expect(codex.allSatisfy { !$0.limitation.isEmpty && !$0.action.isEmpty })
        #expect(EfficiencyOpportunityAnalyzer.telemetry(snapshot: snapshot, runtime: .claude).isEmpty)
        #expect(EfficiencyOpportunityAnalyzer.telemetry(snapshot: .unavailable, runtime: .codex).isEmpty)
    }

    @Test func skillOpportunityNeverClaimsContextSavingsOrUnused() {
        let member = SkillRedundancyMember(id: "a", name: "review", description: "Review code", logicalBytes: 2_048,
                                           modified: Date(), source: "fixture", exposedRuntimes: [.codex], isManagedCache: false)
        let finding = SkillRedundancyFinding(id: "duplicate", kind: .exactCopy, confidence: .high, score: 1,
            members: [member, member], keepCandidateID: "a", affectedRuntimes: [.codex],
            evidence: ["Identical bounded content"], recommendation: "Review aliases", estimatedDuplicateBytes: 2_048,
            includesManagedCache: false)
        let summary = SkillRedundancySummary(findings: [finding])
        let opportunities = EfficiencyOpportunityAnalyzer.skills(summary: summary, runtime: .codex, telemetry: nil)
        #expect(opportunities.count == 1)
        #expect(opportunities[0].limitation.contains("not proven prompt tokens"))
        #expect(!opportunities[0].title.localizedCaseInsensitiveContains("unused"))
        #expect(EfficiencyOpportunityAnalyzer.skills(summary: summary, runtime: .claude, telemetry: nil).isEmpty)
    }

    @Test func issueBriefContainsEveryFindingAndVerificationRequiresSourceCoverage() {
        let first = SkillRedundancyMember(id: "/a/SKILL.md", name: "review", description: "Review code",
                                          logicalBytes: 2_048, modified: Date(), source: "fixture",
                                          exposedRuntimes: [.codex], isManagedCache: false)
        let second = SkillRedundancyMember(id: "/b/SKILL.md", name: "review", description: "Review code",
                                           logicalBytes: 2_048, modified: Date(), source: "fixture",
                                           exposedRuntimes: [.codex], isManagedCache: false)
        let finding = SkillRedundancyFinding(id: "Exact copy:/a|/b", kind: .exactCopy, confidence: .high,
                                             score: 1, members: [first, second], keepCandidateID: first.id,
                                             affectedRuntimes: [.codex], evidence: ["Same bounded SHA-256"],
                                             recommendation: "Review aliases", estimatedDuplicateBytes: 2_048,
                                             includesManagedCache: false)
        let brief = IssueBriefFormatter.skills([finding])
        #expect(brief.contains("/a/SKILL.md"))
        #expect(brief.contains("/b/SKILL.md"))
        #expect(brief.contains("Same bounded SHA-256"))
        #expect(brief.contains("Do not delete files"))

        let baseline = SkillIssueBaseline(findings: [finding])
        let stillDetected = baseline.verify(against: SkillRedundancySummary(findings: [finding]),
                                            scannedRecordIDs: [first.id, second.id])
        #expect(stillDetected.stillDetected.count == 1)
        let cleared = baseline.verify(against: SkillRedundancySummary(findings: []),
                                      scannedRecordIDs: [first.id, second.id])
        #expect(cleared.cleared.count == 1)
        let missingSource = baseline.verify(against: SkillRedundancySummary(findings: []),
                                            scannedRecordIDs: [first.id])
        #expect(missingSource.unverified.count == 1)
        #expect(baseline.verify(against: nil, scannedRecordIDs: nil).unverified.count == 1)
        let changedKind = SkillRedundancyFinding(id: "Version drift:/a|/b", kind: .versionDrift,
                                                 confidence: .high, score: 0.95, members: [first, second],
                                                 keepCandidateID: first.id, affectedRuntimes: [.codex],
                                                 evidence: ["Bodies diverged"], recommendation: "Review drift",
                                                 estimatedDuplicateBytes: 0, includesManagedCache: false)
        let relatedConflict = baseline.verify(against: SkillRedundancySummary(findings: [changedKind]),
                                              scannedRecordIDs: [first.id, second.id])
        #expect(relatedConflict.stillDetected.count == 1)
    }

    @Test func telemetryBriefPreservesWindowCaveat() {
        let issue = EfficiencyOpportunity(id: "otel:api-failures", title: "API failures observed",
                                          scope: "Codex · last 24h", evidence: "3 derived events",
                                          action: "Inspect runs", limitation: "No reliable denominator",
                                          confidence: .high)
        let brief = IssueBriefFormatter.telemetry([issue])
        #expect(brief.contains("otel:api-failures"))
        #expect(brief.contains("new observation window"))
        #expect(brief.contains("No reliable denominator"))
    }

    @Test func configurationIssueHandoffRequiresSameConfigFileForClearance() {
        let issue = ConfigurationHealthIssue(id: "ignored", severity: .warning, runtime: .codex,
                                             title: "Ignored setting", detail: "Wrong table", path: "/config.toml",
                                             line: 12, remediation: "Move the key")
        let brief = IssueBriefFormatter.configuration([issue])
        #expect(brief.contains("/config.toml:12"))
        #expect(brief.contains("never config values"))
        let baseline = ConfigurationIssueBaseline(issues: [issue])
        #expect(baseline.verify(against: ConfigurationHealthReport(issues: [issue], scannedFiles: [issue.path]))
            .stillDetected.count == 1)
        #expect(baseline.verify(against: ConfigurationHealthReport(issues: [], scannedFiles: [issue.path]))
            .cleared.count == 1)
        #expect(baseline.verify(against: .empty).unverified.count == 1)
    }
}
