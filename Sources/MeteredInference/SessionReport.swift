import Foundation

/// The numbers a lead should watch for a metered AI feature.
/// Cost per completed task, not price per call, is the one that tells the truth.
public struct SessionReport: Sendable, Equatable {
    public let requests: Int
    public let completed: Int
    public let degraded: Int
    public let failed: Int
    public let unavailable: Int
    /// Cloud attempts the platform refused: latency the user sat through for nothing.
    public let refusedAttempts: Int
    public let paidCalls: Int
    public let spendCents: Int
    public let completedByTier: [InferenceTier: Int]

    /// Total spend divided by completed tasks. `nil` when nothing completed.
    public var costPerCompletedTaskCents: Double? {
        completed > 0 ? Double(spendCents) / Double(completed) : nil
    }

    public init(_ session: MeteredSession, featureID: String? = nil) {
        let results = session.results.filter { featureID == nil || $0.featureID == featureID }
        let attempts = session.attempts.filter { featureID == nil || $0.featureID == featureID }

        var completed = 0, degraded = 0, failed = 0, unavailable = 0
        var byTier: [InferenceTier: Int] = [:]
        for entry in results {
            switch entry.result {
            case .completed(let tier, let wasDegraded):
                completed += 1
                byTier[tier, default: 0] += 1
                if wasDegraded { degraded += 1 }
            case .failed: failed += 1
            case .unavailable: unavailable += 1
            }
        }
        self.requests = results.count
        self.completed = completed
        self.degraded = degraded
        self.failed = failed
        self.unavailable = unavailable
        self.refusedAttempts = attempts.filter { $0.tier == .privateCloud && $0.outcome == .platformLimitReached }.count
        self.paidCalls = attempts.filter { $0.tier == .paidAPI }.count
        self.spendCents = attempts.reduce(0) { $0 + $1.costCents }
        self.completedByTier = byTier
    }
}
