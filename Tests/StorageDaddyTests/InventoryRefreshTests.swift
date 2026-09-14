import Foundation
import Testing
import DiskCore
@testable import StorageDaddy

private enum RefreshFailure: Error { case unavailable }

private final class RefreshSequence<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let first: Value
    let second: Value
    let blockFirst: Bool

    init(first: Value, second: Value, blockFirst: Bool = false) {
        self.first = first; self.second = second; self.blockFirst = blockFirst
    }

    func next() throws -> Value {
        lock.lock(); calls += 1; let call = calls; lock.unlock()
        if call == 1 {
            if blockFirst { started.signal(); resume.wait() }
            return first
        }
        if blockFirst { return second }
        throw RefreshFailure.unavailable
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.started.wait()
                continuation.resume()
            }
        }
    }
}

@Suite struct InventoryRefreshTests {
    private func context(_ suffix: String) throws -> AIContextDiscoveryReport {
        try AIContextDiscovery.discover(configuration: .init(
            home: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("absent-context-\(UUID())-\(suffix)"), projectRoots: []))
    }

    private func sessions(_ suffix: String) throws -> AISessionInventoryReport {
        try AISessionInventory.discover(configuration: .init(
            home: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("absent-sessions-\(UUID())-\(suffix)")))
    }

    @Test @MainActor func contextRetainsInventoryAndShowsRefreshFailure() async throws {
        let expected = try context("retained")
        let sequence = RefreshSequence(first: expected, second: expected)
        let model = AIContextModel(discover: { _ in try sequence.next() })
        await model.load()
        #expect(model.report == expected)
        await model.load()
        #expect(model.report == expected)
        #expect(model.errorMessage != nil)
        #expect(!model.loading)
    }

    @Test @MainActor func sessionsRetainInventoryAndShowRefreshFailure() async throws {
        let expected = try sessions("retained")
        let sequence = RefreshSequence(first: expected, second: expected)
        let model = AISessionsModel(discover: { try sequence.next() })
        await model.load()
        await model.load()
        #expect(model.report == expected)
        #expect(model.errorMessage != nil)
        #expect(!model.loading)
    }

    @Test @MainActor func supersededContextCannotOverwriteNewResult() async throws {
        let newer = try context("new")
        let sequence = RefreshSequence(first: try context("old"), second: newer, blockFirst: true)
        let model = AIContextModel(discover: { _ in try sequence.next() })
        let old = Task { await model.load() }
        await sequence.waitUntilStarted()
        #expect(model.loading)
        await model.load()
        sequence.resume.signal()
        await old.value
        #expect(model.report == newer)
        #expect(model.errorMessage == nil)
        #expect(!model.loading)
    }

    @Test @MainActor func supersededSessionsCannotOverwriteNewResult() async throws {
        let newer = try sessions("new")
        let sequence = RefreshSequence(first: try sessions("old"), second: newer, blockFirst: true)
        let model = AISessionsModel(discover: { try sequence.next() })
        let old = Task { await model.load() }
        await sequence.waitUntilStarted()
        await model.load()
        sequence.resume.signal()
        await old.value
        #expect(model.report == newer)
        #expect(model.errorMessage == nil)
        #expect(!model.loading)
    }
}
