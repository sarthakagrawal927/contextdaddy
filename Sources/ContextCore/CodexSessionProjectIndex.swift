import Foundation
import SQLite3

/// Joins ccusage's Codex session key to the Codex thread index's explicit cwd.
/// Reads only rollout_path and cwd; prompt, response, and config values are
/// neither queried nor retained. Failure leaves project identity unavailable.
public struct CodexSessionProjectIndex: Sendable {
    private let databaseURL: URL?
    private let sessionsRoot: URL?

    public init(databaseURL: URL? = nil, sessionsRoot: URL? = nil) {
        self.databaseURL = databaseURL
        self.sessionsRoot = sessionsRoot
    }

    public func load() throws -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = sessionsRoot ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let candidates = databaseURL.map { [$0] } ?? [
            home.appendingPathComponent(".codex/state_5.sqlite"),
            home.appendingPathComponent(".codex/sqlite/state_5.sqlite"),
        ]
        guard let database = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
            return [:]
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let connection else { throw IndexError.unreadable }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 1_000)
        let sql = "SELECT rollout_path, cwd FROM threads"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw IndexError.unreadable }
        defer { sqlite3_finalize(statement) }

        let prefix = root.standardizedFileURL.path + "/"
        let deadline = Date().addingTimeInterval(10)
        var results: [String: String] = [:]
        var rows = 0
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            rows += 1
            guard rows <= 100_000, Date() < deadline else { throw IndexError.boundedScanExceeded }
            if let pathBytes = sqlite3_column_text(statement, 0), let cwdBytes = sqlite3_column_text(statement, 1) {
                let path = String(cString: pathBytes)
                let cwd = String(cString: cwdBytes)
                if path.hasPrefix(prefix), path.hasSuffix(".jsonl"),
                   cwd.hasPrefix("/"), cwd != "/", cwd.utf8.count <= 4096,
                   !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                    let key = String(path.dropFirst(prefix.count).dropLast(".jsonl".count))
                    if !key.isEmpty { results[key] = cwd }
                }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw IndexError.unreadable }
        return results
    }

    public enum IndexError: Error, Sendable {
        case unreadable
        case boundedScanExceeded
    }
}
