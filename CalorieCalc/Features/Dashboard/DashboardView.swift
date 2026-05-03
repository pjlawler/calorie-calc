import SwiftUI
import SwiftData
import Charts

/// "My Plan" + "Progress" merged into a single scrolling view. Plan cards (current weight, plan
/// summary) sit on top; Progress section (timeframe picker, weight chart, summary tiles) below.
/// The "Log" CTA that used to live in the weight card header now sits next to the "Progress"
/// section title to keep both screens collapsed into one.
struct DashboardView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(HealthKitService.self) private var healthKitService

    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \GoalPeriod.startDate) private var goalPeriods: [GoalPeriod]
    @Query(sort: [SortDescriptor(\WeightEntry.timestamp, order: .reverse)]) private var weightEntries: [WeightEntry]
    @Query(sort: \DayLog.date) private var dayLogs: [DayLog]

    @State private var showWeightSheet = false
    @State private var showSettings = false
    /// HealthKit workout active-energy bucketed by start-of-day for the current chart range.
    /// Refreshed via `.task(id:)` whenever the timeframe or custom range changes — one HK query
    /// covers the whole span.
    @State private var hkBurnsByDay: [Date: Double] = [:]

    @AppStorage("progress.timeframe") private var timeframe: ProgressTrendTimeframe = .days90
    @AppStorage("progress.customStart") private var customStartTS: Double = (Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: .now)) ?? .now).timeIntervalSinceReferenceDate
    @AppStorage("progress.customEnd") private var customEndTS: Double = Calendar.current.startOfDay(for: .now).timeIntervalSinceReferenceDate
    @AppStorage("dashboard.planCardExpanded") private var planCardExpanded: Bool = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Progress")
                            .font(.largeTitle.weight(.bold))
                        Spacer()
                        Button {
                            showWeightSheet = true
                        } label: {
                            Label("Log", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if let profile = profiles.first {
                        progressSection(profile: profile)
                        Text("Plan Overview")
                            .font(.title2.weight(.bold))
                        planCard(profile: profile)
                    } else {
                        ProgressView().padding(.top, 80)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showWeightSheet) {
                WeightLogView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .task { await ensureProfile() }
            .task(id: healthKitFetchKey) { await loadHealthKitBurns() }
        }
    }

    /// Single key combining everything that affects the chart's date range. `.task(id:)` re-runs
    /// `loadHealthKitBurns` whenever this changes, so switching timeframe or editing a custom
    /// range triggers a fresh HK fetch.
    private var healthKitFetchKey: String {
        "\(timeframe.rawValue)|\(customStartTS)|\(customEndTS)"
    }

    private func loadHealthKitBurns() async {
        let (start, end) = range
        do {
            let burns = try await healthKitService.dailyWorkoutBurn(from: start, through: end)
            hkBurnsByDay = burns
        } catch {
            // HK access denied or query failed — fall back to manual-only burns. Don't surface
            // the error to the user here; the Settings page handles HK auth status.
            hkBurnsByDay = [:]
        }
    }

    // MARK: - Plan card

    private func planCard(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header row: hero number + chevron toggle. Tapping the whole row flips
            // `planCardExpanded`, which is persisted via @AppStorage.
            Button {
                withAnimation(.snappy) { planCardExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(profile.dailyNetCalorieGoal.formatted())
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    Text("net kcal / day")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(planCardExpanded ? 0 : -90))
                        .accessibilityLabel(planCardExpanded ? "Collapse plan details" : "Expand plan details")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Weekly target \(profile.dailyNetCalorieGoal * 7) kcal")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if planCardExpanded {
                VStack(spacing: 6) {
                    planRow(label: "Plan-day gross", value: "\(profile.dailyGrossCalorieGoal) kcal")
                    planRow(label: "Workout goal", value: "\(profile.dailyWorkoutCalorieGoal) kcal/day")
                    planRow(label: "Week split", value: profile.bankSplit.displayName)
                }

                Divider().overlay(Color.accentColor.opacity(0.2))

                planExplainer(profile: profile)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private func planExplainer(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("How it works")
                    .font(.subheadline.weight(.semibold))
            }
            Text(explainerBody(profile: profile))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func explainerBody(profile: UserProfile) -> String {
        """
        To reach your goal weight, we're targeting an average of \(profile.dailyNetCalorieGoal) net calories per day — the weekly total is your true budget, not a strict daily ceiling. Early in the week, hit your bank-day goal of \(profile.dailyGrossCalorieGoal) kcal eaten and \(profile.dailyWorkoutCalorieGoal) kcal burned. Every day you eat under target builds up calories you can spend later in the week, so a dinner out, a drink, or a treat on your bonus days won't derail your progress.
        """
    }

    private func planRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    // MARK: - Progress section

    private func progressSection(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            timeframePicker
            if timeframe == .custom {
                customRangeEditor
            }
            weightChartCard(profile: profile)

            // Current weight subsection sits between the chart and the averages, so the
            // user's "where am I right now" tiles read first, before the period averages.
            Text("Current weight")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            summaryCard(profile: profile)

            averagesCard(profile: profile)
        }
    }

    /// Period-level insights: average daily net calories and average weekly weight change
    /// across the same range as the chart. Helps the user see whether their banking math is
    /// actually moving the scale at the rate they expect.
    private func averagesCard(profile: UserProfile) -> some View {
        let summary = periodAverages
        return HStack(spacing: 12) {
            averageTile(
                title: "Avg net / day",
                value: summary.avgDailyNet.map { $0.formatted(.number) } ?? "—",
                unit: "kcal"
            )
            averageTile(
                title: "Avg weekly change",
                value: summary.avgWeeklyChange.map { weightChangeString($0) } ?? "—",
                unit: profile.weightUnit.suffix,
                valueColor: summary.avgWeeklyChange.map { weightChangeColor($0) } ?? .primary
            )
        }
    }

    private func averageTile(title: String, value: String, unit: String, valueColor: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private func weightChangeString(_ value: Double) -> String {
        // Always include a sign so a flat 0 shows as "0.0" without sign noise.
        if abs(value) < 0.05 { return "0.0" }
        let sign = value > 0 ? "+" : "−"
        return sign + String(format: "%.1f", abs(value))
    }

    /// `true` when the user is trying to *lose* weight. A negative change in that case is good
    /// (green); a positive change is bad (red). Inverted for users gaining toward a higher goal.
    /// Defaults to loss-is-good when no goal is set, since that's the common case.
    private var weightLossDirection: Bool {
        guard let profile = profiles.first, let goal = profile.goalWeight else { return true }
        // Reference weight to compare the goal against — prefer the latest reading, then the
        // starting weight, then the goal itself (zero-delta fallback).
        let reference = weightEntries.first?.weight(in: profile.weightUnit)
            ?? profile.startingWeight
            ?? goal
        return goal < reference
    }

    /// Color a weight-change figure by whether it's moving in the user's intended direction.
    /// Flat (≈0) stays secondary so a zero doesn't look like a bad outcome.
    private func weightChangeColor(_ value: Double) -> Color {
        if abs(value) < 0.05 { return .secondary }
        let isLoss = value < 0
        return isLoss == weightLossDirection ? .green : .red
    }

    private struct PeriodAverages {
        let avgDailyNet: Int?
        let avgWeeklyChange: Double?
    }

    /// Best-fit line through the weigh-ins in the visible range. Smooths out daily noise so the
    /// "true" trend isn't whipped around by a single high or low reading.
    private struct WeightTrend {
        /// Slope (weight units per day). Positive = gaining, negative = losing.
        let slopePerDay: Double
        /// Predicted weight at the line's leftmost point in the range.
        let lineStart: Double
        /// Predicted weight at the line's rightmost point in the range — the user's current
        /// "trend weight," i.e. what the regression says you weigh today after filtering out
        /// daily water-retention noise. This is the number to show as `current avg`.
        let lineEnd: Double

        /// Net change implied by the line from start to end. Use this instead of (lastRaw −
        /// firstRaw) when you want a reading that ignores noise from a single weigh-in.
        var fitChange: Double { lineEnd - lineStart }
    }

    /// Linear-regression fit of weight vs. days-since-first-point. Needs at least two distinct
    /// timestamps to produce a slope; returns `nil` for empty/single-point ranges or any case
    /// where every measurement landed on the same day (denominator → 0).
    private var weightTrend: WeightTrend? {
        let points = weightPoints
        guard points.count >= 2 else { return nil }
        let calendar = Calendar.current
        let firstDate = points.first!.date

        // x = days since first weigh-in (Double for fractional smoothing if a future timestamp
        // ever carries hours/minutes precision). y = weight in user's preferred unit.
        let xs: [Double] = points.map {
            Double(calendar.dateComponents([.day], from: firstDate, to: $0.date).day ?? 0)
        }
        let ys: [Double] = points.map(\.weight)

        let n = Double(points.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + ($1.0 * $1.1) }
        let sumX2 = xs.reduce(0) { $0 + ($1 * $1) }

        let denom = n * sumX2 - sumX * sumX
        guard denom != 0 else { return nil }

        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n

        let xStart = xs.min() ?? 0
        let xEnd = xs.max() ?? 0
        return WeightTrend(
            slopePerDay: slope,
            lineStart: slope * xStart + intercept,
            lineEnd: slope * xEnd + intercept
        )
    }

    /// Average daily net calories across the chart's date range, plus a weight trend smoothed
    /// via linear regression. Going through the regression line instead of just first-vs-last
    /// keeps the weekly-change number stable when the user logs a noisy weigh-in (post-meal,
    /// dehydrated, etc.) — slope across all points is what matters.
    ///
    /// Net is computed via `HistoryAggregator` so this card stays consistent with the History
    /// tab — same per-day-totals, same "tracked days" rule (count only days where food was
    /// logged). Both views always show the same number for the same date range.
    private var periodAverages: PeriodAverages {
        let (start, end) = range

        let totals = HistoryAggregator.dailyTotals(
            dayLogs: dayLogs,
            workoutBurnByDay: hkBurnsByDay
        )
        let summary = HistoryAggregator.summary(
            metric: .net,
            start: start,
            end: end,
            dailyTotals: totals
        )
        let avgDailyNet: Int? = summary.dayAvg == 0 ? nil : Int(summary.dayAvg.rounded())

        // Avg weekly change: slope of the regression line × 7. Linear regression is the
        // mean-of-changes the user described — a best-fit line through every weigh-in, robust
        // to a single bad data point.
        let avgWeeklyChange: Double? = weightTrend.map { $0.slopePerDay * 7 }

        return PeriodAverages(avgDailyNet: avgDailyNet, avgWeeklyChange: avgWeeklyChange)
    }

    private var preferredUnit: WeightUnit {
        profiles.first?.weightUnit ?? .pounds
    }

    private var customStart: Date { Date(timeIntervalSinceReferenceDate: customStartTS) }
    private var customEnd: Date { Date(timeIntervalSinceReferenceDate: customEndTS) }
    private var customStartBinding: Binding<Date> {
        Binding(get: { customStart }, set: { customStartTS = $0.timeIntervalSinceReferenceDate })
    }
    private var customEndBinding: Binding<Date> {
        Binding(get: { customEnd }, set: { customEndTS = $0.timeIntervalSinceReferenceDate })
    }

    private var range: (start: Date, end: Date) {
        let calendar = Calendar.current
        if timeframe == .custom {
            let s = calendar.startOfDay(for: customStart)
            let e = calendar.startOfDay(for: customEnd)
            return s <= e ? (s, e) : (e, s)
        }
        let end = calendar.startOfDay(for: .now)
        let days = timeframe.daysBack ?? 30
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        return (start, end)
    }

    private var rangeDayCount: Int {
        max(1, (Calendar.current.dateComponents([.day], from: range.start, to: range.end).day ?? 0) + 1)
    }

    /// Chart X-domain end. `range.end` is start-of-day, so a weigh-in logged later that day
    /// would sit past the chart's right edge. Extend by one day to cover the full end-date.
    private var chartDomainEnd: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: range.end) ?? range.end
    }

    private struct WeightPoint: Identifiable, Hashable {
        let id: String
        let date: Date
        let weight: Double
    }

    private var weightPoints: [WeightPoint] {
        let calendar = Calendar.current
        let (start, end) = range
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: end) ?? end
        return weightEntries
            .filter { $0.timestamp >= start && $0.timestamp < rangeEnd }
            .sorted { $0.timestamp < $1.timestamp }
            .map {
                WeightPoint(
                    id: $0.id.uuidString,
                    date: $0.timestamp,
                    weight: $0.weight(in: preferredUnit)
                )
            }
    }

    private var timeframePicker: some View {
        HStack {
            Picker("Timeframe", selection: $timeframe) {
                ForEach(ProgressTrendTimeframe.allCases) { tf in
                    Text(tf.displayName).tag(tf)
                }
            }
            .pickerStyle(.menu)
            Spacer()
            Text(rangeText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var rangeText: String {
        let (start, end) = range
        let s = start.formatted(.dateTime.month(.abbreviated).day().year())
        let e = end.formatted(.dateTime.month(.abbreviated).day().year())
        if Calendar.current.isDate(start, inSameDayAs: end) { return s }
        return "\(s) – \(e)"
    }

    private var customRangeEditor: some View {
        HStack(spacing: 12) {
            DatePicker("Start", selection: customStartBinding, in: ...customEnd, displayedComponents: .date)
                .labelsHidden()
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            DatePicker("End", selection: customEndBinding, in: customStart...Date(), displayedComponents: .date)
                .labelsHidden()
            Spacer()
        }
    }

    private func weightChartCard(profile: UserProfile) -> some View {
        let points = weightPoints
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weight (\(preferredUnit.suffix))").font(.headline)
                Spacer()
            }
            if points.isEmpty {
                Text("No weight entries in this range. Tap Log above to add one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Weight", point.weight)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.accentColor)
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Weight", point.weight)
                        )
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(height: 240)
                .chartXScale(domain: range.start...chartDomainEnd)
                .chartXAxis { weightXAxis }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(String(format: "%.1f", v)).font(.caption2.monospacedDigit())
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    @AxisContentBuilder
    private var weightXAxis: some AxisContent {
        let days = rangeDayCount
        if days <= 14 {
            AxisMarks(values: .stride(by: .day, count: max(1, days / 4))) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        } else if days <= 60 {
            AxisMarks(values: .stride(by: .day, count: max(1, days / 6))) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        } else if days <= 200 {
            AxisMarks(values: .stride(by: .month, count: 1)) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        } else {
            AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
    }

    @ViewBuilder
    private func summaryCard(profile: UserProfile) -> some View {
        let points = weightPoints
        if let first = points.first, let last = points.last {
            let unit = preferredUnit.suffix
            // LATEST ENTRY: most-recent weigh-in (raw), date in the title row, raw delta inline.
            // NORMALIZED FOR PERIOD: end of the regression line (smoothed "true" weight),
            // line-end − line-start as the inline change.
            let rawChange = last.weight - first.weight
            let trend = weightTrend
            HStack(spacing: 12) {
                weightTile(
                    title: "Latest entry",
                    dateLabel: shortDate(last.date),
                    value: String(format: "%.1f", last.weight),
                    unit: unit,
                    change: first.id == last.id ? nil : rawChange
                )
                if let trend {
                    weightTile(
                        title: "Normalized for period",
                        dateLabel: nil,
                        value: String(format: "%.1f", trend.lineEnd),
                        unit: unit,
                        change: trend.fitChange
                    )
                }
            }
        }
    }

    /// Short numeric date used in tile headers, e.g. "5/1/26" in en-US locales.
    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day().year(.twoDigits))
    }

    private func weightTile(title: String, dateLabel: String?, value: String, unit: String, change: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let dateLabel {
                    Text(dateLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
                if let change {
                    Spacer(minLength: 6)
                    Text("\(weightChangeString(change)) \(unit)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(weightChangeColor(change))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    // MARK: - Bootstrapping

    private func ensureProfile() async {
        if profiles.isEmpty {
            modelContext.insert(UserProfile())
            try? modelContext.save()
        }
        if let profile = profiles.first {
            GoalPeriod.ensureBootstrapped(in: modelContext, profile: profile, existing: goalPeriods)
        }
    }
}
