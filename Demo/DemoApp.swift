import SwiftUI
import MeteredInference

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Launch arguments used for screenshots: `-tab day|compare|ledger`, `-plan cloudFirst|meterAware`, `-scroll end`.
struct RootView: View {
    @State private var tab: String = UserDefaults.standard.string(forKey: "tab") ?? "day"

    var body: some View {
        TabView(selection: $tab) {
            DayView(initialPlan: SampleDay.Plan(rawValue: UserDefaults.standard.string(forKey: "plan") ?? "") ?? .cloudFirst)
                .tabItem { Label("Day", systemImage: "clock") }
                .tag("day")
            CompareView()
                .tabItem { Label("Compare", systemImage: "chart.bar.xaxis") }
                .tag("compare")
            LedgerView()
                .tabItem { Label("Ledger", systemImage: "creditcard") }
                .tag("ledger")
        }
    }
}

extension InferenceTier {
    var color: Color {
        switch self {
        case .onDevice: return .green
        case .privateCloud: return .blue
        case .paidAPI: return .orange
        }
    }

    var symbol: String {
        switch self {
        case .onDevice: return "iphone"
        case .privateCloud: return "cloud.fill"
        case .paidAPI: return "dollarsign.circle.fill"
        }
    }
}

struct TierBadge: View {
    let tier: InferenceTier

    var body: some View {
        Label(tier.displayName, systemImage: tier.symbol)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tier.color.opacity(0.18), in: Capsule())
            .foregroundStyle(tier.color)
    }
}

let utcTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = SampleDay.timeZone
    formatter.dateFormat = "HH:mm"
    return formatter
}()

// MARK: - Day

struct DayView: View {
    @State var plan: SampleDay.Plan

    init(initialPlan: SampleDay.Plan) {
        _plan = State(initialValue: initialPlan)
    }

    var body: some View {
        let run = SampleDay.run(plan, hiddenLimit: SampleDay.defaultHiddenLimit)
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section {
                    Picker("Plan", selection: $plan) {
                        ForEach(SampleDay.Plan.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Same \(SampleDay.script.count) requests. The platform quietly allows \(SampleDay.defaultHiddenLimit) cloud requests today and never says so.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("18 Nov, UTC") {
                    ForEach(run.entries) { entry in
                        EntryRow(entry: entry)
                    }
                }
            }
            .onAppear {
                // `-scroll end` shows the evening, where the two plans differ most.
                if UserDefaults.standard.string(forKey: "scroll") == "end", let last = run.entries.last?.id {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            }
            .navigationTitle("A metered day")
        }
    }
}

struct EntryRow: View {
    let entry: SampleDay.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(utcTimeFormatter.string(from: entry.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(entry.feature.title).font(.subheadline.weight(.semibold))
                Spacer()
                if let tier = entry.result.completedTier {
                    TierBadge(tier: tier)
                } else {
                    Label("No route", systemImage: "nosign")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                }
            }
            if entry.hitRefusal {
                Text("Cloud refused: daily limit reached. Re-routed.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let copy = QuotaCopy.message(for: entry.result, feature: entry.feature, now: entry.time, timeZone: SampleDay.timeZone) {
                Text("“\(copy)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Compare

struct CompareView: View {
    var body: some View {
        let cloud = SampleDay.run(.cloudFirst, hiddenLimit: SampleDay.defaultHiddenLimit)
        let aware = SampleDay.run(.meterAware, hiddenLimit: SampleDay.defaultHiddenLimit)
        NavigationStack {
            List {
                Section {
                    let total = SampleDay.script.count
                    MetricRow(name: "Completed", cloud: "\(cloud.report.completed)/\(total)", aware: "\(aware.report.completed)/\(total)",
                              awareIsBetter: aware.report.completed > cloud.report.completed)
                    MetricRow(name: "No route left", cloud: "\(cloud.report.unavailable)", aware: "\(aware.report.unavailable)",
                              awareIsBetter: aware.report.unavailable < cloud.report.unavailable)
                    MetricRow(name: "Ran on a fallback", cloud: "\(cloud.report.degraded)", aware: "\(aware.report.degraded)",
                              awareIsBetter: aware.report.degraded < cloud.report.degraded)
                    MetricRow(name: "Refused cloud attempts", cloud: "\(cloud.report.refusedAttempts)", aware: "\(aware.report.refusedAttempts)",
                              awareIsBetter: aware.report.refusedAttempts < cloud.report.refusedAttempts)
                    MetricRow(name: "Paid calls", cloud: "\(cloud.report.paidCalls)", aware: "\(aware.report.paidCalls)",
                              awareIsBetter: aware.report.paidCalls < cloud.report.paidCalls)
                    MetricRow(name: "Spend per completed task", cloud: cents(cloud.report.costPerCompletedTaskCents),
                              aware: cents(aware.report.costPerCompletedTaskCents),
                              awareIsBetter: (aware.report.costPerCompletedTaskCents ?? .infinity) < (cloud.report.costPerCompletedTaskCents ?? .infinity))
                } header: {
                    HStack {
                        Text("Hidden limit \(SampleDay.defaultHiddenLimit)")
                        Spacer()
                        Text("Cloud first").frame(width: 76)
                        Text("Meter-aware").frame(width: 84)
                    }
                } footer: {
                    Text("Paid calls priced at \(SampleDay.paidCallCostCents)¢ (an assumption). Meter-aware sends summaries and rewrites to the on-device model, which assumes it is good enough for them: check that with your own evals.")
                }

                Section {
                    ForEach(0...6, id: \.self) { limit in
                        let c = SampleDay.run(.cloudFirst, hiddenLimit: limit).report(for: SampleDay.planDay)
                        let a = SampleDay.run(.meterAware, hiddenLimit: limit).report(for: SampleDay.planDay)
                        MetricRow(name: "Limit \(limit)", cloud: "\(c.unavailable) blocked", aware: "\(a.unavailable) blocked",
                                  awareIsBetter: a.unavailable < c.unavailable)
                    }
                } header: {
                    Text("“Plan my day” with no route, by hidden limit")
                } footer: {
                    Text("Apple doesn't publish the limit, so the plan has to hold up for every value. The tests check 0 to 16.")
                }
            }
            .navigationTitle("Compare plans")
        }
    }

    func cents(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.2f¢", value)
    }
}

struct MetricRow: View {
    let name: String
    let cloud: String
    let aware: String
    /// Highlight only a strict win; a tie stays plain.
    let awareIsBetter: Bool

    var body: some View {
        HStack {
            Text(name).font(.subheadline)
            Spacer()
            Text(cloud).font(.subheadline.monospacedDigit()).frame(width: 76)
            Text(aware)
                .font(.subheadline.monospacedDigit().weight(awareIsBetter ? .semibold : .regular))
                .foregroundStyle(awareIsBetter ? Color.green : Color.primary)
                .frame(width: 84)
        }
    }
}

// MARK: - Ledger

struct LedgerView: View {
    struct Snapshot {
        let before: LedgerBalance
        let after: LedgerBalance
        let debit: DebitResult
        let packs: [UsagePack]
        let now: Date
    }

    static func snapshot() -> Snapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = SampleDay.timeZone
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? SampleDay.dayStart
        }
        let now = SampleDay.dayStart.addingTimeInterval(12 * 3_600)
        var ledger = UsageLedger(monthlyAllowance: 3, timeZone: SampleDay.timeZone)
        _ = try? ledger.purchasePack(id: "Pack from Nov 2025", units: 10, at: day(2025, 11, 10))
        _ = try? ledger.purchasePack(id: "Pack from Sep 2026", units: 10, at: day(2026, 9, 1))
        _ = try? ledger.purchasePack(id: "Pack from Feb 2026", units: 10, at: day(2026, 2, 10))
        let before = ledger.balance(at: now)
        let debit = ledger.debit(5, at: now)
        return Snapshot(before: before, after: ledger.balance(at: now), debit: debit, packs: ledger.packs, now: now)
    }

    var body: some View {
        let snap = Self.snapshot()
        NavigationStack {
            List {
                Section("Debit 5 units on 18 Nov") {
                    switch snap.debit {
                    case .approved(let fromAllowance, let draws):
                        LabeledContent("From this month's allowance", value: "\(fromAllowance)")
                        ForEach(draws, id: \.packID) { draw in
                            LabeledContent("From \(draw.packID)", value: "\(draw.units)")
                        }
                    case .denied(let reason):
                        Text("Denied: \(String(describing: reason))")
                    }
                    LabeledContent("Balance before → after", value: "\(snap.before.total) → \(snap.after.total)")
                }
                Section {
                    ForEach(snap.packs) { pack in
                        PackRow(pack: pack, now: snap.now)
                    }
                } header: {
                    Text("Packs")
                } footer: {
                    Text("Allowance first, then the pack that expires soonest. The Nov 2025 pack expired on 10 Nov 2026 and is never spent.")
                }
            }
            .navigationTitle("Paid-tier ledger")
        }
    }
}

struct PackRow: View {
    let pack: UsagePack
    let now: Date

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = SampleDay.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(pack.id).font(.subheadline.weight(.semibold))
                Text("Expires \(Self.dayFormatter.string(from: pack.expiresAt))")
                    .font(.caption)
                    .foregroundStyle(pack.isUsable(at: now) ? Color.secondary : Color.red)
            }
            Spacer()
            Text(pack.isUsable(at: now) ? "\(pack.remaining)/\(pack.units)" : "expired")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(pack.isUsable(at: now) ? Color.primary : Color.red)
        }
    }
}
