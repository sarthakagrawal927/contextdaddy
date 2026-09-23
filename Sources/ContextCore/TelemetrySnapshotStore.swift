import Foundation

public actor TelemetrySnapshotStore {
    public static let retention: TimeInterval = 14 * 24 * 60 * 60
    public static let maximumSnapshots = 336

    private let fileURL: URL
    private let now: @Sendable () -> Date

    public init(directory: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContextDaddy", isDirectory: true)
        self.fileURL = base.appendingPathComponent("telemetry-snapshots.json")
        self.now = now
    }

    public func load() -> [ObservabilitySnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshots = try? JSONDecoder().decode([ObservabilitySnapshot].self, from: data) else { return [] }
        return retained(snapshots)
    }

    @discardableResult
    public func append(_ snapshot: ObservabilitySnapshot) throws -> [ObservabilitySnapshot] {
        var snapshots = load()
        if let latest = snapshots.last, snapshot.generatedAt.timeIntervalSince(latest.generatedAt) < 300 {
            snapshots[snapshots.count - 1] = snapshot
        } else {
            snapshots.append(snapshot)
        }
        snapshots = retained(snapshots)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshots).write(to: fileURL, options: .atomic)
        return snapshots
    }

    private func retained(_ snapshots: [ObservabilitySnapshot]) -> [ObservabilitySnapshot] {
        let cutoff = now().addingTimeInterval(-Self.retention)
        return Array(snapshots.filter { $0.generatedAt >= cutoff }.sorted { $0.generatedAt < $1.generatedAt }.suffix(Self.maximumSnapshots))
    }
}
