import Foundation

/// A modelled day used by the tests and the demo app.
///
/// Everything here is an assumption chosen to be easy to follow, not a measurement:
/// Apple does not publish the daily limit, so the "hidden limit" is a parameter.
public enum SampleDay {
    /// Two ways to order the same four features' tiers.
    public enum Plan: String, CaseIterable, Sendable, Identifiable {
        /// Use the best free model everywhere: cloud first, on-device as the fallback.
        case cloudFirst
        /// Spend the user's cloud allowance only where the on-device model can't do the job.
        case meterAware

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .cloudFirst: return "Cloud first"
            case .meterAware: return "Meter-aware"
            }
        }
    }

    public static let timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current

    // Features. `tiers` here is the meter-aware order; `features(for:)` derives the other.
    public static let summarize = FeatureProfile(id: "summarize", title: "Summarize note", tiers: [.onDevice, .privateCloud])
    public static let rewrite = FeatureProfile(id: "rewrite", title: "Rewrite in my tone", tiers: [.onDevice, .privateCloud])
    public static let planDay = FeatureProfile(id: "plan-day", title: "Plan my day", tiers: [.privateCloud, .paidAPI])
    public static let receipt = FeatureProfile(id: "receipt", title: "Read a receipt", tiers: [.onDevice])

    public static func profile(_ base: FeatureProfile, for plan: Plan) -> FeatureProfile {
        switch plan {
        case .meterAware:
            return base
        case .cloudFirst:
            // Cloud first wherever a cloud tier is allowed; everything else keeps its order.
            let cloud = base.tiers.filter { $0 == .privateCloud }
            return base.reordered(cloud + base.tiers.filter { $0 != .privateCloud })
        }
    }

    /// Fourteen requests, one an hour from 08:00 to 21:00 UTC on 18 Nov 2026.
    public static let script: [FeatureProfile] = [
        summarize, rewrite, planDay, summarize, receipt, rewrite, planDay,
        summarize, rewrite, planDay, summarize, receipt, planDay, rewrite,
    ]

    public static let dayStart: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 18)) ?? Date(timeIntervalSince1970: 1_794_960_000)
    }()

    public static func requestTime(_ index: Int) -> Date {
        dayStart.addingTimeInterval(Double(8 + index) * 3_600)
    }

    /// The paid tier's ledger for this user: 1 included run this month plus a 1-run pack.
    public static func ledger() -> UsageLedger {
        var ledger = UsageLedger(monthlyAllowance: 1, timeZone: timeZone)
        _ = try? ledger.purchasePack(id: "pack-oct", units: 1, at: dayStart.addingTimeInterval(-30 * 86_400))
        return ledger
    }

    public static let paidCallCostCents = 4

    public struct Entry: Sendable, Identifiable {
        public let id: Int
        public let time: Date
        public let feature: FeatureProfile
        public let result: TaskResult
        /// The platform refused a cloud attempt during this request before it was re-routed.
        public let hitRefusal: Bool
    }

    public struct Run: Sendable {
        public let plan: Plan
        public let hiddenLimit: Int
        public let entries: [Entry]
        public let session: MeteredSession

        public var report: SessionReport { SessionReport(session) }
        public func report(for feature: FeatureProfile) -> SessionReport { SessionReport(session, featureID: feature.id) }
    }

    /// Runs the script. The platform accepts `hiddenLimit` cloud requests, then refuses;
    /// the app is never told the number. All other attempts succeed.
    public static func run(_ plan: Plan, hiddenLimit: Int) -> Run {
        var session = MeteredSession(
            router: InferenceRouter(platform: PlatformLimitTracker(timeZone: timeZone), ledger: ledger()),
            paidCallCostCents: paidCallCostCents
        )
        var cloudUsed = 0
        var entries: [Entry] = []
        for (index, base) in script.enumerated() {
            let before = session.attempts.count
            let result = session.perform(profile(base, for: plan), at: requestTime(index)) { tier in
                guard tier == .privateCloud else { return .succeeded }
                guard cloudUsed < hiddenLimit else { return .platformLimitReached }
                cloudUsed += 1
                return .succeeded
            }
            let refused = session.attempts.dropFirst(before).contains { $0.tier == .privateCloud && $0.outcome == .platformLimitReached }
            entries.append(Entry(id: index, time: requestTime(index), feature: base, result: result, hitRefusal: refused))
        }
        return Run(plan: plan, hiddenLimit: hiddenLimit, entries: entries, session: session)
    }

    /// The hidden limit assumed in the article and the demo's default screens.
    public static let defaultHiddenLimit = 3
}
