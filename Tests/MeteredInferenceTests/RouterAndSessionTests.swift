import XCTest
@testable import MeteredInference

final class RouterAndSessionTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC") ?? .current
    let noon = SampleDay.dayStart.addingTimeInterval(12 * 3_600)
    let cloudThenPaid = FeatureProfile(id: "f", title: "Feature", tiers: [.privateCloud, .paidAPI])

    func router(allowance: Int = 1, paid: Bool = true) -> InferenceRouter {
        InferenceRouter(platform: PlatformLimitTracker(timeZone: utc),
                        ledger: UsageLedger(monthlyAllowance: allowance, timeZone: utc),
                        paidAPIEnabled: paid)
    }

    // MARK: Router

    func testPlanTakesFirstAvailableTierAndExplainsSkips() {
        let feature = FeatureProfile(id: "f", title: "F", tiers: [.onDevice, .privateCloud])
        XCTAssertEqual(router().plan(feature, at: noon, onDeviceModelAvailable: true), .run(.onDevice, skipped: []))
        XCTAssertEqual(router().plan(feature, at: noon, onDeviceModelAvailable: false),
                       .run(.privateCloud, skipped: [Skip(.onDevice, .onDeviceModelUnavailable)]))
    }

    func testRefusedCloudIsSkippedUntilTheResetEstimate() {
        var r = router()
        r.platform.recordLimitReached(at: noon)
        let midnight = SampleDay.dayStart.addingTimeInterval(86_400)
        XCTAssertEqual(r.platform.exhaustedUntil, midnight)
        XCTAssertEqual(r.plan(cloudThenPaid, at: noon, onDeviceModelAvailable: true),
                       .run(.paidAPI, skipped: [Skip(.privateCloud, .platformLimitReached(resetsAround: midnight))]))
        XCTAssertEqual(r.plan(cloudThenPaid, at: midnight, onDeviceModelAvailable: true).tier, .privateCloud,
                       "at the reset estimate the cloud tier is tried again")
    }

    func testNoRouteReportsTheEarliestReset() {
        var r = router(allowance: 0)
        r.platform.recordLimitReached(at: noon)
        let decision = r.plan(cloudThenPaid, at: noon, onDeviceModelAvailable: true)
        XCTAssertEqual(decision, .unavailable(skipped: [
            Skip(.privateCloud, .platformLimitReached(resetsAround: SampleDay.dayStart.addingTimeInterval(86_400))),
            Skip(.paidAPI, .paidBudgetExhausted(shortfall: 1, allowanceResetsAt: nil)),
        ], retryAround: SampleDay.dayStart.addingTimeInterval(86_400)))
    }

    func testDisabledPaidTierAndEmptyProfileGiveNoRetryTime() {
        XCTAssertEqual(router(paid: false).plan(FeatureProfile(id: "p", title: "P", tiers: [.paidAPI]), at: noon, onDeviceModelAvailable: true),
                       .unavailable(skipped: [Skip(.paidAPI, .paidTierDisabled)], retryAround: nil))
        XCTAssertEqual(router().plan(FeatureProfile(id: "e", title: "E", tiers: []), at: noon, onDeviceModelAvailable: true),
                       .unavailable(skipped: [], retryAround: nil))
    }

    func testProfilesDropDuplicateTiersAndClampPaidUnits() {
        XCTAssertEqual(FeatureProfile(id: "d", title: "D", tiers: [.onDevice, .paidAPI, .onDevice]).tiers, [.onDevice, .paidAPI])
        XCTAssertEqual(FeatureProfile(id: "d", title: "D", tiers: [.paidAPI], paidUnits: 0).paidUnits, 1)
    }

    func testExhaustedPaidBudgetReportsWhenTheMonthlyAllowanceRefills() throws {
        var r = router(allowance: 1)
        _ = r.ledger.debit(1, at: noon)
        let paidOnly = FeatureProfile(id: "p", title: "P", tiers: [.paidAPI])
        let december = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: utc, year: 2026, month: 12, day: 1)))
        XCTAssertEqual(r.plan(paidOnly, at: noon, onDeviceModelAvailable: true),
                       .unavailable(skipped: [Skip(.paidAPI, .paidBudgetExhausted(shortfall: 1, allowanceResetsAt: december))],
                                    retryAround: december))
        // A feature that needs more units than the allowance ever grants gets no refill date.
        let big = FeatureProfile(id: "b", title: "B", tiers: [.paidAPI], paidUnits: 2)
        XCTAssertEqual(r.plan(big, at: noon, onDeviceModelAvailable: true).skipped.first?.reason.resetsAround, nil)
    }

    func testResetEstimateUsesTheTrackersTimeZoneAcrossDaylightSaving() throws {
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = la
        // 31 Oct 2026, 22:00 in Los Angeles (PDT). DST ends at 02:00 on 1 Nov.
        let lateEvening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 22)))
        let reset = PlatformLimitTracker.resetEstimate(after: lateEvening, in: la)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reset),
                       DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 0))
        XCTAssertEqual(reset.timeIntervalSince(lateEvening), 2 * 3_600)
        // The day after the change is 25 hours long; the estimate still lands on local midnight.
        let next = PlatformLimitTracker.resetEstimate(after: reset, in: la)
        XCTAssertEqual(next.timeIntervalSince(reset), 25 * 3_600)
        XCTAssertNotEqual(PlatformLimitTracker.resetEstimate(after: lateEvening, in: utc), reset)
    }

    func testALateResetCostsAnHourNotAWholeDay() {
        var tracker = PlatformLimitTracker(timeZone: utc)
        tracker.recordLimitReached(at: noon)
        let midnight = SampleDay.dayStart.addingTimeInterval(86_400)
        XCTAssertEqual(tracker.exhaustedUntil, midnight)

        // 00:00 exactly: the estimate has just passed, so the cloud is tried; a refusal here is a late reset too.
        var boundary = tracker
        XCTAssertFalse(boundary.isExhausted(at: midnight))
        boundary.recordLimitReached(at: midnight)
        XCTAssertEqual(boundary.exhaustedUntil, midnight.addingTimeInterval(3_600), "a refusal exactly at the estimate is a late reset")

        // 00:30: the estimate has passed, the cloud is tried, and the platform still refuses.
        let halfPast = midnight.addingTimeInterval(1_800)
        XCTAssertFalse(tracker.isExhausted(at: halfPast))
        tracker.recordLimitReached(at: halfPast)
        XCTAssertEqual(tracker.exhaustedUntil, halfPast.addingTimeInterval(3_600), "back off an hour, not until the next midnight")

        // 01:30: still refused, no cloud success since: another hour.
        let later = halfPast.addingTimeInterval(3_600)
        tracker.recordLimitReached(at: later)
        XCTAssertEqual(tracker.exhaustedUntil, later.addingTimeInterval(3_600))

        // 07:00: a reset seven hours late (say, a Family Sharing purchaser far to the west) still backs off an hour.
        let seven = midnight.addingTimeInterval(7 * 3_600)
        tracker.recordLimitReached(at: seven)
        XCTAssertEqual(tracker.exhaustedUntil, seven.addingTimeInterval(3_600))

        // 23:30 after a backoff expired at 23:00: the hour is capped at the next local midnight.
        let nextMidnight = midnight.addingTimeInterval(86_400)
        var capped = PlatformLimitTracker(timeZone: utc)
        capped.recordLimitReached(at: noon)                                   // until 00:00 on day 2
        capped.recordLimitReached(at: midnight.addingTimeInterval(22 * 3_600)) // 22:00 day 2 -> 23:00
        XCTAssertEqual(capped.exhaustedUntil, midnight.addingTimeInterval(23 * 3_600))
        capped.recordLimitReached(at: midnight.addingTimeInterval(23.5 * 3_600)) // 23:30 -> capped at 00:00 day 3
        XCTAssertEqual(capped.exhaustedUntil, nextMidnight)

        // After a cloud success, a refusal is a fresh day's limit: wait for the next midnight.
        var fresh = PlatformLimitTracker(timeZone: utc)
        fresh.recordLimitReached(at: noon)
        fresh.recordSuccess()
        let evening = midnight.addingTimeInterval(20 * 3_600)
        fresh.recordLimitReached(at: evening)
        XCTAssertEqual(fresh.exhaustedUntil, nextMidnight)
    }

    func testTrackerRoundTripsThroughCodable() throws {
        var tracker = PlatformLimitTracker(timeZone: utc)
        tracker.recordLimitReached(at: noon)
        let decoded = try JSONDecoder().decode(PlatformLimitTracker.self, from: JSONEncoder().encode(tracker))
        XCTAssertEqual(decoded, tracker)
        XCTAssertTrue(decoded.isExhausted(at: noon))
    }

    // MARK: Session

    func testRefusalReroutesWithinTheSameRequestAndIsCounted() {
        var session = MeteredSession(router: router(), paidCallCostCents: 4)
        let result = session.perform(cloudThenPaid, at: noon) { $0 == .privateCloud ? .platformLimitReached : .succeeded }

        XCTAssertEqual(result, .completed(.paidAPI, degraded: true))
        XCTAssertEqual(session.attempts.map(\.tier), [.privateCloud, .paidAPI])
        XCTAssertEqual(SessionReport(session).refusedAttempts, 1)
        XCTAssertEqual(session.router.ledger.balance(at: noon).allowanceRemaining, 0)
    }

    func testAfterARefusalLaterRequestsDoNotHitTheCloudAgainThatDay() {
        var session = MeteredSession(router: router(allowance: 5), paidCallCostCents: 4)
        var cloudCalls = 0
        for hour in 0..<3 {
            session.perform(cloudThenPaid, at: noon.addingTimeInterval(Double(hour) * 3_600)) { tier in
                if tier == .privateCloud { cloudCalls += 1; return .platformLimitReached }
                return .succeeded
            }
        }
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(SessionReport(session).paidCalls, 3)
    }

    func testPaidCallCostsMoneyEvenWhenItFailsButUsesNoUnits() {
        var session = MeteredSession(router: router(), paidCallCostCents: 4)
        let paidOnly = FeatureProfile(id: "p", title: "P", tiers: [.paidAPI])
        XCTAssertEqual(session.perform(paidOnly, at: noon) { _ in .failed }, .failed(.paidAPI))
        XCTAssertEqual(SessionReport(session).spendCents, 4)
        XCTAssertEqual(SessionReport(session).costPerCompletedTaskCents, nil)
        XCTAssertEqual(session.router.ledger.balance(at: noon).allowanceRemaining, 1)
    }

    func testLimitRefusalFromANonCloudTierIsAFailureNotAPlatformSignal() {
        var session = MeteredSession(router: router(), paidCallCostCents: 4)
        let onDevice = FeatureProfile(id: "o", title: "O", tiers: [.onDevice, .privateCloud])
        XCTAssertEqual(session.perform(onDevice, at: noon) { _ in .platformLimitReached }, .failed(.onDevice))
        XCTAssertNil(session.router.platform.exhaustedUntil)
        XCTAssertEqual(SessionReport(session).refusedAttempts, 0, "only cloud refusals count as refused cloud attempts")
    }

    func testAlwaysRefusingCloudStillEnds() {
        var session = MeteredSession(router: router(allowance: 0), paidCallCostCents: 4)
        let result = session.perform(cloudThenPaid, at: noon) { _ in .platformLimitReached }
        XCTAssertEqual(result, .unavailable(retryAround: SampleDay.dayStart.addingTimeInterval(86_400)))
        XCTAssertEqual(session.attempts.count, 1)
    }

    func testCloudSuccessClearsAStaleRefusal() {
        var session = MeteredSession(router: router(), paidCallCostCents: 4)
        session.perform(cloudThenPaid, at: noon) { $0 == .privateCloud ? .platformLimitReached : .succeeded }
        let tomorrow = noon.addingTimeInterval(86_400)
        XCTAssertEqual(session.perform(cloudThenPaid, at: tomorrow) { _ in .succeeded }, .completed(.privateCloud, degraded: false))
        XCTAssertNil(session.router.platform.exhaustedUntil)
    }

    func testAsyncPerformBehavesLikeTheSyncOne() async {
        var session = MeteredSession(router: router(), paidCallCostCents: 4)
        let result = await session.perform(cloudThenPaid, at: noon) { tier async -> AttemptOutcome in
            tier == .privateCloud ? .platformLimitReached : .succeeded
        }
        XCTAssertEqual(result, .completed(.paidAPI, degraded: true))
        XCTAssertEqual(session.attempts.map(\.tier), [.privateCloud, .paidAPI])
    }

    func testAFailedCloudAttemptDoesNotFallBack() {
        var session = MeteredSession(router: router(), paidCallCostCents: 4)
        XCTAssertEqual(session.perform(cloudThenPaid, at: noon) { _ in .failed }, .failed(.privateCloud))
        XCTAssertEqual(session.attempts.count, 1)
        XCTAssertNil(session.router.platform.exhaustedUntil)
    }

    // MARK: Copy

    func testCopyTellsTheTruth() {
        let feature = SampleDay.planDay
        XCTAssertNil(QuotaCopy.message(for: .completed(.privateCloud, degraded: false), feature: feature, now: noon, timeZone: utc))
        XCTAssertEqual(QuotaCopy.message(for: .unavailable(retryAround: SampleDay.dayStart.addingTimeInterval(86_400)),
                                         feature: feature, now: noon, timeZone: utc),
                       "Plan my day is paused until about 00:00. Everything else still works.")
        XCTAssertEqual(QuotaCopy.message(for: .unavailable(retryAround: SampleDay.dayStart.addingTimeInterval(13 * 86_400)),
                                         feature: feature, now: noon, timeZone: utc),
                       "Plan my day is paused until 1 Dec. Everything else still works.")
        XCTAssertEqual(QuotaCopy.message(for: .unavailable(retryAround: nil), feature: feature, now: noon, timeZone: utc),
                       "Plan my day isn't available right now.")
        XCTAssertEqual(QuotaCopy.message(for: .completed(.onDevice, degraded: true), feature: feature, now: noon, timeZone: utc),
                       "Done on this device. Results may be shorter than usual today.")
        XCTAssertEqual(QuotaCopy.message(for: .completed(.paidAPI, degraded: true), feature: feature, now: noon, timeZone: utc),
                       "Done with our cloud AI provider, using one paid run.")
        XCTAssertNil(QuotaCopy.message(for: .completed(.onDevice, degraded: false), feature: feature, now: noon, timeZone: utc))
        XCTAssertEqual(QuotaCopy.message(for: .failed(.paidAPI), feature: feature, now: noon, timeZone: utc),
                       "Plan my day didn't work this time. You can try again.")
        XCTAssertEqual(QuotaCopy.message(for: .completed(.paidAPI, degraded: true),
                                         feature: FeatureProfile(id: "x", title: "X", tiers: [.paidAPI], paidUnits: 3), now: noon, timeZone: utc),
                       "Done with our cloud AI provider, using 3 paid runs.")
        // Exactly 24 hours away still reads as a clock time; one second more becomes a date.
        let exactly = noon.addingTimeInterval(86_400)
        XCTAssertEqual(QuotaCopy.message(for: .unavailable(retryAround: exactly), feature: feature, now: noon, timeZone: utc),
                       "Plan my day is paused until about 12:00. Everything else still works.")
        XCTAssertEqual(QuotaCopy.message(for: .unavailable(retryAround: exactly.addingTimeInterval(1)), feature: feature, now: noon, timeZone: utc),
                       "Plan my day is paused until 19 Nov. Everything else still works.")
    }
}
