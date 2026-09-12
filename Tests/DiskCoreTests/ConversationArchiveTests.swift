import Foundation
import XCTest
@testable import DiskCore

final class ConversationArchiveTests: XCTestCase {
    func testPublishesCompleteArchiveAndReplacesApprovedRegularFile() throws {
        let root = try directory()
        let staged = root.appendingPathComponent("staged.zip")
        let destination = root.appendingPathComponent("export.zip")
        let archive = Data(base64Encoded: "UEsDBBQAAAAAAEaHK10c4gQSFwAAABcAAAAKAAAAUkVBRE1FLnR4dERpc3Bvc2FibGUgYXJjaGl2ZSB0ZXN0UEsBAhQDFAAAAAAARocrXRziBBIXAAAAFwAAAAoAAAAAAAAAAAAAAIABAAAAAFJFQURNRS50eHRQSwUGAAAAAAEAAQA4AAAAPwAAAAAA")!
        try archive.write(to: staged)
        try Data("previous export".utf8).write(to: destination)
        try ArchivePublisher.publish(staged: staged, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), archive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testInvalidArchivePreservesExistingExport() throws {
        let root = try directory()
        let staged = root.appendingPathComponent("incomplete.zip")
        let destination = root.appendingPathComponent("export.zip")
        let original = Data("existing archive must survive".utf8)
        try Data("incomplete".utf8).write(to: staged)
        try original.write(to: destination)
        XCTAssertThrowsError(try ArchivePublisher.publish(staged: staged, destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testRejectsSymlinkDestinationAndAgentFolders() throws {
        let root = try directory()
        let target = root.appendingPathComponent("original.zip")
        let link = root.appendingPathComponent("link.zip")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ArchivePublisher.validateDestination(link))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try ArchivePublisher.validateDestination(alias.appendingPathComponent("export.zip")))
        XCTAssertThrowsError(try ArchivePublisher.validateDestination(root.appendingPathComponent(".codex/export.zip")))
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
    }

    func testEmptyReceiptIsValidButNegativeOrUnknownReceiptsFail() throws {
        let root = try directory()
        let receipt = root.appendingPathComponent("receipt.json")
        let valid = #"{"format":"memory-pack-receipt/1","sourceFiles":0,"sourceBytes":0,"sessions":0,"prompts":0,"messages":0,"skippedFiles":2}"#
        try Data(valid.utf8).write(to: receipt)
        let result = try ConversationArchiveReceipt.read(from: receipt)
        XCTAssertEqual(result.sessions, 0)
        XCTAssertEqual(result.skippedFiles, 2)
        for invalid in [valid.replacingOccurrences(of: "receipt/1", with: "receipt/9"), valid.replacingOccurrences(of: "\"sessions\":0", with: "\"sessions\":-1")] {
            try Data(invalid.utf8).write(to: receipt)
            XCTAssertThrowsError(try ConversationArchiveReceipt.read(from: receipt))
        }
    }

    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/")).appendingPathComponent("storagedaddy-archive-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
