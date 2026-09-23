import Foundation
import SQLite3

public enum DevinUsageError: Error, LocalizedError, Sendable {
    case unreadable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unreadable: "Devin's local session index could not be read."
        case .timedOut: "Devin's local session scan exceeded its 30-second limit."
        }
    }
}

/// Reads only session identifiers, timestamps, model names, and token metrics.
/// Chat text is extracted inside neither Swift nor the SQL result set.
public struct DevinUsageClient: Sendable {
    private let databaseURL: URL?

    public init(databaseURL: URL? = nil) { self.databaseURL = databaseURL }

    public func load() async throws -> DevinUsage {
        try await Task.detached(priority: .utility) { try scan() }.value
    }

    private func scan() throws -> DevinUsage {
        let path = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/devin/cli/sessions.db")
        guard FileManager.default.isReadableFile(atPath: path.path) else {
            return DevinUsage(status: "unavailable", source: "Devin CLI sessions.db · read-only",
                              windows: [], daily: [], limitations: ["Devin's local sessions.db is not available."], costAvailable: false)
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let connection else { throw DevinUsageError.unreadable }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 1_000)
        let deadline = ScanDeadline(Date().addingTimeInterval(30))
        sqlite3_progress_handler(connection, 1_000, { pointer in
            guard let pointer else { return 1 }
            let limit = Unmanaged<ScanDeadline>.fromOpaque(pointer).takeUnretainedValue()
            return Date() >= limit.date ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer { sqlite3_progress_handler(connection, 0, nil, nil) }

        let sessionsSQL = "SELECT id, COALESCE(model, '') FROM sessions ORDER BY last_activity_at DESC"
        let metricsSQL = """
            SELECT COALESCE(MAX(json_extract(chat_message, '$.metadata.generation_model')), ?2),
                   MIN(created_at),
                   COALESCE(MAX(json_extract(chat_message, '$.metadata.metrics.input_tokens')), 0),
                   COALESCE(MAX(json_extract(chat_message, '$.metadata.metrics.output_tokens')), 0),
                   COALESCE(MAX(json_extract(chat_message, '$.metadata.metrics.cache_read_tokens')), 0),
                   COALESCE(MAX(json_extract(chat_message, '$.metadata.metrics.cache_creation_tokens')), 0)
              FROM message_nodes
             WHERE session_id = ?1
               AND json_extract(chat_message, '$.role') = 'assistant'
               AND json_extract(chat_message, '$.metadata.metrics.input_tokens') IS NOT NULL
             GROUP BY json_extract(chat_message, '$.message_id')
            """
        var sessions: OpaquePointer?
        var metrics: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sessionsSQL, -1, &sessions, nil) == SQLITE_OK,
              let sessions else { throw DevinUsageError.unreadable }
        defer { sqlite3_finalize(sessions) }
        guard sqlite3_prepare_v2(connection, metricsSQL, -1, &metrics, nil) == SQLITE_OK,
              let metrics else { throw DevinUsageError.unreadable }
        defer { sqlite3_finalize(metrics) }
        let now = Date()
        var aggregations = Dictionary(uniqueKeysWithValues: UsageRange.allCases.map { ($0.rawValue, DevinAggregation()) })
        var dailyAggregations: [String: DevinAggregation] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        var sawUsage = false
        var sessionStep = sqlite3_step(sessions)
        while sessionStep == SQLITE_ROW {
            guard let idBytes = sqlite3_column_text(sessions, 0) else { continue }
            let id = String(cString: idBytes)
            let fallback = sqlite3_column_text(sessions, 1).map { String(cString: $0) } ?? ""
            let step: Int32 = id.withCString { idPointer in
                fallback.withCString { modelPointer in
                    sqlite3_bind_text(metrics, 1, idPointer, -1, nil)
                    sqlite3_bind_text(metrics, 2, modelPointer, -1, nil)
                    defer { sqlite3_reset(metrics); sqlite3_clear_bindings(metrics) }
                    var metricStep = sqlite3_step(metrics)
                    while metricStep == SQLITE_ROW {
                        let model = sqlite3_column_text(metrics, 0).map { String(cString: $0) }
                            .flatMap { $0.isEmpty ? nil : $0 } ?? "Unidentified model"
                        let timestamp = sqlite3_column_int64(metrics, 1)
                        if timestamp > 0 {
                            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                            if date <= now {
                                let input = max(0, sqlite3_column_int64(metrics, 2))
                                let output = max(0, sqlite3_column_int64(metrics, 3))
                                let cacheRead = max(0, sqlite3_column_int64(metrics, 4))
                                let cacheCreation = max(0, sqlite3_column_int64(metrics, 5))
                                let generated = Self.add(Self.add(input, cacheCreation), output)
                                sawUsage = true
                                let day = dayFormatter.string(from: date)
                                var daily = dailyAggregations[day] ?? DevinAggregation()
                                daily.record(session: id, model: model, generated: generated, cache: cacheRead)
                                dailyAggregations[day] = daily
                                for range in UsageRange.allCases where Self.includes(date, range: range, now: now) {
                                    var total = aggregations[range.rawValue] ?? DevinAggregation()
                                    total.record(session: id, model: model, generated: generated, cache: cacheRead)
                                    aggregations[range.rawValue] = total
                                }
                            }
                        }
                        metricStep = sqlite3_step(metrics)
                    }
                    return metricStep
                }
            }
            if step != SQLITE_DONE {
                throw Date() >= deadline.date ? DevinUsageError.timedOut : DevinUsageError.unreadable
            }
            sessionStep = sqlite3_step(sessions)
        }
        guard sessionStep == SQLITE_DONE else {
            throw Date() >= deadline.date ? DevinUsageError.timedOut : DevinUsageError.unreadable
        }
        let windows = UsageRange.allCases.map { range in
            (aggregations[range.rawValue] ?? DevinAggregation()).window(range.rawValue)
        }
        let daily = dailyAggregations.keys.sorted().map { day -> DevinUsageDay in
            let total = dailyAggregations[day]!.window(day)
            return DevinUsageDay(period: day, sessions: total.sessions, generatedTokens: total.generatedTokens,
                                 cacheReadTokens: total.cacheReadTokens, models: total.models)
        }
        return DevinUsage(status: sawUsage ? "ready" : "empty", source: "Devin CLI sessions.db · read-only",
                          windows: windows, daily: daily, limitations: [
                            "Devin is counted separately from ccusage and provider allowance.",
                            "Token metrics are deduplicated by message ID. Cost is unavailable without verified provider billing rates.",
                          ], costAvailable: false)
    }

    private static func includes(_ date: Date, range: UsageRange, now: Date) -> Bool {
        guard range != .all else { return true }
        let days = switch range { case .week: 7; case .month: 30; case .quarter: 90; case .all: 0 }
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: now)) ?? now
        return date >= start
    }

    private static func add(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}

private final class ScanDeadline {
    let date: Date
    init(_ date: Date) { self.date = date }
}

private struct DevinAggregation {
    var sessions: Set<String> = []
    var generated: Int64 = 0
    var cache: Int64 = 0
    var models: [String: DevinModelAggregation] = [:]

    mutating func record(session: String, model: String, generated amount: Int64, cache reads: Int64) {
        sessions.insert(session)
        generated = add(generated, amount)
        cache = add(cache, reads)
        var row = models[model] ?? DevinModelAggregation()
        row.sessions.insert(session)
        row.generated = add(row.generated, amount)
        row.cache = add(row.cache, reads)
        models[model] = row
    }

    func window(_ name: String) -> DevinUsageWindow {
        var rows: [DevinUsageModel] = []
        for (name, row) in models {
            rows.append(DevinUsageModel(model: name, sessions: Int64(row.sessions.count),
                                        generatedTokens: row.generated, cacheReadTokens: row.cache, costUSD: 0))
        }
        rows.sort { left, right in
            if left.generatedTokens == right.generatedTokens { return left.model < right.model }
            return left.generatedTokens > right.generatedTokens
        }
        return DevinUsageWindow(window: name, sessions: Int64(sessions.count), generatedTokens: generated,
                                cacheReadTokens: cache, costUSD: 0, models: rows)
    }

    private func add(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}

private struct DevinModelAggregation {
    var sessions: Set<String> = []
    var generated: Int64 = 0
    var cache: Int64 = 0
}
