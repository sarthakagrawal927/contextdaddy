import Foundation
import Darwin
import XCTest
@testable import DiskCore

final class StorageAccessTests: XCTestCase {
    func testMissingLocationsAreUnknownRatherThanDenied() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(FullDiskAccessProbe.status(homeDirectory: home), .unknown)
    }

    func testReadableProtectedDirectoryIsAccessible() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Mail"), withIntermediateDirectories: true)
        XCTAssertEqual(FullDiskAccessProbe.status(homeDirectory: home), .accessible)
    }

    func testFilesAndSymlinksAreNotAccessProof() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = home.appendingPathComponent("Library")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try Data().write(to: library.appendingPathComponent("Mail"))
        try fm.createSymbolicLink(at: library.appendingPathComponent("Messages"), withDestinationURL: library)
        XCTAssertEqual(FullDiskAccessProbe.status(homeDirectory: home), .unknown)
    }

    func testBlockedLocationOverridesAnotherAccessibleLocation() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permission checks") }
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let blocked = home.appendingPathComponent("Library/Messages")
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/Mail"), withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        XCTAssertEqual(FullDiskAccessProbe.status(homeDirectory: home), .limited)
    }
}
