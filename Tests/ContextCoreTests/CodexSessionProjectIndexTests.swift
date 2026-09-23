import Foundation
import SQLite3
import Testing
@testable import ContextCore

struct CodexSessionProjectIndexTests {
    @Test func joinsOnlySessionMetadataUnderExpectedRoot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("contextdaddy-index-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("state.sqlite")
        let sessions = folder.appendingPathComponent("sessions", isDirectory: true)
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK, let connection else {
            Issue.record("Could not create SQLite fixture")
            return
        }
        defer { sqlite3_close(connection) }
        #expect(sqlite3_exec(connection, "CREATE TABLE threads (rollout_path TEXT, cwd TEXT)", nil, nil, nil) == SQLITE_OK)
        let sql = "INSERT INTO threads (rollout_path, cwd) VALUES (?1, ?2)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            Issue.record("Could not prepare SQLite fixture")
            return
        }
        defer { sqlite3_finalize(statement) }
        for (path, cwd) in [
            (sessions.appendingPathComponent("2026/09/23/rollout-one.jsonl").path, "/projects/alpha"),
            (sessions.appendingPathComponent("2026/09/23/rollout-two.jsonl").path, "/"),
            (folder.appendingPathComponent("foreign/rollout-three.jsonl").path, "/projects/other"),
        ] {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            path.withCString { pathBytes in
                cwd.withCString { cwdBytes in
                    sqlite3_bind_text(statement, 1, pathBytes, -1, nil)
                    sqlite3_bind_text(statement, 2, cwdBytes, -1, nil)
                    #expect(sqlite3_step(statement) == SQLITE_DONE)
                }
            }
        }
        let result = try CodexSessionProjectIndex(databaseURL: database, sessionsRoot: sessions).load()
        #expect(result == ["2026/09/23/rollout-one": "/projects/alpha"])
    }
}
