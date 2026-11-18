import Foundation

public enum SkipReason: Sendable, Equatable {
    case onDeviceModelUnavailable
    /// The platform refused a cloud request today; it should come back around this time.
    case platformLimitReached(resetsAround: Date)
    case paidTierDisabled
    /// Allowance plus packs fall short; the monthly allowance refills at `allowanceResetsAt`.
    case paidBudgetExhausted(shortfall: Int, allowanceResetsAt: Date?)

    /// When this tier is expected to be usable again, if it ever comes back on its own.
    public var resetsAround: Date? {
        switch self {
        case .platformLimitReached(let date): return date
        case .paidBudgetExhausted(_, let date): return date
        case .onDeviceModelUnavailable, .paidTierDisabled: return nil
        }
    }
}

public struct Skip: Sendable, Equatable {
    public let tier: InferenceTier
    public let reason: SkipReason

    public init(_ tier: InferenceTier, _ reason: SkipReason) {
        self.tier = tier
        self.reason = reason
    }
}

public enum RouteDecision: Sendable, Equatable {
    /// Run on `tier`. `skipped` lists the preferred tiers that were passed over, and why.
    case run(InferenceTier, skipped: [Skip])
    /// No tier can take the request. `retryAround` is the earliest expected reset, if any.
    case unavailable(skipped: [Skip], retryAround: Date?)

    public var tier: InferenceTier? {
        if case .run(let tier, _) = self { return tier }
        return nil
    }

    public var skipped: [Skip] {
        switch self {
        case .run(_, let skipped): return skipped
        case .unavailable(let skipped, _): return skipped
        }
    }
}

/// Picks the first tier in a feature's preference list that can take the request now.
///
/// `plan` is pure: it reads state and never changes it. The caller (see `MeteredSession`)
/// records what actually happened, because only an attempt reveals the platform limit.
public struct InferenceRouter: Sendable, Equatable {
    public var platform: PlatformLimitTracker
    public var ledger: UsageLedger
    public var paidAPIEnabled: Bool

    public init(platform: PlatformLimitTracker, ledger: UsageLedger, paidAPIEnabled: Bool = true) {
        self.platform = platform
        self.ledger = ledger
        self.paidAPIEnabled = paidAPIEnabled
    }

    public func plan(_ feature: FeatureProfile, at date: Date, onDeviceModelAvailable: Bool) -> RouteDecision {
        var skipped: [Skip] = []
        for tier in feature.tiers {
            if let reason = blocker(for: tier, feature: feature, at: date, onDeviceModelAvailable: onDeviceModelAvailable) {
                skipped.append(Skip(tier, reason))
            } else {
                return .run(tier, skipped: skipped)
            }
        }
        return .unavailable(skipped: skipped, retryAround: skipped.compactMap(\.reason.resetsAround).min())
    }

    private func blocker(for tier: InferenceTier, feature: FeatureProfile, at date: Date,
                         onDeviceModelAvailable: Bool) -> SkipReason? {
        switch tier {
        case .onDevice:
            return onDeviceModelAvailable ? nil : .onDeviceModelUnavailable
        case .privateCloud:
            guard platform.isExhausted(at: date), let until = platform.exhaustedUntil else { return nil }
            return .platformLimitReached(resetsAround: until)
        case .paidAPI:
            guard paidAPIEnabled else { return .paidTierDisabled }
            let balance = ledger.balance(at: date)
            guard balance.total < feature.paidUnits else { return nil }
            let refills = ledger.monthlyAllowance >= feature.paidUnits ? balance.allowanceResetsAt : nil
            return .paidBudgetExhausted(shortfall: feature.paidUnits - balance.total, allowanceResetsAt: refills)
        }
    }
}
