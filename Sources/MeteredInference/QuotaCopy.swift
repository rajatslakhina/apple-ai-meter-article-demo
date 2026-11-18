import Foundation

/// User-facing copy that tells the truth about a metered result.
/// No spinner that never ends, no "something went wrong" when the real answer is "limit reached".
public enum QuotaCopy {
    /// `nil` when the request ran where it was meant to and there is nothing to say.
    public static func message(for result: TaskResult, feature: FeatureProfile, now: Date, timeZone: TimeZone) -> String? {
        switch result {
        case .completed(let tier, let degraded):
            guard degraded else { return nil }
            switch tier {
            case .onDevice:
                return "Done on this device. Results may be shorter than usual today."
            case .privateCloud:
                return nil
            case .paidAPI:
                let runs = feature.paidUnits == 1 ? "one paid run" : "\(feature.paidUnits) paid runs"
                return "Done with our cloud AI provider, using \(runs)."
            }
        case .failed:
            return "\(feature.title) didn't work this time. You can try again."
        case .unavailable(let retry):
            guard let retry else {
                return "\(feature.title) isn't available right now."
            }
            let when = retry.timeIntervalSince(now) <= 86_400
                ? "about \(clockTime(retry, timeZone: timeZone))"
                : dayAndMonth(retry, timeZone: timeZone)
            return "\(feature.title) is paused until \(when). Everything else still works."
        }
    }

    static func dayAndMonth(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.day, .month], from: date)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let index = (parts.month ?? 1) - 1
        let month = months.indices.contains(index) ? months[index] : "?"
        return "\(parts.day ?? 1) \(month)"
    }

    static func clockTime(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return twoDigits(parts.hour ?? 0) + ":" + twoDigits(parts.minute ?? 0)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
