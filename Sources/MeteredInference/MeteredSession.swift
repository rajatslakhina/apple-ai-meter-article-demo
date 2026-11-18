import Foundation

/// What one attempt on one tier returned.
public enum AttemptOutcome: Sendable, Equatable {
    case succeeded
    /// The platform refused the request because the user's daily limit was reached.
    /// Only meaningful for `.privateCloud`; from any other tier it is treated as `.failed`.
    case platformLimitReached
    /// The model ran but the task failed (error, refusal, unusable output).
    case failed
}

public struct Attempt: Sendable, Equatable {
    public let featureID: String
    public let tier: InferenceTier
    public let outcome: AttemptOutcome
    /// What this attempt cost you. Paid calls cost money whether or not the task succeeds.
    public let costCents: Int
}

/// How one user request ended.
public enum TaskResult: Sendable, Equatable {
    /// Completed on `tier`. `degraded` is true when a preferred tier was skipped or refused.
    case completed(InferenceTier, degraded: Bool)
    case failed(InferenceTier)
    /// No route left. `retryAround` is the honest "when" to show the user, if there is one.
    case unavailable(retryAround: Date?)

    public var completedTier: InferenceTier? {
        if case .completed(let tier, _) = self { return tier }
        return nil
    }
}

/// Runs requests through the router and keeps the records that matter:
/// every attempt (including the ones the platform refused) and every task result.
///
/// State lives in memory. A real app should persist `router.platform` (it is `Codable`)
/// so a relaunch doesn't spend another refused round trip, and should keep the paid
/// ledger on its server. This is a value type and is not safe to share across concurrent
/// requests. The async `perform` is `mutating`, so call it on a session your code owns locally
/// and run requests one at a time; Swift won't let you call it on an actor's or a `@MainActor`
/// model's stored property across an `await`. For parallel requests, wrap the session in your
/// own actor and serialise requests through it.
public struct MeteredSession: Sendable {
    public private(set) var router: InferenceRouter
    public let paidCallCostCents: Int
    public private(set) var attempts: [Attempt] = []
    public private(set) var results: [(featureID: String, result: TaskResult)] = []

    public init(router: InferenceRouter, paidCallCostCents: Int) {
        self.router = router
        self.paidCallCostCents = max(0, paidCallCostCents)
    }

    /// Plans, runs, and re-plans after a platform refusal, until the task completes,
    /// fails, or no tier is left.
    ///
    /// - Only a platform refusal moves the request down the ladder. A `.failed` attempt ends
    ///   the request as `.failed`, so the caller decides whether a retry is worth it.
    /// - Paid units are taken from the ledger only when a paid call succeeds,
    ///   but the call's cost to you is recorded either way.
    @discardableResult
    public mutating func perform(
        _ feature: FeatureProfile,
        at date: Date,
        onDeviceModelAvailable: Bool = true,
        execute: (InferenceTier) -> AttemptOutcome
    ) -> TaskResult {
        var state = RequestState()
        while true {
            switch nextStep(feature, at: date, onDeviceModelAvailable: onDeviceModelAvailable, state: &state) {
            case .finished(let result):
                return result
            case .attempt(let tier, let decision):
                let outcome = execute(tier)
                if let result = record(outcome, on: tier, feature: feature, decision: decision, at: date, state: &state) {
                    return result
                }
            }
        }
    }

    /// The same as `perform(_:at:onDeviceModelAvailable:execute:)`, for real model calls that are `async`.
    @discardableResult
    public mutating func perform(
        _ feature: FeatureProfile,
        at date: Date,
        onDeviceModelAvailable: Bool = true,
        execute: (InferenceTier) async -> AttemptOutcome
    ) async -> TaskResult {
        var state = RequestState()
        while true {
            switch nextStep(feature, at: date, onDeviceModelAvailable: onDeviceModelAvailable, state: &state) {
            case .finished(let result):
                return result
            case .attempt(let tier, let decision):
                let outcome = await execute(tier)
                if let result = record(outcome, on: tier, feature: feature, decision: decision, at: date, state: &state) {
                    return result
                }
            }
        }
    }

    // MARK: - Shared steps

    private struct RequestState {
        var refused = false
        /// Each tier is tried at most once per request, so the loop always ends.
        var tried = Set<InferenceTier>()
    }

    private enum Step {
        case attempt(InferenceTier, RouteDecision)
        case finished(TaskResult)
    }

    private mutating func nextStep(_ feature: FeatureProfile, at date: Date, onDeviceModelAvailable: Bool,
                                   state: inout RequestState) -> Step {
        let decision = router.plan(feature, at: date, onDeviceModelAvailable: onDeviceModelAvailable)
        guard let tier = decision.tier, !state.tried.contains(tier) else {
            if case .unavailable(_, let retry) = decision {
                return .finished(finish(feature, .unavailable(retryAround: retry)))
            }
            return .finished(finish(feature, .unavailable(retryAround: nil)))
        }
        state.tried.insert(tier)
        return .attempt(tier, decision)
    }

    /// Records the attempt. Returns the task result, or `nil` to re-plan.
    private mutating func record(_ outcome: AttemptOutcome, on tier: InferenceTier, feature: FeatureProfile,
                                 decision: RouteDecision, at date: Date, state: inout RequestState) -> TaskResult? {
        let cost = tier == .paidAPI ? paidCallCostCents : 0
        attempts.append(Attempt(featureID: feature.id, tier: tier, outcome: outcome, costCents: cost))

        switch outcome {
        case .succeeded:
            if tier == .privateCloud { router.platform.recordSuccess() }
            if tier == .paidAPI, case .denied(let reason) = router.ledger.debit(feature.paidUnits, at: date) {
                // `plan` checked the balance moments ago on this same value, so this can't happen.
                // If it ever does, it is a bug to fix, not a free run to hand out quietly.
                assertionFailure("paid run succeeded but the debit was denied: \(reason)")
            }
            let degraded = state.refused || !decision.skipped.isEmpty
            return finish(feature, .completed(tier, degraded: degraded))
        case .platformLimitReached where tier == .privateCloud:
            router.platform.recordLimitReached(at: date)
            state.refused = true
            return nil
        case .platformLimitReached, .failed:
            return finish(feature, .failed(tier))
        }
    }

    private mutating func finish(_ feature: FeatureProfile, _ result: TaskResult) -> TaskResult {
        results.append((feature.id, result))
        return result
    }
}
