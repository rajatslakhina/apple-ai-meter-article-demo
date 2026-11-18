import Foundation

/// What the app can know about the platform's daily cloud limit: as far as Apple has
/// documented, almost nothing.
///
/// Apple documents no way for apps to read the remaining allowance. As far as is documented,
/// the only signal is a refused request once the limit is reached. This tracker remembers that refusal
/// until the limit is expected to reset, so the app stops sending doomed requests
/// and can tell the user roughly when the feature comes back.
///
/// Apple says limits reset "around midnight" in the user's time zone, with exceptions
/// (travel, Family Sharing, signed-out devices). `resetEstimate` is therefore an estimate.
/// After it passes, the next request tries the cloud again and a success clears the state.
/// There is no early retry: if the real reset comes before local midnight, the cloud stays
/// off until then. If the real reset comes later, a request in the gap is refused. A refusal
/// after an expired estimate, with no cloud success since, is treated as "the reset is late":
/// the cloud may be tried again after `lateResetBackoff` (an hour, capped at the next local
/// midnight) instead of writing off the whole new day. A limit genuinely spent before the
/// app's first request of the day looks the same, so it costs at most one refused request an hour.
///
/// `Codable` so the app can persist it; otherwise every relaunch spends one more refused request.
public struct PlatformLimitTracker: Sendable, Equatable, Codable {
    public private(set) var exhaustedUntil: Date?
    public let timeZone: TimeZone

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    public func isExhausted(at date: Date) -> Bool {
        guard let until = exhaustedUntil else { return false }
        return date < until
    }

    /// How long to wait after a refusal that arrives after an expired estimate, with no cloud success since.
    public static let lateResetBackoff: TimeInterval = 3_600

    /// Call when the platform refuses a request because the daily limit was reached.
    public mutating func recordLimitReached(at date: Date) {
        let nextMidnight = Self.resetEstimate(after: date, in: timeZone)
        if let previous = exhaustedUntil, date >= previous {
            // We expected a reset at `previous`, nothing has succeeded since, and the platform
            // still says no: treat the reset as late and look again in an hour.
            exhaustedUntil = min(date.addingTimeInterval(Self.lateResetBackoff), nextMidnight)
        } else {
            exhaustedUntil = nextMidnight
        }
    }

    /// Call when a cloud request succeeds: whatever we believed, the limit is not reached.
    public mutating func recordSuccess() {
        exhaustedUntil = nil
    }

    /// The next local midnight after `date`.
    public static func resetEstimate(after date: Date, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date.addingTimeInterval(86_400)
    }
}
