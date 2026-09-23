import Foundation
import SQLite3
import Testing
@testable import ContextCore

struct DevinUsageClientTests {
    @Test func installedIndexSmokeWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["CONTEXTDADDY_TEST_LIVE_DEVIN"] == "1" else { return }
        let result = try await DevinUsageClient().load()
        #expect(result.status == "ready" || result.status == "empty")
        #expect(result.costAvailable == false)
    }

    @Test func missingDatabaseIsUnavailableNotZeroUsage() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try await DevinUsageClient(databaseURL: path).load()
        #expect(result.status == "unavailable")
        #expect(result.windows.isEmpty)
        #expect(result.costAvailable == false)
    }

    @Test func deduplicatesAssistantMessagesAndKeepsCostUnavailable() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("devin-usage-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: path) }
        var database: OpaquePointer?
        #expect(sqlite3_open(path.path, &database) == SQLITE_OK)
        let connection = try #require(database)
        defer { sqlite3_close(connection) }
        let current = Int64(Date().timeIntervalSince1970)
        let schema = """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, model TEXT, last_activity_at INTEGER);
            CREATE TABLE message_nodes (session_id TEXT, created_at INTEGER, chat_message TEXT);
            INSERT INTO sessions VALUES ('session-a', 'fallback-model', \(current));
            INSERT INTO message_nodes VALUES ('session-a', \(current),
              '{"role":"assistant","message_id":"one","metadata":{"generation_model":"devin-model","metrics":{"input_tokens":3,"output_tokens":7,"cache_read_tokens":11,"cache_creation_tokens":5}}}');
            INSERT INTO message_nodes VALUES ('session-a', \(current),
              '{"role":"assistant","message_id":"one","metadata":{"generation_model":"devin-model","metrics":{"input_tokens":3,"output_tokens":7,"cache_read_tokens":11,"cache_creation_tokens":5}}}');
            INSERT INTO message_nodes VALUES ('session-a', \(current),
              '{"role":"user","message_id":"two","metadata":{"metrics":{"input_tokens":100}}}');
            """
        #expect(sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK)
        let result = try await DevinUsageClient(databaseURL: path).load()
        #expect(result.status == "ready")
        #expect(result.costAvailable == false)
        let week = try #require(result.windows.first { $0.window == "1w" })
        #expect(week.sessions == 1)
        #expect(week.generatedTokens == 15)
        #expect(week.cacheReadTokens == 11)
        #expect(week.models.map(\.model) == ["devin-model"])
        let day = try #require(result.daily?.first)
        #expect(day.generatedTokens == 15)
        #expect(day.cacheReadTokens == 11)
        #expect(day.models.map(\.model) == ["devin-model"])
        #expect(result.daily?.count == 1)
        let history = UsageHistoryProjection(devin: result, range: .week, scale: .day, metric: .generated)
        #expect(history.total == 15)
        #expect(history.series.map(\.label) == ["devin-model"])
        #expect(history.buckets.count == 1)
    }
}
