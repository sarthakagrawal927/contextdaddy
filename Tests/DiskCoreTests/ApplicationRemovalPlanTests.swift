import Darwin
import Foundation
import XCTest
@testable import DiskCore

final class ApplicationRemovalPlanTests: XCTestCase {
    func testPrepareAndValidateUnchangedApplication() async throws {
        let fixture = try ApplicationFixture()
        try fixture.write("Example.app/Contents/MacOS/example", bytes: [1, 2, 3])

        let plan = try await fixture.prepare()

        XCTAssertEqual(plan.url.standardizedFileURL.path, fixture.app.standardizedFileURL.path)
        XCTAssertGreaterThanOrEqual(plan.allocatedBytes, 0)
        try plan.validateIdentity()
        try await plan.validate()
    }

    func testAllowsInternalBundleSymlinks() async throws {
        let fixture = try ApplicationFixture()
        try fixture.write("Example.app/Contents/MacOS/example", bytes: [1, 2, 3])
        let frameworks = fixture.app.appendingPathComponent("Contents/Frameworks")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        XCTAssertEqual(symlink("../MacOS/example", frameworks.appendingPathComponent("example").path), 0)

        let plan = try await fixture.prepare()

        try await plan.validate()
    }

    func testValidateRejectsChangedAndNewBundleContents() async throws {
        let fixture = try ApplicationFixture()
        try fixture.write("Example.app/Contents/MacOS/example", bytes: [1])
        let plan = try await fixture.prepare()

        try fixture.write("Example.app/Contents/MacOS/example", bytes: [2, 3])
        await XCTAssertThrowsErrorAsync(try await plan.validate())

        let freshPlan = try await fixture.prepare()
        try fixture.write("Example.app/Contents/Resources/new.txt", bytes: [4])
        await XCTAssertThrowsErrorAsync(try await freshPlan.validate())
    }

    func testRejectsLeafAndAncestorSymlinks() async throws {
        let fixture = try ApplicationFixture()
        try fixture.write("Target.app/Contents/MacOS/target", bytes: [1])
        XCTAssertEqual(symlink("Target.app", fixture.root.appendingPathComponent("Applications/Link.app").path), 0)

        await XCTAssertThrowsErrorAsync(try await ApplicationRemovalPlan.prepare(
            url: fixture.root.appendingPathComponent("Applications/Link.app"),
            allowedRoots: [fixture.applications],
            scanBackend: .foundation
        ))

        let linkedApplications = fixture.root.appendingPathComponent("LinkedApplications")
        XCTAssertEqual(symlink(fixture.applications.path, linkedApplications.path), 0)
        await XCTAssertThrowsErrorAsync(try await ApplicationRemovalPlan.prepare(
            url: linkedApplications.appendingPathComponent("Target.app"),
            allowedRoots: [linkedApplications],
            scanBackend: .foundation
        ))
    }

    func testRejectsInvalidRootsAndNestedApplications() async throws {
        let fixture = try ApplicationFixture()
        try fixture.write("Example.app/Contents/MacOS/example", bytes: [1])
        try fixture.write("Example.app/Contents/Resources/Nested.app/Contents/MacOS/nested", bytes: [2])

        await XCTAssertThrowsErrorAsync(try await ApplicationRemovalPlan.prepare(
            url: fixture.app,
            allowedRoots: [fixture.root.appendingPathComponent("Elsewhere")],
            scanBackend: .foundation
        ))
        await XCTAssertThrowsErrorAsync(try await ApplicationRemovalPlan.prepare(
            url: fixture.app.appendingPathComponent("Contents/Resources/Nested.app"),
            allowedRoots: [fixture.applications],
            scanBackend: .foundation
        ))
    }

    func testAllowsRegularApplicationSubfolder() async throws {
        let fixture = try ApplicationFixture()
        let nested = fixture.applications.appendingPathComponent("Utilities/ThirdParty.app")
        let executable = nested.appendingPathComponent("Contents/MacOS/third-party")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: executable)

        let plan = try await ApplicationRemovalPlan.prepare(
            url: nested,
            allowedRoots: [fixture.applications],
            scanBackend: .foundation
        )

        try await plan.validate()
    }

    func testValidateIdentityRejectsReplacedApplicationRoot() async throws {
        let fixture = try ApplicationFixture()
        try fixture.write("Example.app/Contents/MacOS/example", bytes: [1])
        let plan = try await fixture.prepare()
        let prior = fixture.applications.appendingPathComponent("Example-prior.app")
        try FileManager.default.moveItem(at: fixture.app, to: prior)
        try fixture.write("Example.app/Contents/MacOS/replacement", bytes: [2])

        XCTAssertThrowsError(try plan.validateIdentity())
    }

    func testPrepareAndValidateRejectCancelledTasks() async throws {
        let fixture = try ApplicationFixture()
        try fixture.write("Example.app/Contents/MacOS/example", bytes: [1])
        let app = fixture.app
        let applications = fixture.applications
        let prepareTask = Task { () throws -> ApplicationRemovalPlan in
            while !Task.isCancelled { await Task.yield() }
            return try await ApplicationRemovalPlan.prepare(
                url: app,
                allowedRoots: [applications],
                scanBackend: .foundation
            )
        }
        prepareTask.cancel()
        await XCTAssertThrowsErrorAsync(try await prepareTask.value)

        let plan = try await fixture.prepare()
        let validateTask = Task { () throws -> Void in
            while !Task.isCancelled { await Task.yield() }
            try await plan.validate()
        }
        validateTask.cancel()
        await XCTAssertThrowsErrorAsync(try await validateTask.value)
    }

    func testRejectsIncompleteBundleScan() async throws {
        let fixture = try ApplicationFixture()
        try fixture.write("Example.app/Contents/MacOS/example", bytes: [1])
        try fixture.write("Example.app/Contents/.env.production", bytes: [2])

        await XCTAssertThrowsErrorAsync(try await fixture.prepare())
    }
}

private final class ApplicationFixture {
    let root: URL
    let applications: URL
    let app: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageDaddyApplicationRemoval-\(UUID().uuidString)")
        applications = root.appendingPathComponent("Applications")
        app = applications.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, bytes: [UInt8]) throws {
        let url = applications.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    func prepare() async throws -> ApplicationRemovalPlan {
        try await ApplicationRemovalPlan.prepare(url: app, allowedRoots: [applications], scanBackend: .foundation)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
