import Foundation

public enum AllowanceAutoCheckPolicy {
    public static let minimumInterval: TimeInterval = 15 * 60

    public static func shouldCheck(enabled: Bool, lastAttempt: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastAttempt else { return true }
        // A future timestamp can result from a clock correction. It must not
        // suppress automatic checks indefinitely.
        let age = now.timeIntervalSince(lastAttempt)
        return age < 0 || age >= minimumInterval
    }
}
