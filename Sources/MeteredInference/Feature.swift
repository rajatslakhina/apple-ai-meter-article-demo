import Foundation

/// Where an AI request can run, and who pays for it.
public enum InferenceTier: String, CaseIterable, Sendable, Codable, Hashable {
    /// The on-device model. No meter: it costs the user battery, not quota.
    case onDevice
    /// A platform cloud model (for example Apple Foundation Models in Private Cloud Compute).
    /// It spends the *user's* daily allowance, which Apple documents no way for the app to read.
    case privateCloud
    /// Your own server calling a paid model API. It spends *your* money,
    /// metered against the user's allowance and packs in `UsageLedger`.
    case paidAPI

    public var displayName: String {
        switch self {
        case .onDevice: return "On-device"
        case .privateCloud: return "Private Cloud"
        case .paidAPI: return "Paid API"
        }
    }

    /// Who pays when a request runs on this tier.
    public var payer: String {
        switch self {
        case .onDevice: return "nobody (battery)"
        case .privateCloud: return "the user's daily limit"
        case .paidAPI: return "you"
        }
    }
}

/// One AI feature and the tiers it may run on, in the order you want to try them.
///
/// The order is the product decision. Putting `.onDevice` first for a feature
/// the on-device model handles well keeps the user's cloud allowance for the
/// features that cannot run anywhere else.
public struct FeatureProfile: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// Tiers in preference order. Duplicates are dropped, keeping the first occurrence.
    public let tiers: [InferenceTier]
    /// Units one paid run takes from `UsageLedger`. Values below 1 are raised to 1.
    public let paidUnits: Int

    public init(id: String, title: String, tiers: [InferenceTier], paidUnits: Int = 1) {
        self.id = id
        self.title = title
        var seen = Set<InferenceTier>()
        self.tiers = tiers.filter { seen.insert($0).inserted }
        self.paidUnits = max(1, paidUnits)
    }

    /// Returns a copy that tries the tiers in a different order.
    public func reordered(_ tiers: [InferenceTier]) -> FeatureProfile {
        FeatureProfile(id: id, title: title, tiers: tiers, paidUnits: paidUnits)
    }
}
