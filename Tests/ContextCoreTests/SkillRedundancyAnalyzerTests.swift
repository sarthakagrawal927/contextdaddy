import Foundation
import Testing
@testable import ContextCore

struct SkillRedundancyAnalyzerTests {
    @Test func identicalContentBecomesOneHighConfidenceExactCopyFinding() throws {
        let records = [
            record("one", path: "/global/one", bytes: 120, fingerprint: "same", runtime: .codex),
            record("two", path: "/project/two", bytes: 120, fingerprint: "same", runtime: .claude),
        ]

        let summary = SkillRedundancyAnalyzer.analyze(records: records)
        let finding = try #require(summary.findings.first)
        #expect(finding.kind == .exactCopy)
        #expect(finding.confidence == .high)
        #expect(finding.estimatedDuplicateBytes == 120)
        #expect(Set(finding.affectedRuntimes) == [.codex, .claude])
    }

    @Test func sameNameWithDifferentContentAndSharedRuntimeIsVersionDrift() throws {
        let records = [
            record("shared", path: "/global/shared", fingerprint: "old", runtime: .codex),
            record("Shared", path: "/project/shared", fingerprint: "new", runtime: .codex),
        ]

        let finding = try #require(SkillRedundancyAnalyzer.analyze(records: records).findings.first)
        #expect(finding.kind == .versionDrift)
        #expect(finding.affectedRuntimes == [.codex])
    }

    @Test func strongPurposeSimilarityFindsDifferentlyNamedSkills() throws {
        let purpose = "Audit application security privacy promises permissions vulnerabilities authentication and exposed credentials"
        let records = [
            record("security-audit", path: "/one", description: purpose + " across product surfaces", fingerprint: "one", runtime: .codex),
            record("privacy-review", path: "/two", description: purpose + " before release", fingerprint: "two", runtime: .codex),
        ]

        let finding = try #require(SkillRedundancyAnalyzer.analyze(records: records).findings.first)
        #expect(finding.kind == .semanticOverlap)
        #expect(finding.confidence == .medium)
        #expect(finding.score >= 0.56)
    }

    @Test func commonInvocationBoilerplateDoesNotCreateOverlap() {
        let records = [
            record("alpha", path: "/one", description: "Use when the user asks to build a weather chart", fingerprint: "one", runtime: .codex),
            record("beta", path: "/two", description: "Use when the user asks to build a database migration", fingerprint: "two", runtime: .codex),
        ]

        #expect(SkillRedundancyAnalyzer.analyze(records: records).findings.isEmpty)
    }

    @Test func disjointRuntimesDoNotTurnDriftOrSimilarityIntoAConflict() {
        let description = "Inspect security privacy authentication vulnerabilities permissions credentials before release"
        let records = [
            record("shared", path: "/one", description: description, fingerprint: "one", runtime: .codex),
            record("shared", path: "/two", description: description, fingerprint: "two", runtime: .claude),
            record("different", path: "/three", description: description, fingerprint: "three", runtime: .grok),
        ]

        #expect(SkillRedundancyAnalyzer.analyze(records: records).findings.isEmpty)
    }

    @Test func unavailableFingerprintDoesNotPretendToProveVersionDrift() {
        let records = [
            record("shared", path: "/one", fingerprint: "known", runtime: .codex),
            record("shared", path: "/two", fingerprint: nil, runtime: .codex),
        ]

        #expect(SkillRedundancyAnalyzer.analyze(records: records).findings.isEmpty)
    }

    @Test func activeDefinitionWinsOverManagedCacheAsKeepCandidate() throws {
        let active = record("active", path: "/active", fingerprint: "same", runtime: .codex)
        let cached = record("cached", path: "/cache", fingerprint: "same", runtime: nil, installedOnly: true)

        let finding = try #require(SkillRedundancyAnalyzer.analyze(records: [cached, active]).findings.first)
        #expect(finding.keepCandidateID == active.id)
        #expect(finding.includesManagedCache)
        #expect(finding.members.first?.isManagedCache == false)
    }

    @Test func summarySeparatesManagedCacheNoiseFromReviewQueue() {
        let active = [
            record("one", path: "/active/one", fingerprint: "active", runtime: .codex),
            record("two", path: "/active/two", fingerprint: "active", runtime: .claude),
        ]
        let caches = [
            record("cached-one", path: "/cache/one", fingerprint: "cache", runtime: nil, installedOnly: true),
            record("cached-two", path: "/cache/two", fingerprint: "cache", runtime: nil, installedOnly: true),
        ]

        let summary = SkillRedundancyAnalyzer.analyze(records: active + caches)
        #expect(summary.findings.count == 2)
        #expect(summary.reviewCount == 1)
        #expect(summary.managedCacheOnlyCount == 1)
        #expect(summary.exactCopyCount == 1)
        #expect(summary.estimatedDuplicateBytes == 100)
        #expect(summary.managedCacheDuplicateBytes == 100)
    }

    @Test func canonicalChoiceIsDeterministicWhenEvidenceTies() throws {
        let later = Date(timeIntervalSince1970: 20)
        let older = Date(timeIntervalSince1970: 10)
        let records = [
            record("older", path: "/z", modified: older, fingerprint: "same", runtime: .codex),
            record("newer", path: "/a", modified: later, fingerprint: "same", runtime: .codex),
        ]

        let forward = try #require(SkillRedundancyAnalyzer.analyze(records: records).findings.first)
        let reversed = try #require(SkillRedundancyAnalyzer.analyze(records: records.reversed()).findings.first)
        #expect(forward.keepCandidateID == "/a")
        #expect(reversed.keepCandidateID == forward.keepCandidateID)
    }

    private func record(
        _ name: String,
        path: String,
        description: String = "Fixture description with enough distinct evidence terms for testing",
        bytes: Int64 = 100,
        modified: Date = .distantPast,
        fingerprint: String?,
        runtime: AgentRuntime?,
        installedOnly: Bool = false
    ) -> SkillRecord {
        let policies = AgentRuntime.allCases.map { candidate in
            SkillRuntimePolicy(
                runtime: candidate,
                mode: candidate == runtime ? .automatic : .unsupported,
                explicit: true,
                reason: "Fixture",
                invocation: "$fixture",
                isExposed: candidate == runtime
            )
        }
        let provider: AIContextProvider = switch runtime {
        case .codex: .codex
        case .claude: .claude
        case .cursor: .cursor
        case .devin: .devin
        case .grok: .grok
        case nil: .codex
        }
        let exposure = SkillExposure(
            logicalPath: path,
            resolvedPath: path,
            source: installedOnly ? "Plugin cache" : "Fixture",
            scope: .global,
            provider: provider,
            applicability: installedOnly ? .installedOnly : .global
        )
        return SkillRecord(
            id: path,
            name: name,
            description: description,
            logicalBytes: bytes,
            modified: modified,
            exposures: [exposure],
            policies: policies,
            contentFingerprint: fingerprint
        )
    }
}
