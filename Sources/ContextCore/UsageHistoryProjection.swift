import Foundation

public enum UsageHistoryGrouping: String, CaseIterable, Identifiable, Sendable {
    case model = "Model"
    case provider = "Model provider"
    case project = "Project"
    public var id: String { rawValue }
}

public struct UsageHistorySeries: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let value: Double
}

public struct UsageHistoryBucket: Identifiable, Sendable {
    public let period: String
    public let values: [String: Double]
    public var id: String { period }
    public var total: Double { values.values.reduce(0, +) }
}

/// The timeline and exact breakdown share one projection from the local
/// daily ledger for model and provider views. Project grouping is explicitly a
/// separate session ledger, bucketed by last activity, not a daily allocation.
public struct UsageHistoryProjection: Sendable {
    public let series: [UsageHistorySeries]
    public let buckets: [UsageHistoryBucket]
    public let total: Double
    public let unattributed: Double
    public let grouping: UsageHistoryGrouping
    public let metric: UsageChartMetric

    public init(report: LocalUsageReport, agents: Set<String>, range: UsageRange,
                scale: UsageChartScale, grouping: UsageHistoryGrouping,
                metric: UsageChartMetric, now: Date = Date()) {
        self.grouping = grouping
        self.metric = metric
        var grouped: [String: [String: Double]] = [:]
        var totals: [String: Double] = [:]
        var labels = ["unattributed": "Unattributed"]
        if grouping == .project {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: report.provenance.timezone) ?? .current
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let fractionalISO = ISO8601DateFormatter()
            fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plainISO = ISO8601DateFormatter()
            plainISO.formatOptions = [.withInternetDateTime]
            for session in report.sessions ?? [] where agents.isEmpty || agents.contains(session.agent) {
                guard let activity = session.lastActivity.flatMap({ fractionalISO.date(from: $0) ?? plainISO.date(from: $0) }),
                      activity <= now else { continue }
                let day = formatter.string(from: activity)
                guard range.includes(day: day, now: now, timezone: report.provenance.timezone) else { continue }
                let period = Self.periodKey(day, scale: scale)
                let id = session.project.map { "project:\($0)" } ?? "unattributed"
                if let project = session.project { labels[id] = UsageProjectIdentity.name(project) }
                let value = max(0, metric.value(session.totals))
                grouped[period, default: [:]][id, default: 0] += value
                totals[id, default: 0] += value
            }
        } else {
            for day in report.daily where range.includes(day: day.period, now: now, timezone: report.provenance.timezone) {
                let period = Self.periodKey(day.period, scale: scale)
                for agent in day.agents where agents.isEmpty || agents.contains(agent.agent) {
                    let canonical = max(0, metric.value(agent.totals))
                    var attributed: [String: Double] = [:]
                    for model in agent.models {
                        let id: String
                        if grouping == .provider {
                            let provider = ModelProviderClassifier.label(for: model.model)
                            id = "provider:\(provider)"
                            labels[id] = provider
                        } else {
                            id = "model:\(model.model)"
                            labels[id] = model.model
                        }
                        attributed[id, default: 0] += max(0, metric.value(model.totals))
                    }
                    // Reject an inconsistent optional attribution instead of
                    // inflating the authoritative daily total.
                    if attributed.values.reduce(0, +) > canonical + 0.000_001 {
                        attributed.removeAll()
                    }
                    let remainder = max(0, canonical - attributed.values.reduce(0, +))
                    if remainder > 0 { attributed["unattributed", default: 0] += remainder }
                    for (id, value) in attributed where value > 0 {
                        grouped[period, default: [:]][id, default: 0] += value
                        totals[id, default: 0] += value
                    }
                    if grouped[period] == nil { grouped[period] = [:] }
                }
            }
        }
        unattributed = totals["unattributed"] ?? 0
        total = totals.values.reduce(0, +)
        series = totals.map { id, value in
            UsageHistorySeries(id: id, label: labels[id] ?? id, value: value)
        }.sorted { $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value }

        buckets = Self.condense(grouped, scale: scale)
    }

    /// Devin is a separate indexed source. It can share the chart grammar,
    /// but never joins ccusage totals or claims project/cost attribution.
    public init(devin: DevinUsage, range: UsageRange, scale: UsageChartScale,
                grouping: UsageHistoryGrouping = .model, metric: UsageChartMetric, now: Date = Date()) {
        self.grouping = grouping == .provider ? .provider : .model
        self.metric = metric
        var grouped: [String: [String: Double]] = [:]
        var totals: [String: Double] = [:]
        var labels: [String: String] = [:]
        for day in devin.daily ?? [] where range.includes(day: day.period, now: now, timezone: TimeZone.current.identifier) {
            let period = Self.periodKey(day.period, scale: scale)
            for model in day.models {
                let value: Double = switch metric {
                case .generated: Double(max(0, model.generatedTokens))
                case .cacheRead: Double(max(0, model.cacheReadTokens))
                case .estimatedCost: 0
                }
                guard value > 0 else { continue }
                let id: String
                if self.grouping == .provider {
                    let provider = ModelProviderClassifier.label(for: model.model)
                    id = "provider:\(provider)"
                    labels[id] = provider
                } else {
                    id = "model:\(model.model)"
                    labels[id] = model.model
                }
                grouped[period, default: [:]][id, default: 0] += value
                totals[id, default: 0] += value
            }
        }
        unattributed = 0
        total = totals.values.reduce(0, +)
        series = totals.map { id, value in
            UsageHistorySeries(id: id, label: labels[id] ?? id, value: value)
        }.sorted { $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value }
        buckets = Self.condense(grouped, scale: scale)
    }

    private static func condense(_ grouped: [String: [String: Double]], scale: UsageChartScale) -> [UsageHistoryBucket] {
        var ordered = grouped.keys.sorted().map { UsageHistoryBucket(period: $0, values: grouped[$0]!) }
        let limit = scale.maximumBars
        if ordered.count > limit {
            var earlier: [String: Double] = [:]
            for bucket in ordered.prefix(ordered.count - (limit - 1)) {
                for (id, value) in bucket.values { earlier[id, default: 0] += value }
            }
            ordered = [UsageHistoryBucket(period: "Earlier", values: earlier)] + ordered.suffix(limit - 1)
        }
        return ordered
    }

    public var visibleSeries: [UsageHistorySeries] {
        guard series.count > 5 else { return series }
        return Array(series.prefix(4)) + [
            UsageHistorySeries(id: "other", label: "Other (\(series.count - 4))",
                               value: series.dropFirst(4).reduce(0) { $0 + $1.value })
        ]
    }

    public func value(in bucket: UsageHistoryBucket, series item: UsageHistorySeries) -> Double {
        if item.id != "other" { return bucket.values[item.id] ?? 0 }
        let primary = Set(series.prefix(4).map(\.id))
        return bucket.values.filter { !primary.contains($0.key) }.values.reduce(0, +)
    }

    private static func periodKey(_ day: String, scale: UsageChartScale) -> String {
        if scale == .day { return day }
        if scale == .month { return String(day.prefix(7)) }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return day }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: date) + 5) % 7), to: date) else {
            return day
        }
        let value = calendar.dateComponents([.year, .month, .day], from: monday)
        return String(format: "%04d-%02d-%02d", value.year ?? 0, value.month ?? 0, value.day ?? 0)
    }
}
