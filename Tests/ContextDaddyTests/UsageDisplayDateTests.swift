import ContextCore
import Testing
@testable import ContextDaddy

struct UsageDisplayDateTests {
    @Test func formatsProviderTimestampsAndChartPeriodsWithoutShowingRawValues() {
        let iso = "2026-09-25T09:30:00Z"
        #expect(UsageDisplayDate.timestamp(iso) != iso)
        #expect(UsageDisplayDate.timestamp("1790328600") != "1790328600")
        #expect(UsageDisplayDate.timestamp("not-a-date") == "Date unavailable")
        #expect(UsageDisplayDate.period("2026-09-25", scale: .day) != "2026-09-25")
        #expect(UsageDisplayDate.period("2026-09", scale: .month) != "2026-09")
    }
}
