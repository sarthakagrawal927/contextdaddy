import Foundation
import Darwin
import XCTest
@testable import DiskCore

final class ArchiveCleanupTests: XCTestCase {
    private let zip = Data(base64Encoded: "UEsDBBQAAAAAAEaHK10c4gQSFwAAABcAAAAKAAAAUkVBRE1FLnR4dERpc3Bvc2FibGUgYXJjaGl2ZSB0ZXN0UEsBAhQDFAAAAAAARocrXRziBBIXAAAAFwAAAAoAAAAAAAAAAAAAAIABAAAAAFJFQURNRS50eHRQSwUGAAAAAAEAAQA4AAAAPwAAAAAA")!
    private func fixture() throws -> (URL, URL, URL, ConversationArchiveReceipt) {
        let home = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/")).appendingPathComponent("archive-cleanup-" + UUID().uuidString)
        let source = home.appendingPathComponent(".codex/sessions/old.jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original conversation".utf8).write(to: source)
        let archive = home.appendingPathComponent("export.zip")
        try zip.write(to: archive)
        var info = stat(); XCTAssertEqual(lstat(source.path, &info), 0)
        let record: [String: Any] = ["path": source.path, "device": UInt64(info.st_dev), "inode": info.st_ino, "size": info.st_size,
            "modifiedSeconds": info.st_mtimespec.tv_sec, "modifiedNanoseconds": info.st_mtimespec.tv_nsec,
            "changedSeconds": info.st_ctimespec.tv_sec, "changedNanoseconds": info.st_ctimespec.tv_nsec]
        let data = try JSONSerialization.data(withJSONObject: ["format": "memory-pack-receipt/1", "sourceFiles": 1,
            "sourceBytes": info.st_size, "sessions": 1, "prompts": 1, "messages": 1, "skippedFiles": 0, "sources": [record]])
        return (home, source, archive, try JSONDecoder().decode(ConversationArchiveReceipt.self, from: data))
    }
    func testVerifiedArchiveAndExactOriginalPassWithoutChangingEither() throws {
        let (home, source, archive, receipt) = try fixture()
        let original = try Data(contentsOf: source)
        let plan = try ArchiveCleanupVerifier.prepare(receipt: receipt, archive: archive, cutoff: Date().addingTimeInterval(1), home: home)
        XCTAssertEqual(plan.items.count, 1)
        try ArchiveCleanupVerifier.validate(plan, home: home)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: archive), zip)
    }
    func testChangedSourceBlocksCleanupEvenWhenLengthMatches() throws {
        let (home, source, archive, receipt) = try fixture()
        let plan = try ArchiveCleanupVerifier.prepare(receipt: receipt, archive: archive, cutoff: Date().addingTimeInterval(1), home: home)
        try Data("modified conversation".utf8).write(to: source)
        XCTAssertThrowsError(try ArchiveCleanupVerifier.validate(plan, home: home))
    }
    func testChangedArchiveBlocksCleanup() throws {
        let (home, _, archive, receipt) = try fixture()
        let plan = try ArchiveCleanupVerifier.prepare(receipt: receipt, archive: archive, cutoff: Date().addingTimeInterval(1), home: home)
        try Data("different archive".utf8).write(to: archive)
        XCTAssertThrowsError(try ArchiveCleanupVerifier.validate(plan, home: home))
    }
    func testArchiveMetadataChangeRefreshesIdentityAfterStableContentHash() throws {
        let (home, source, archive, receipt) = try fixture()
        let plan = try ArchiveCleanupVerifier.prepare(receipt: receipt, archive: archive, cutoff: Date().addingTimeInterval(1), home: home)
        var info = stat(); XCTAssertEqual(lstat(archive.path, &info), 0)
        XCTAssertEqual(chmod(archive.path, info.st_mode ^ 0o100), 0)

        let refreshed = try ArchiveCleanupVerifier.validate(plan, home: home)
        XCTAssertNoThrow(try ArchiveCleanupVerifier.validateArchiveIdentity(refreshed))
        XCTAssertNoThrow(try ArchiveCleanupVerifier.validateItem(refreshed.items[0], home: home))
        XCTAssertEqual(try Data(contentsOf: source), Data("original conversation".utf8))
    }
    func testCorruptZIPCannotAuthorizeCleanup() throws {
        let (home, _, archive, receipt) = try fixture()
        var corrupt = zip; corrupt[48] ^= 1
        try corrupt.write(to: archive)
        XCTAssertThrowsError(try ArchiveCleanupVerifier.prepare(receipt: receipt, archive: archive, cutoff: Date().addingTimeInterval(1), home: home))
    }
    func testRecentAndOutsideHomeSourcesAreRejected() throws {
        let (home, _, archive, receipt) = try fixture()
        XCTAssertThrowsError(try ArchiveCleanupVerifier.prepare(receipt: receipt, archive: archive, cutoff: Date(timeIntervalSince1970: 0), home: home))
        XCTAssertThrowsError(try ArchiveCleanupVerifier.prepare(receipt: receipt, archive: archive, cutoff: Date().addingTimeInterval(1), home: home.appendingPathComponent("other")))
    }
    func testReplacedSourceAndSymlinkAreRejected() throws {
        let (home, source, archive, receipt) = try fixture()
        let plan = try ArchiveCleanupVerifier.prepare(receipt: receipt, archive: archive, cutoff: Date().addingTimeInterval(1), home: home)
        let moved = source.appendingPathExtension("original")
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
        XCTAssertThrowsError(try ArchiveCleanupVerifier.validate(plan, home: home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }
}
