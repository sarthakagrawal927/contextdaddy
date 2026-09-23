import Foundation

public enum UsageChartMetric: String, CaseIterable, Identifiable, Sendable {
    case generated = "Generated"
    case cacheRead = "Cache read"
    case estimatedCost = "Est. cost"

    public var id: String { rawValue }

    public func value(_ totals: UsageTotals) -> Double {
        switch self {
        case .generated: Double(totals.generatedTokens)
        case .cacheRead: Double(totals.cacheReadTokens)
        case .estimatedCost: totals.costUSD
        }
    }
}

public enum UsageChartScale: String, CaseIterable, Identifiable, Sendable {
    case day = "Day"
    case week = "Week"
    case month = "Month"

    public var id: String { rawValue }
    var maximumBars: Int {
        switch self {
        case .day: 60
        case .week: 52
        case .month: 24
        }
    }
}

public struct UsageChartPoint: Identifiable, Sendable {
    public let period: String
    public let value: Double
    public var id: String { period }
}

public struct UsageModelSummary: Identifiable, Sendable {
    public let name: String
    public let generatedTokens: UInt64
    public let cacheReadTokens: UInt64
    public let costUSD: Double
    public let priced: Bool
    public let fallback: Bool
    public var id: String { name }
}

public struct UsageProjectSummary: Identifiable, Sendable {
    public let path: String?
    public let generatedTokens: UInt64
    public let cacheReadTokens: UInt64
    public let costUSD: Double
    public let sessions: Int
    public var id: String { path ?? "unattributed" }
    public var name: String { path.map(UsageProjectIdentity.name) ?? "Unattributed" }
}

public struct UsageRecentSession: Identifiable, Sendable {
    public let id: String
    public let project: String?
    public let lastActivity: String?
    public let generatedTokens: UInt64
    public let cacheReadTokens: UInt64
    public let costUSD: Double
    public var projectName: String { project.map(UsageProjectIdentity.name) ?? "Unattributed" }
}

/// The local-log dashboard never mixes provider allowance, OTEL, or Devin's
/// separately indexed source into ccusage totals. Project numbers come from
/// session attribution and may not reconcile to daily accounting.
public struct UsageDashboardProjection: Sendable {
    public let slice: UsageSlice?
    public let trend: [UsageChartPoint]
    public let chartTruncated: Bool
    public let models: [UsageModelSummary]
    public let projects: [UsageProjectSummary]
    public let recentSessions: [UsageRecentSession]
    public let sessionCount: Int
    public let attributedSessionCount: Int

    public init(report: LocalUsageReport, service: UsageService, model: String?,
                range: UsageRange, scale: UsageChartScale, metric: UsageChartMetric,
                now: Date = Date()) {
        slice = report.slice(service: service, model: model, range: range, now: now)
        if service == .devin {
            let window = report.devin?.windows.first { $0.window == range.rawValue }
            models = (window?.models ?? []).filter { model == nil || $0.model == model }.map {
                UsageModelSummary(name: $0.model, generatedTokens: UInt64(max(0, $0.generatedTokens)),
                                  cacheReadTokens: UInt64(max(0, $0.cacheReadTokens)), costUSD: $0.costUSD,
                                  priced: report.devin?.costAvailable != false, fallback: false)
            }.sorted { $0.generatedTokens == $1.generatedTokens ? $0.name < $1.name : $0.generatedTokens > $1.generatedTokens }
            sessionCount = model == nil ? Int(max(0, window?.sessions ?? 0)) :
                Int(max(0, window?.models.first { $0.model == model }?.sessions ?? 0))
            trend = []
            chartTruncated = false
            projects = []
            recentSessions = []
            attributedSessionCount = 0
            return
        }

        guard let agentKey = service.agentKey, report.status == "ready" || report.status == "stale" else {
            trend = []
            chartTruncated = false
            models = []
            projects = []
            recentSessions = []
            sessionCount = 0
            attributedSessionCount = 0
            return
        }

        var modelTotals: [String: (generated: UInt64, cache: UInt64, cost: Double, priced: Bool, fallback: Bool)] = [:]
        var chartTotals: [String: Double] = [:]
        let calendar = Self.calendar(timezone: report.provenance.timezone)
        let dayFormatter = Self.dayFormatter(timezone: calendar.timeZone)
        let endDay = dayFormatter.string(from: now)
        let dayCount: Int? = switch range {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
        let cutoff = dayCount.flatMap { calendar.date(byAdding: .day, value: -($0 - 1), to: calendar.startOfDay(for: now)) }
        let startDay = cutoff.map { dayFormatter.string(from: $0) }
        func includes(_ day: String) -> Bool { day <= endDay && (startDay.map { day >= $0 } ?? true) }
        for day in report.daily where includes(day.period) {
            guard let agent = day.agents.first(where: { $0.agent == agentKey }) else { continue }
            for item in agent.models where model == nil || model == item.model {
                var row = modelTotals[item.model] ?? (0, 0, 0, true, false)
                row.generated = row.generated.saturatingAdding(item.totals.generatedTokens)
                row.cache = row.cache.saturatingAdding(item.totals.cacheReadTokens)
                row.cost += item.totals.costUSD
                row.priced = row.priced && item.priced
                row.fallback = row.fallback || item.fallback
                modelTotals[item.model] = row
            }
            guard let totals = model.flatMap({ name in agent.models.first { $0.model == name }?.totals }) ??
                    (model == nil ? agent.totals : nil),
                  let date = dayFormatter.date(from: day.period) else { continue }
            let key = Self.bucket(date: date, scale: scale, calendar: calendar, formatter: dayFormatter)
            chartTotals[key, default: 0] += metric.value(totals)
        }
        models = modelTotals.map { key, value in
            UsageModelSummary(name: key, generatedTokens: value.generated, cacheReadTokens: value.cache,
                              costUSD: value.cost, priced: value.priced, fallback: value.fallback)
        }.sorted { $0.generatedTokens == $1.generatedTokens ? $0.name < $1.name : $0.generatedTokens > $1.generatedTokens }
        let allPoints = chartTotals.keys.sorted().map { UsageChartPoint(period: $0, value: chartTotals[$0] ?? 0) }
        chartTruncated = allPoints.count > scale.maximumBars
        trend = Array(allPoints.suffix(scale.maximumBars))

        var projectTotals: [String: (generated: UInt64, cache: UInt64, cost: Double, sessions: Int)] = [:]
        var sessionRows: [UsageRecentSession] = []
        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainISO = ISO8601DateFormatter()
        plainISO.formatOptions = [.withInternetDateTime]
        for session in report.sessions ?? [] where session.agent == agentKey {
            if let cutoff {
                guard let activity = Self.activityDate(session.lastActivity,
                                                       fractionalISO: fractionalISO, plainISO: plainISO),
                      activity >= cutoff, activity <= now else { continue }
            }
            guard let totals = model.flatMap({ name in session.models.first { $0.model == name }?.totals }) ??
                    (model == nil ? session.totals : nil) else { continue }
            let key = session.project ?? ""
            var row = projectTotals[key] ?? (0, 0, 0, 0)
            row.generated = row.generated.saturatingAdding(totals.generatedTokens)
            row.cache = row.cache.saturatingAdding(totals.cacheReadTokens)
            row.cost += totals.costUSD
            row.sessions += 1
            projectTotals[key] = row
            sessionRows.append(UsageRecentSession(id: session.id, project: session.project,
                                                  lastActivity: session.lastActivity,
                                                  generatedTokens: totals.generatedTokens,
                                                  cacheReadTokens: totals.cacheReadTokens,
                                                  costUSD: totals.costUSD))
        }
        projects = projectTotals.map { key, value in
            UsageProjectSummary(path: key.isEmpty ? nil : key, generatedTokens: value.generated,
                                cacheReadTokens: value.cache, costUSD: value.cost, sessions: value.sessions)
        }.sorted { $0.generatedTokens == $1.generatedTokens ? $0.name < $1.name : $0.generatedTokens > $1.generatedTokens }
        sessionCount = sessionRows.count
        attributedSessionCount = sessionRows.filter { $0.project != nil }.count
        recentSessions = Array(sessionRows.sorted {
            let left = $0.lastActivity ?? ""
            let right = $1.lastActivity ?? ""
            return left == right ? $0.id < $1.id : left > right
        }.prefix(12))
    }

    private static func calendar(timezone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        calendar.firstWeekday = 2
        return calendar
    }

    private static func dayFormatter(timezone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timezone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func bucket(date: Date, scale: UsageChartScale, calendar: Calendar,
                               formatter: DateFormatter) -> String {
        switch scale {
        case .day: return formatter.string(from: date)
        case .week:
            let weekday = calendar.component(.weekday, from: date)
            let offset = (weekday + 5) % 7
            let start = calendar.date(byAdding: .day, value: -offset, to: date) ?? date
            return formatter.string(from: start)
        case .month:
            return String(format: "%04d-%02d", calendar.component(.year, from: date), calendar.component(.month, from: date))
        }
    }

    private static func activityDate(_ value: String?, fractionalISO: ISO8601DateFormatter,
                                     plainISO: ISO8601DateFormatter) -> Date? {
        guard let value else { return nil }
        return fractionalISO.date(from: value) ?? plainISO.date(from: value)
    }
}

private extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? .max : result
    }
}
