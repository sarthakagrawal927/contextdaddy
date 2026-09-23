import Foundation
import Testing
@testable import ContextCore

struct TelemetrySnapshotStoreTests {
    @Test func prunesExpiredSnapshotsAndReplacesRapidRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let store = TelemetrySnapshotStore(directory: root, now: { fixedNow })
        let expired = ObservabilitySnapshot(generatedAt: fixedNow.addingTimeInterval(-TelemetrySnapshotStore.retention - 1), collectorReachable: true, agents: [], notes: [])
        let recent = ObservabilitySnapshot(generatedAt: fixedNow.addingTimeInterval(-60), collectorReachable: true, agents: [], notes: ["first"])
        let replacement = ObservabilitySnapshot(generatedAt: fixedNow, collectorReachable: true, agents: [], notes: ["replacement"])
        _ = try await store.append(expired)
        _ = try await store.append(recent)
        let stored = try await store.append(replacement)
        #expect(stored.count == 1)
        #expect(stored.first?.notes == ["replacement"])
    }

    @Test func decodesSnapshotsWrittenBeforeOTelDetailFields() throws {
        struct LegacySnapshot: Codable {
            let generatedAt: Date
            let collectorReachable: Bool
            let agents: [AgentTelemetry]
            let notes: [String]
        }
        let legacy = LegacySnapshot(generatedAt: .distantPast, collectorReachable: true, agents: [], notes: ["legacy"])
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(ObservabilitySnapshot.self, from: data)
        #expect(decoded.notes == ["legacy"])
        #expect(decoded.recentRuns == nil)
        #expect(decoded.breakdowns == nil)
    }
}
