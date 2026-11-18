import XCTest
@testable import MeteredInference

final class UsageLedgerTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC") ?? .current

    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    func testAllowanceIsSpentBeforeAnyPack() throws {
        var ledger = UsageLedger(monthlyAllowance: 2, timeZone: utc)
        try ledger.purchasePack(id: "p", units: 5, at: date(2026, 11, 1))

        XCTAssertEqual(ledger.debit(3, at: date(2026, 11, 18)),
                       .approved(fromAllowance: 2, fromPacks: [PackDraw(packID: "p", units: 1)]))
        XCTAssertEqual(ledger.balance(at: date(2026, 11, 18)).allowanceRemaining, 0)
        XCTAssertEqual(ledger.balance(at: date(2026, 11, 18)).packUnitsRemaining, 4)
    }

    func testEarliestExpiringPackIsSpentFirstRegardlessOfPurchaseOrder() throws {
        var ledger = UsageLedger(monthlyAllowance: 0, timeZone: utc)
        try ledger.purchasePack(id: "newer", units: 3, at: date(2026, 9, 1))
        try ledger.purchasePack(id: "older", units: 3, at: date(2026, 2, 1))

        XCTAssertEqual(ledger.debit(4, at: date(2026, 11, 18)),
                       .approved(fromAllowance: 0, fromPacks: [PackDraw(packID: "older", units: 3),
                                                               PackDraw(packID: "newer", units: 1)]))
    }

    func testPackExpiresTwelveMonthsAfterPurchaseAndIsUnusableAtThatInstant() throws {
        var ledger = UsageLedger(monthlyAllowance: 0, timeZone: utc)
        let pack = try ledger.purchasePack(id: "p", units: 2, at: date(2025, 11, 18))
        XCTAssertEqual(pack.expiresAt, date(2026, 11, 18))

        XCTAssertEqual(ledger.balance(at: pack.expiresAt.addingTimeInterval(-1)).packUnitsRemaining, 2)
        XCTAssertEqual(ledger.balance(at: pack.expiresAt).packUnitsRemaining, 0)
        XCTAssertEqual(ledger.debit(1, at: pack.expiresAt), .denied(.insufficient(shortfall: 1)))
        XCTAssertEqual(ledger.packs.first?.remaining, 2, "an expired pack is never drawn down")
    }

    func testDenialIsAllOrNothing() throws {
        var ledger = UsageLedger(monthlyAllowance: 1, timeZone: utc)
        try ledger.purchasePack(id: "p", units: 1, at: date(2026, 11, 1))
        let before = ledger

        XCTAssertEqual(ledger.debit(3, at: date(2026, 11, 18)), .denied(.insufficient(shortfall: 1)))
        XCTAssertEqual(ledger, before)
    }

    func testAllowanceDoesNotRollOverButPacksDo() throws {
        var ledger = UsageLedger(monthlyAllowance: 2, timeZone: utc)
        try ledger.purchasePack(id: "p", units: 2, at: date(2026, 11, 1))
        XCTAssertEqual(ledger.debit(1, at: date(2026, 11, 30)), .approved(fromAllowance: 1, fromPacks: []))

        let december = ledger.balance(at: date(2026, 12, 1, hour: 0))
        XCTAssertEqual(december.allowanceRemaining, 2, "a new month refills to the allowance, not allowance + leftover")
        XCTAssertEqual(december.packUnitsRemaining, 2, "pack units carry over")
        XCTAssertEqual(ledger.balance(at: date(2026, 11, 30)).allowanceResetsAt, date(2026, 12, 1, hour: 0))
    }

    func testInvalidInputsAreRejected() throws {
        var ledger = UsageLedger(monthlyAllowance: 1, timeZone: utc)
        XCTAssertEqual(ledger.debit(0, at: date(2026, 11, 18)), .denied(.invalidAmount))
        XCTAssertEqual(ledger.debit(-2, at: date(2026, 11, 18)), .denied(.invalidAmount))
        XCTAssertThrowsError(try ledger.purchasePack(id: "p", units: 0, at: date(2026, 11, 1))) {
            XCTAssertEqual($0 as? LedgerError, .invalidUnits)
        }
        try ledger.purchasePack(id: "p", units: 1, at: date(2026, 11, 1))
        XCTAssertThrowsError(try ledger.purchasePack(id: "p", units: 1, at: date(2026, 11, 2))) {
            XCTAssertEqual($0 as? LedgerError, .duplicatePackID)
        }
        XCTAssertEqual(UsageLedger(monthlyAllowance: -5, timeZone: utc).monthlyAllowance, 0)
    }

    func testNextPackExpiryIgnoresEmptyAndExpiredPacks() throws {
        var ledger = UsageLedger(monthlyAllowance: 0, timeZone: utc)
        try ledger.purchasePack(id: "expired", units: 1, at: date(2025, 10, 1))
        try ledger.purchasePack(id: "spent", units: 1, at: date(2026, 1, 1))
        try ledger.purchasePack(id: "live", units: 1, at: date(2026, 6, 1))
        _ = ledger.debit(1, at: date(2026, 11, 18))  // spends "spent", the earliest usable

        XCTAssertEqual(ledger.balance(at: date(2026, 11, 18)).nextPackExpiry, date(2027, 6, 1))
    }
}
