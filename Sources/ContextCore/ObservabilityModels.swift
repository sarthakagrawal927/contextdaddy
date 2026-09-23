import Foundation

public enum TelemetrySignal: String, Codable, CaseIterable, Sendable, Identifiable {
    case contextTokens = "Context tokens"
    case networkCalls = "Network calls"
    case toolCalls = "Tool calls"
    case internetUsage = "Internet usage"

    public var id: String { rawValue }
}

public struct TelemetryValue: Codable, Sendable, Equatable {
    public let value: Double?
    public let unit: String
    public let quality: EvidenceQuality
    public let note: String

    public init(value: Double?, unit: String, quality: EvidenceQuality, note: String) {
        self.value = value
        self.unit = unit
        self.quality = quality
        self.note = note
    }
}

public struct AgentTelemetry: Identifiable, Codable, Sendable, Equatable {
    public let runtime: AgentRuntime
    public let connected: Bool
    public let source: String
    public let signals: [TelemetrySignal: TelemetryValue]

    public var id: String { runtime.rawValue }
}

public struct TelemetryBreakdownItem: Identifiable, Codable, Sendable, Equatable {
    public let name: String
    public let value: Double
    public let unit: String
    public let detail: String?
    public let quality: EvidenceQuality

    public init(name: String, value: Double, unit: String, detail: String? = nil, quality: EvidenceQuality = .measured) {
        self.name = name
        self.value = value
        self.unit = unit
        self.detail = detail
        self.quality = quality
    }

    public var id: String { name + ":" + (detail ?? "") }
}

public struct TelemetryBreakdownSection: Identifiable, Codable, Sendable, Equatable {
    public let title: String
    public let note: String
    public let items: [TelemetryBreakdownItem]

    public init(title: String, note: String, items: [TelemetryBreakdownItem]) {
        self.title = title
        self.note = note
        self.items = items
    }

    public var id: String { title }
}

public struct OTelRun: Identifiable, Codable, Sendable, Equatable {
    public let traceID: String
    public let startedAt: Date
    public let durationMilliseconds: Double
    public let rootService: String
    public let rootOperation: String
    public let spanCount: Int
    public let quality: EvidenceQuality

    public init(traceID: String, startedAt: Date, durationMilliseconds: Double, rootService: String,
                rootOperation: String, spanCount: Int, quality: EvidenceQuality = .measured) {
        self.traceID = traceID
        self.startedAt = startedAt
        self.durationMilliseconds = durationMilliseconds
        self.rootService = rootService
        self.rootOperation = rootOperation
        self.spanCount = spanCount
        self.quality = quality
    }

    public var id: String { traceID }
}

public struct ObservabilitySnapshot: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let collectorReachable: Bool
    public let agents: [AgentTelemetry]
    public let notes: [String]
    /// Optional for backward-compatible decoding of snapshots written before
    /// run and breakdown normalization existed.
    public let recentRuns: [OTelRun]?
    public let breakdowns: [TelemetryBreakdownSection]?
    /// Claude metrics are a separate provider ledger, never merged into Codex.
    public let claudeBreakdowns: [TelemetryBreakdownSection]?
    public let sourceSchema: String?

    public init(generatedAt: Date, collectorReachable: Bool, agents: [AgentTelemetry], notes: [String],
                recentRuns: [OTelRun]? = nil, breakdowns: [TelemetryBreakdownSection]? = nil,
                claudeBreakdowns: [TelemetryBreakdownSection]? = nil, sourceSchema: String? = nil) {
        self.generatedAt = generatedAt
        self.collectorReachable = collectorReachable
        self.agents = agents
        self.notes = notes
        self.recentRuns = recentRuns
        self.breakdowns = breakdowns
        self.claudeBreakdowns = claudeBreakdowns
        self.sourceSchema = sourceSchema
    }

    public static var unavailable: ObservabilitySnapshot {
        unavailable(reason: "No local telemetry was verified.")
    }

    public static func unavailable(reason: String) -> ObservabilitySnapshot {
        ObservabilitySnapshot(
            generatedAt: Date(),
            collectorReachable: false,
            agents: AgentRuntime.allCases.map { runtime in
                AgentTelemetry(runtime: runtime, connected: false, source: "No verified adapter", signals: Dictionary(uniqueKeysWithValues: TelemetrySignal.allCases.map {
                    ($0, TelemetryValue(value: nil, unit: $0 == .contextTokens ? "tokens" : "events", quality: .unavailable, note: reason))
                }))
            },
            notes: [reason, "ContextDaddy never captures prompt or response bodies."],
            recentRuns: [], breakdowns: [], claudeBreakdowns: [], sourceSchema: nil
        )
    }
}
