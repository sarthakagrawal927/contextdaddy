import Foundation
import Testing
@testable import ContextCore

struct LocalObservabilityClientTests {
    @Test func readsExistingLocalStackWhenExplicitlyRequested() async {
        // Hosted CI has no operator-owned loopback collector. Keep this smoke
        // available locally without making the portable suite depend on it.
        guard ProcessInfo.processInfo.environment["CONTEXTDADDY_TEST_LIVE_OTEL"] == "1" else { return }
        let snapshot = await LocalObservabilityClient().load()
        #expect(snapshot.collectorReachable, Comment(rawValue: snapshot.notes.joined(separator: " ")))
        #expect(snapshot.agents.first { $0.runtime == .codex }?.signals[.contextTokens]?.value != nil)
        #expect(snapshot.sourceSchema == "codex-native-otel+claude-code-metrics/prometheus-tempo-v1")
        #expect(snapshot.breakdowns?.contains { $0.title == "Tools · 24h" } == true)
        #expect(snapshot.breakdowns?.contains { $0.title == "Skills injected · 24h" } == true)
        #expect(snapshot.recentRuns != nil)
    }

    @Test func decodesPrometheusLabelsAndValues() throws {
        let json = Data(#"{"status":"success","data":{"resultType":"vector","result":[{"metric":{"tool":"exec_command"},"value":[1790101336.1,"42.5"]}]}}"#.utf8)
        let payload = try JSONDecoder().decode(PrometheusResponse.self, from: json)
        #expect(payload.data.result.first?.metric["tool"] == "exec_command")
        #expect(payload.data.result.first?.rawValue == "42.5")
    }

    @Test func decodesTempoSessionRoots() throws {
        let json = Data(#"{"traces":[{"traceID":"abc123","rootServiceName":"codex-app-server","rootTraceName":"session_loop","startTimeUnixNano":"1790100374775191000","durationMs":731918,"serviceStats":{"codex-app-server":{"spanCount":7}}}]}"#.utf8)
        let payload = try JSONDecoder().decode(TempoSearchResponse.self, from: json)
        #expect(payload.traces.first?.traceID == "abc123")
        #expect(payload.traces.first?.durationMs == 731_918)
        #expect(payload.traces.first?.serviceStats["codex-app-server"]?.spanCount == 7)
    }

    @Test func claudeMetricsStaySeparateAndDoNotInventToolOrNetworkCounts() {
        let result = LocalObservabilityClient.claudeLoad(
            types: [PrometheusSample(metric: ["type": "input"], value: 40),
                    PrometheusSample(metric: ["type": "output"], value: 20),
                    PrometheusSample(metric: ["type": "cacheRead"], value: 100)],
            models: [PrometheusSample(metric: ["model": "claude-sonnet"], value: 160)],
            sessions: [PrometheusSample(metric: [:], value: 2)],
            costs: [PrometheusSample(metric: [:], value: 0.42)])
        #expect(result.agent.runtime == .claude)
        #expect(result.agent.connected)
        #expect(result.agent.signals[.contextTokens]?.value == 160)
        #expect(result.agent.signals[.toolCalls]?.value == nil)
        #expect(result.agent.signals[.networkCalls]?.value == nil)
        #expect(result.sections.first?.items.count == 3)
    }

    @Test func claudeWithoutSamplesIsUnavailableNotZero() {
        let result = LocalObservabilityClient.claudeLoad(types: [], models: [], sessions: [], costs: [])
        #expect(!result.agent.connected)
        #expect(result.agent.signals[.contextTokens]?.value == nil)
        #expect(result.agent.signals[.contextTokens]?.quality == .unavailable)
    }

    @Test func claudeSingleSampleIsConnectedButCannotClaimRangeTokens() {
        let result = LocalObservabilityClient.claudeLoad(types: [], models: [], sessions: [], costs: [],
            presence: [PrometheusSample(metric: [:], value: 1)])
        #expect(result.agent.connected)
        #expect(result.agent.signals[.contextTokens]?.value == nil)
    }
}
