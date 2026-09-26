import ContextCore
import Foundation

enum UsageDisplayDate {
    static func timestamp(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let parsed: Date?
        if let date = fractional.date(from: raw) ?? plain.date(from: raw) {
            parsed = date
        } else if let number = Double(raw), number.isFinite {
            let seconds = number > 10_000_000_000 ? number / 1_000 : number
            parsed = (946_684_800...4_102_444_800).contains(seconds)
                ? Date(timeIntervalSince1970: seconds) : nil
        } else {
            parsed = nil
        }
        return parsed?.formatted(date: .abbreviated, time: .shortened) ?? "Date unavailable"
    }

    static func period(_ value: String, scale: UsageChartScale) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = scale == .month ? "yyyy-MM" : "yyyy-MM-dd"
        guard let date = parser.date(from: value) else { return "Date unavailable" }
        let output = DateFormatter()
        output.locale = .current
        output.timeZone = parser.timeZone
        output.dateFormat = scale == .month ? "MMM yyyy" : "d MMM yyyy"
        let label = output.string(from: date)
        return scale == .week ? "Week of \(label)" : label
    }
}
