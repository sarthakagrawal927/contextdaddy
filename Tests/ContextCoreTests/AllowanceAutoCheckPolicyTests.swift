import Foundation
import Testing
@testable import ContextCore

struct AllowanceAutoCheckPolicyTests {
    @Test func requiresOptInAndThrottlesChecks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!AllowanceAutoCheckPolicy.shouldCheck(enabled: false, lastAttempt: nil, now: now))
        #expect(AllowanceAutoCheckPolicy.shouldCheck(enabled: true, lastAttempt: nil, now: now))
        #expect(!AllowanceAutoCheckPolicy.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(-60), now: now))
        #expect(AllowanceAutoCheckPolicy.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(-900), now: now))
        #expect(AllowanceAutoCheckPolicy.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(60), now: now))
    }
}
