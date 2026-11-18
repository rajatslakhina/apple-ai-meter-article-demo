import XCTest
@testable import MeteredInference

/// Pins the modelled day the article quotes, at hidden limit 3. These tests don't read
/// `SampleDay.defaultHiddenLimit`, so you can change the demo's default and keep them green.
/// If any of these numbers change, the article, README, diagram and screenshots must change with them.
final class SampleDayTests: XCTestCase {
    func testCloudFirstAtHiddenLimitThree() {
        let run = SampleDay.run(.cloudFirst, hiddenLimit: 3)
        let report = run.report
        XCTAssertEqual(report.requests, 14)
        XCTAssertEqual(report.completed, 13)
        XCTAssertEqual(report.degraded, 8)
        XCTAssertEqual(report.unavailable, 1)
        XCTAssertEqual(report.refusedAttempts, 1)
        XCTAssertEqual(report.paidCalls, 2)
        XCTAssertEqual(report.spendCents, 8)
        XCTAssertEqual(report.completedByTier, [.privateCloud: 3, .onDevice: 8, .paidAPI: 2])

        let planDay = run.report(for: SampleDay.planDay)
        XCTAssertEqual(planDay.completedByTier, [.privateCloud: 1, .paidAPI: 2])
        XCTAssertEqual(planDay.unavailable, 1)
        // The 20:00 request has no route left and is told when to come back.
        XCTAssertEqual(run.entries[12].result, .unavailable(retryAround: SampleDay.dayStart.addingTimeInterval(86_400)))
        // The cloud budget went on a summary, a rewrite and one plan before lunch.
        XCTAssertEqual(run.entries.prefix(3).map(\.result.completedTier), [.privateCloud, .privateCloud, .privateCloud])
        XCTAssertTrue(run.entries[3].hitRefusal)
    }

    func testMeterAwareAtHiddenLimitThree() {
        let run = SampleDay.run(.meterAware, hiddenLimit: 3)
        let report = run.report
        XCTAssertEqual(report.requests, 14)
        XCTAssertEqual(report.completed, 14)
        XCTAssertEqual(report.degraded, 1)
        XCTAssertEqual(report.unavailable, 0)
        XCTAssertEqual(report.refusedAttempts, 1)
        XCTAssertEqual(report.paidCalls, 1)
        XCTAssertEqual(report.spendCents, 4)
        XCTAssertEqual(report.completedByTier, [.privateCloud: 3, .onDevice: 10, .paidAPI: 1])

        let planDay = run.report(for: SampleDay.planDay)
        XCTAssertEqual(planDay.completedByTier, [.privateCloud: 3, .paidAPI: 1])
        XCTAssertTrue(run.entries[12].hitRefusal)
        XCTAssertEqual(run.entries[12].result, .completed(.paidAPI, degraded: true))
    }

    /// The limit is hidden, so the ordering must not depend on guessing it.
    func testMeterAwareIsNeverWorseForPlanMyDayAtAnyHiddenLimit() {
        for limit in 0...16 {
            let cloud = SampleDay.run(.cloudFirst, hiddenLimit: limit)
            let aware = SampleDay.run(.meterAware, hiddenLimit: limit)
            XCTAssertLessThanOrEqual(aware.report(for: SampleDay.planDay).unavailable,
                                     cloud.report(for: SampleDay.planDay).unavailable, "limit \(limit)")
            XCTAssertLessThanOrEqual(aware.report.paidCalls, cloud.report.paidCalls, "limit \(limit)")
            XCTAssertLessThanOrEqual(aware.report.refusedAttempts, 1, "limit \(limit)")
        }
    }

    func testCloudFirstOnlyReordersFeaturesThatAllowTheCloud() {
        XCTAssertEqual(SampleDay.profile(SampleDay.summarize, for: .cloudFirst).tiers, [.privateCloud, .onDevice])
        XCTAssertEqual(SampleDay.profile(SampleDay.planDay, for: .cloudFirst).tiers, [.privateCloud, .paidAPI])
        XCTAssertEqual(SampleDay.profile(SampleDay.receipt, for: .cloudFirst).tiers, [.onDevice])
    }
}
