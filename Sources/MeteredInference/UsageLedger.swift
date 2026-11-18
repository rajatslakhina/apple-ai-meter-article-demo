import Foundation

/// A one-time purchase of extra usage, modelled on Apple's intelligence usage packs:
/// it rolls over from month to month and expires 12 months after purchase.
public struct UsagePack: Sendable, Hashable, Identifiable {
    public let id: String
    public let purchasedAt: Date
    public let expiresAt: Date
    public let units: Int
    public internal(set) var remaining: Int

    /// A pack can be spent strictly before its expiry instant.
    public func isUsable(at date: Date) -> Bool {
        remaining > 0 && date < expiresAt
    }
}

public enum LedgerError: Error, Equatable {
    case invalidUnits
    case duplicatePackID
}

/// Units drawn from one pack by a debit.
public struct PackDraw: Sendable, Hashable {
    public let packID: String
    public let units: Int
}

public enum DebitResult: Sendable, Equatable {
    /// The full amount was taken: first from this month's allowance, then from packs.
    case approved(fromAllowance: Int, fromPacks: [PackDraw])
    /// Nothing was taken.
    case denied(DebitDenial)
}

public enum DebitDenial: Sendable, Equatable {
    case invalidAmount
    /// The allowance and every usable pack together fall short by this many units.
    case insufficient(shortfall: Int)
}

public struct LedgerBalance: Sendable, Equatable {
    public let allowanceRemaining: Int
    public let packUnitsRemaining: Int
    /// The earliest expiry among packs that still have usable units.
    public let nextPackExpiry: Date?
    /// When this month's allowance refills.
    public let allowanceResetsAt: Date

    public var total: Int { allowanceRemaining + packUnitsRemaining }
}

/// The paid tier's meter: a monthly allowance that does not roll over,
/// plus purchased packs that do, until they expire.
///
/// From Apple's published pack terms, applied to your own paid tier:
/// - The monthly allowance doesn't roll over; packs roll over and expire 12 months after purchase.
/// - Packs are spent only after the month's allowance is used up.
///
/// Design choices of this package:
/// - Among packs, the one that expires first is spent first, so the user loses as little as possible.
/// - Expired packs are never spent.
/// - A debit is all-or-nothing.
public struct UsageLedger: Sendable, Equatable {
    public let monthlyAllowance: Int
    public private(set) var packs: [UsagePack] = []
    private var usedByMonth: [String: Int] = [:]
    private let calendar: Calendar

    public init(monthlyAllowance: Int, timeZone: TimeZone) {
        self.monthlyAllowance = max(0, monthlyAllowance)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    @discardableResult
    public mutating func purchasePack(id: String, units: Int, at date: Date) throws -> UsagePack {
        guard units > 0 else { throw LedgerError.invalidUnits }
        guard !packs.contains(where: { $0.id == id }) else { throw LedgerError.duplicatePackID }
        let expiry = calendar.date(byAdding: .month, value: 12, to: date) ?? date.addingTimeInterval(365 * 86_400)
        let pack = UsagePack(id: id, purchasedAt: date, expiresAt: expiry, units: units, remaining: units)
        packs.append(pack)
        return pack
    }

    public func balance(at date: Date) -> LedgerBalance {
        let usable = packs.filter { $0.isUsable(at: date) }
        return LedgerBalance(
            allowanceRemaining: max(0, monthlyAllowance - usedByMonth[monthKey(date), default: 0]),
            packUnitsRemaining: usable.reduce(0) { $0 + $1.remaining },
            nextPackExpiry: usable.map(\.expiresAt).min(),
            allowanceResetsAt: startOfNextMonth(after: date)
        )
    }

    public mutating func debit(_ units: Int, at date: Date) -> DebitResult {
        guard units > 0 else { return .denied(.invalidAmount) }
        let current = balance(at: date)
        guard current.total >= units else {
            return .denied(.insufficient(shortfall: units - current.total))
        }

        let fromAllowance = min(units, current.allowanceRemaining)
        usedByMonth[monthKey(date), default: 0] += fromAllowance
        var needed = units - fromAllowance

        var draws: [PackDraw] = []
        let order = packs.indices
            .filter { packs[$0].isUsable(at: date) }
            .sorted { packs[$0].expiresAt < packs[$1].expiresAt }
        for index in order where needed > 0 {
            let take = min(needed, packs[index].remaining)
            packs[index].remaining -= take
            needed -= take
            draws.append(PackDraw(packID: packs[index].id, units: take))
        }
        return .approved(fromAllowance: fromAllowance, fromPacks: draws)
    }

    private func monthKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)"
    }

    private func startOfNextMonth(after date: Date) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: parts) ?? date
        return calendar.date(byAdding: .month, value: 1, to: start) ?? date.addingTimeInterval(31 * 86_400)
    }
}
