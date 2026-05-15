import SwiftUI
import SwiftData
import Charts

/// Progress tab: timeframe picker, weight chart, current weight tiles, period averages, then
/// per-metric history rows (calories / macros / exercise / steps), supplements (if tracked),
/// and an Analyze CTA. Driven by a single `progress.timeframe` selection.
struct DashboardView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(HealthKitService.self) private var healthKitService

    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \GoalPeriod.startDate) private var goalPeriods: [GoalPeriod]
    @Query(sort: [SortDescriptor(\WeightEntry.timestamp, order: .reverse)]) private var weightEntries: [WeightEntry]
    @Query(sort: \DayLog.date) private var dayLogs: [DayLog]
    @Query(sort: \SupplementEntry.timestamp) private var supplementEntries: [SupplementEntry]

    @State private var showWeightSheet = false
    @State private var showSettings = false
    @State private var showAnalysis = false
    /// HealthKit workout active-energy bucketed by start-of-day for the current chart range.
    /// Refreshed via `.task(id:)` whenever the timeframe or custom range changes — one HK query
    /// covers the whole span.
    @State private var hkBurnsByDay: [Date: Double] = [:]
    @State private var hkStepsByDay: [Date: Double] = [:]

    @AppStorage("progress.timeframe") private var timeframe: ProgressTrendTimeframe = .days90
    @AppStorage("progress.customStart") private var customStartTS: Double = (Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: .now)) ?? .now).timeIntervalSinceReferenceDate
    @AppStorage("progress.customEnd") private var customEndTS: Double = Calendar.current.startOfDay(for: .now).timeIntervalSinceReferenceDate
    @AppStorage("settings.showSteps") private var showSteps: Bool = true

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Color.clear.frame(height: 0).id("top")
                    if let profile = profiles.first {
                        progressSection(profile: profile)
                    } else {
                        ProgressView().padding(.top, 80)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Progress")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showWeightSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Log weight")
                }
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
            .sheet(isPresented: $showAnalysis) {
                NutritionAnalysisSheet(data: analysisInput)
            }
            .task { await ensureProfile() }
            .task(id: healthKitFetchKey) { await loadHealthKit() }
            }
        }
    }

    /// Single key combining everything that affects the chart's date range. `.task(id:)` re-runs
    /// `loadHealthKit` whenever this changes, so switching timeframe or editing a custom
    /// range triggers a fresh HK fetch.
    private var healthKitFetchKey: String {
        "\(timeframe.rawValue)|\(customStartTS)|\(customEndTS)"
    }

    private func loadHealthKit() async {
        let (start, end) = range
        async let burnsTask = healthKitService.dailyWorkoutBurn(from: start, through: end)
        async let stepsTask = healthKitService.dailyStepsByDay(from: start, through: end)
        hkBurnsByDay = (try? await burnsTask) ?? [:]
        hkStepsByDay = (try? await stepsTask) ?? [:]
    }

    // MARK: - Progress section

    private func progressSection(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            timeframePicker
            if timeframe == .custom {
                customRangeEditor
            } else {
                Toggle("Include today", isOn: includesTodayBinding)
                    .font(.subheadline)
                    .tint(.accentColor)
            }
            weightChartCard(profile: profile)

            Text("Current weight")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            currentWeightCard(profile: profile)

            Divider()
                .padding(.vertical, 4)

            ForEach(visibleMetrics) { metric in
                metricSection(metric)
                if metric == .protein {
                    Divider().padding(.vertical, 4)
                }
            }
            if tracksSupplements && !supplementSummaries.isEmpty {
                supplementsSection
            }
            analyzeButton
                .padding(.top, 8)
        }
    }

    // MARK: - History rows

    private var tracksSupplements: Bool { profiles.first?.tracksSupplements ?? false }

    private var visibleMetrics: [HistoryMetric] {
        let ordered: [HistoryMetric] = [.net, .calories, .carbs, .fat, .protein, .exercise, .steps]
        return ordered.filter { showSteps || $0 != .steps }
    }

    private var dailyTotals: [Date: HistoryAggregator.DailyTotals] {
        HistoryAggregator.dailyTotals(
            dayLogs: dayLogs,
            workoutBurnByDay: hkBurnsByDay,
            stepsByDay: hkStepsByDay
        )
    }

    private var supplementSummaries: [SupplementHistorySummary] {
        HistoryAggregator.supplementSummaries(
            entries: supplementEntries,
            start: range.start,
            end: range.end
        )
    }

    @ViewBuilder
    private func metricSection(_ metric: HistoryMetric) -> some View {
        let summary = HistoryAggregator.summary(
            metric: metric,
            start: range.start,
            end: range.end,
            dailyTotals: dailyTotals
        )
        let cards = cardsFor(metric: metric, summary: summary)
        VStack(alignment: .leading, spacing: 8) {
            Text(metric == .steps ? metric.displayName : "\(metric.displayName) (\(metric.unit))")
                .font(.subheadline.weight(.semibold))
            if cards.count > 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(cards) { card in
                            metricTile(card, metric: metric).frame(width: 140)
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    ForEach(cards) { card in
                        metricTile(card, metric: metric).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func cardsFor(metric: HistoryMetric, summary: HistorySummary) -> [MetricSummaryCard] {
        let unit = metric.unit
        switch timeframe {
        case .days7, .days14, .custom:
            return [
                MetricSummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                MetricSummaryCard(id: "total", title: totalTitleForShortRange, value: summary.total, unit: unit)
            ]
        case .days30, .days60:
            return [
                MetricSummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                MetricSummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                MetricSummaryCard(id: "range-total", title: totalTitleForShortRange, value: summary.total, unit: unit)
            ]
        case .days90:
            return [
                MetricSummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                MetricSummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                MetricSummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                MetricSummaryCard(id: "range-total", title: "90-Day Total", value: summary.total, unit: unit)
            ]
        case .days180:
            return [
                MetricSummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                MetricSummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                MetricSummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                MetricSummaryCard(id: "range-total", title: "180-Day Total", value: summary.total, unit: unit)
            ]
        case .year:
            return [
                MetricSummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                MetricSummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                MetricSummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                MetricSummaryCard(id: "year-total", title: "Year Total", value: summary.total, unit: unit)
            ]
        }
    }

    private var totalTitleForShortRange: String {
        switch timeframe {
        case .days7: "7-Day Total"
        case .days14: "14-Day Total"
        case .days30: "30-Day Total"
        case .days60: "60-Day Total"
        case .custom: "Total"
        default: "Total"
        }
    }

    private func metricTile(_ card: MetricSummaryCard, metric: HistoryMetric) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(formattedMetric(card.value, metric: metric))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(metric.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private func formattedMetric(_ value: Double, metric: HistoryMetric) -> String {
        switch metric {
        case .protein, .carbs, .fat:
            return CalorieFormatter.macro(value)
        case .steps:
            return Int(value.rounded()).formatted(.number)
        default:
            return CalorieFormatter.whole(value)
        }
    }

    // MARK: - Supplements

    private var supplementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Supplements")
                .font(.headline)
            ForEach(supplementSummaries) { summary in
                supplementRow(summary)
            }
        }
    }

    @ViewBuilder
    private func supplementRow(_ summary: SupplementHistorySummary) -> some View {
        let cards = supplementCards(for: summary)
        VStack(alignment: .leading, spacing: 8) {
            Text("\(summary.name) (\(summary.unit))")
                .font(.subheadline.weight(.semibold))
            if cards.count > 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(cards) { card in
                            supplementTile(card).frame(width: 140)
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    ForEach(cards) { card in
                        supplementTile(card).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func supplementCards(for summary: SupplementHistorySummary) -> [MetricSummaryCard] {
        let unit = summary.unit
        switch timeframe {
        case .days7, .days14, .custom:
            return [
                MetricSummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                MetricSummaryCard(id: "total", title: totalTitleForShortRange, value: summary.total, unit: unit),
            ]
        case .days30, .days60:
            return [
                MetricSummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                MetricSummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                MetricSummaryCard(id: "range-total", title: totalTitleForShortRange, value: summary.total, unit: unit),
            ]
        case .days90:
            return [
                MetricSummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                MetricSummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                MetricSummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                MetricSummaryCard(id: "range-total", title: "90-Day Total", value: summary.total, unit: unit),
            ]
        case .days180:
            return [
                MetricSummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                MetricSummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                MetricSummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                MetricSummaryCard(id: "range-total", title: "180-Day Total", value: summary.total, unit: unit),
            ]
        case .year:
            return [
                MetricSummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                MetricSummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                MetricSummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                MetricSummaryCard(id: "year-total", title: "Year Total", value: summary.total, unit: unit),
            ]
        }
    }

    private func supplementTile(_ card: MetricSummaryCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(formatSupplementValue(card.value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.purple)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private func formatSupplementValue(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return Int(value).formatted(.number)
        }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    // MARK: - Analyze

    private var analyzeButton: some View {
        Button {
            showAnalysis = true
        } label: {
            Label("Analyze", systemImage: "sparkles")
                .labelStyle(TitleAndIconLabelStyle())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }

    private var analysisInput: PeriodNutritionData {
        let totals = dailyTotals
        let calories = HistoryAggregator.summary(metric: .calories, start: range.start, end: range.end, dailyTotals: totals)
        let protein = HistoryAggregator.summary(metric: .protein, start: range.start, end: range.end, dailyTotals: totals)
        let carbs = HistoryAggregator.summary(metric: .carbs, start: range.start, end: range.end, dailyTotals: totals)
        let fat = HistoryAggregator.summary(metric: .fat, start: range.start, end: range.end, dailyTotals: totals)
        let exercise = HistoryAggregator.summary(metric: .exercise, start: range.start, end: range.end, dailyTotals: totals)
        let net = HistoryAggregator.summary(metric: .net, start: range.start, end: range.end, dailyTotals: totals)
        let dayCount = max(1, (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: range.start), to: Calendar.current.startOfDay(for: range.end)).day ?? 0) + 1)

        let calendar = Calendar.current
        let rangeStartDay = calendar.startOfDay(for: range.start)
        let rangeEndDay = calendar.startOfDay(for: range.end)
        let exerciseDayCount = totals
            .filter { $0.key >= rangeStartDay && $0.key <= rangeEndDay && $0.value.exercise > 0 }
            .count

        // Pull a wider window of weight entries than the analysis range itself so the AI
        // can comment on trend even when the user is looking at a short period. 60 days back
        // gives ~8 weeks of context.
        let displayUnit = profiles.first?.weightUnit ?? .pounds
        let weightWindowStart = calendar.date(byAdding: .day, value: -60, to: rangeStartDay) ?? rangeStartDay
        let weightSamples = weightEntries
            .filter { $0.timestamp >= weightWindowStart && $0.timestamp <= range.end }
            .sorted { $0.timestamp < $1.timestamp }
            .map { WeightSample(date: $0.timestamp, weight: $0.weight(in: displayUnit)) }
        let currentGoalPeriod = GoalPeriod.current(in: goalPeriods)

        return PeriodNutritionData(
            periodLabel: "\(timeframe.displayName) — \(rangeText)",
            dayCount: dayCount,
            totalCalories: calories.total,
            avgCalories: calories.dayAvg,
            totalProtein: protein.total,
            avgProtein: protein.dayAvg,
            totalCarbs: carbs.total,
            avgCarbs: carbs.dayAvg,
            totalFat: fat.total,
            avgFat: fat.dayAvg,
            totalExercise: exercise.total,
            avgExercise: exercise.dayAvg,
            totalNetCalories: net.total,
            avgNetCalories: net.dayAvg,
            dailyCalorieGoal: currentGoalPeriod?.dailyGrossCalorieGoal,
            dailyNetCalorieGoal: currentGoalPeriod?.dailyNetCalorieGoal,
            dailyExerciseGoal: currentGoalPeriod?.dailyWorkoutCalorieGoal,
            weightSamples: weightSamples,
            weightUnitSuffix: displayUnit.suffix,
            goalWeight: profiles.first?.goalWeight,
            exerciseDayCount: exerciseDayCount
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

    /// Best-fit line through the weigh-ins in the visible range. Uses Theil–Sen (median of
    /// pairwise slopes) rather than OLS so a single noisy weigh-in — water retention, missed
    /// scale reset, post-meal weigh — doesn't drag the line around. Endpoints are projected
    /// to the chart's window edges, not the first/last weigh-in, so a 7-day window's
    /// `fitChange` equals `slopePerDay × 7` regardless of when within the window the user
    /// happened to log.
    private struct WeightTrend {
        /// Slope (weight units per day). Positive = gaining, negative = losing.
        let slopePerDay: Double
        /// Regression value at the chart window's left edge.
        let lineStart: Double
        /// Regression value at the chart window's right edge — the user's current
        /// "trend weight," i.e. what the regression says you weigh today after filtering out
        /// daily water-retention noise. This is the number to show as `current avg`.
        let lineEnd: Double

        /// Net change implied by the line across the chart window. Equals slopePerDay × days
        /// in the window, so a 7-day view's fitChange matches the weekly-rate readout.
        var fitChange: Double { lineEnd - lineStart }
    }

    /// Theil–Sen fit of weight vs. fractional days since the first weigh-in. Needs at least
    /// two weigh-ins with distinct timestamps; returns nil otherwise. Robust to outliers:
    /// the slope is the median of slopes between every (i, j) pair, so a lone spike can't
    /// pivot the line.
    private var weightTrend: WeightTrend? {
        let points = weightPoints
        guard points.count >= 2 else { return nil }
        let firstDate = points.first!.date

        // x = fractional days since first weigh-in (so two weigh-ins on the same calendar
        // day at different times still get distinct x's). y = weight in user's preferred unit.
        let xs: [Double] = points.map { $0.date.timeIntervalSince(firstDate) / 86_400.0 }
        let ys: [Double] = points.map(\.weight)

        // Theil–Sen slope: median of (y_j − y_i)/(x_j − x_i) over all i<j with distinct x.
        var pairSlopes: [Double] = []
        pairSlopes.reserveCapacity(xs.count * (xs.count - 1) / 2)
        for i in 0..<xs.count {
            for j in (i + 1)..<xs.count {
                let dx = xs[j] - xs[i]
                guard dx != 0 else { continue }
                pairSlopes.append((ys[j] - ys[i]) / dx)
            }
        }
        guard !pairSlopes.isEmpty else { return nil }
        let slope = Self.median(of: pairSlopes)
        let intercept = Self.median(of: zip(xs, ys).map { $1 - slope * $0 })

        // Project to the chart-window edges (not the data extremes) so fitChange reflects the
        // selected window, and so the dashed line on the chart spans the full x-axis.
        let windowStartX = range.start.timeIntervalSince(firstDate) / 86_400.0
        let windowEndX = chartDomainEnd.timeIntervalSince(firstDate) / 86_400.0
        return WeightTrend(
            slopePerDay: slope,
            lineStart: slope * windowStartX + intercept,
            lineEnd: slope * windowEndX + intercept
        )
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        if n.isMultiple(of: 2) {
            return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        }
        return sorted[n / 2]
    }

    /// Visible portion of the regression line after clipping to the chart's Y domain.
    /// When the unclipped endpoints fall outside the visible Y range — common on long
    /// windows where the regression extrapolates far past the actual data — this returns
    /// just the segment intersecting the plot area, so the dashed line never escapes the
    /// chart. Returns nil if the entire line lies outside the visible Y range.
    private struct TrendSegment {
        let startDate: Date
        let startY: Double
        let endDate: Date
        let endY: Double
    }

    private func clippedTrendSegment(trend: WeightTrend, yDomain: ClosedRange<Double>) -> TrendSegment? {
        let xStart = range.start.timeIntervalSinceReferenceDate
        let xEnd = chartDomainEnd.timeIntervalSinceReferenceDate
        let yStart = trend.lineStart
        let yEnd = trend.lineEnd
        let dy = yEnd - yStart

        // Horizontal line: either entirely in the Y domain or entirely out.
        if abs(dy) < 1e-9 {
            guard yDomain.contains(yStart) else { return nil }
            return TrendSegment(
                startDate: range.start, startY: yStart,
                endDate: chartDomainEnd, endY: yEnd
            )
        }

        // Parametric clip on t ∈ [0, 1] where (x, y) = (xStart + t·Δx, yStart + t·dy).
        let t1 = (yDomain.lowerBound - yStart) / dy
        let t2 = (yDomain.upperBound - yStart) / dy
        let tMin = max(0.0, min(t1, t2))
        let tMax = min(1.0, max(t1, t2))
        guard tMin < tMax else { return nil }

        let dx = xEnd - xStart
        return TrendSegment(
            startDate: Date(timeIntervalSinceReferenceDate: xStart + tMin * dx),
            startY: yStart + tMin * dy,
            endDate: Date(timeIntervalSinceReferenceDate: xStart + tMax * dx),
            endY: yStart + tMax * dy
        )
    }

    /// Weekly change derived from the regression slope. More stable than (last − first) when
    /// a single noisy weigh-in lands at one end of the range.
    private var avgWeeklyChange: Double? {
        weightTrend.map { $0.slopePerDay * 7 }
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
        var end = calendar.startOfDay(for: .now)
        if !includesTodayInProgress {
            end = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        }
        let days = timeframe.daysBack ?? 30
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        return (start, end)
    }

    private var includesTodayInProgress: Bool {
        profiles.first?.includesTodayInProgress ?? true
    }

    /// Two-way binding into `UserProfile.includesTodayInProgress`. SwiftData @Model objects
    /// are reference types, so the mutation flows through CloudKit sync automatically.
    private var includesTodayBinding: Binding<Bool> {
        Binding(
            get: { profiles.first?.includesTodayInProgress ?? true },
            set: { newValue in
                guard let profile = profiles.first else { return }
                profile.includesTodayInProgress = newValue
                profile.updatedAt = .now
            }
        )
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
        HStack(spacing: 4) {
            if timeframe != .custom {
                Text("Last")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
                if let trend = weightTrend {
                    HStack {
                        trendEndpointLabel(trend.lineStart)
                        Spacer()
                        trendEndpointLabel(trend.lineEnd)
                    }
                }
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Weight", point.weight),
                            series: .value("Series", "actual")
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.accentColor)
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Weight", point.weight)
                        )
                        .foregroundStyle(Color.accentColor)
                    }
                    if let trend = weightTrend,
                       let segment = clippedTrendSegment(
                            trend: trend,
                            yDomain: weightChartYDomain(points: points)
                       ) {
                        LineMark(
                            x: .value("Date", segment.startDate),
                            y: .value("Trend", segment.startY),
                            series: .value("Series", "trend")
                        )
                        .foregroundStyle(Color.indigo)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        LineMark(
                            x: .value("Date", segment.endDate),
                            y: .value("Trend", segment.endY),
                            series: .value("Series", "trend")
                        )
                        .foregroundStyle(Color.indigo)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                }
                .frame(height: 240)
                .chartXScale(domain: range.start...chartDomainEnd)
                .chartYScale(domain: weightChartYDomain(points: points))
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

    /// Y-axis domain for the weight chart. Tight around the data so visit-to-visit changes
    /// are visible: pad 10 units beyond min/max when the swing is wide enough to read; for
    /// narrower ranges (<40), centre on the average and show ±20 so a flat trend doesn't
    /// collapse to a single line on the axis.
    private func weightChartYDomain(points: [WeightPoint]) -> ClosedRange<Double> {
        guard let minW = points.map(\.weight).min(),
              let maxW = points.map(\.weight).max() else {
            return 0...100
        }
        if maxW - minW >= 40 {
            return (minW - 10)...(maxW + 10)
        }
        let avg = points.reduce(0.0) { $0 + $1.weight } / Double(points.count)
        return (avg - 20)...(avg + 20)
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
    private func currentWeightCard(profile: UserProfile) -> some View {
        // LATEST is the all-time newest weigh-in regardless of the visible window — it's a
        // "your current number" readout, not a per-range stat. Comes from the descending-sort
        // @Query, so first == newest by timestamp.
        if let latestEntry = weightEntries.first {
            let unit = preferredUnit.suffix
            let latestWeight = latestEntry.weight(in: preferredUnit)
            let latestDate = latestEntry.timestamp
            let trend = weightTrend
            let weeklyChange = avgWeeklyChange
            // Lifetime change: LATEST minus the user's recorded starting weight. Also
            // window-independent — it's the "how far have I come" stat that always anchors
            // to the same baseline regardless of which range is being viewed.
            let rawDelta: Double? = profiles.first?.startingWeight.map { latestWeight - $0 }
            let trendDelta: Double? = trend.map { $0.fitChange }

            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    weightStat(
                        title: "LATEST (\(monthDayString(latestDate)))",
                        value: String(format: "%.1f", latestWeight),
                        unit: unit
                    )
                    weightDivider
                    weightStat(
                        title: "TREND",
                        value: trend.map { String(format: "%.1f", $0.lineEnd) } ?? "—",
                        unit: unit,
                        valueColor: .indigo
                    )
                    weightDivider
                    weightStat(
                        title: "PER WEEK",
                        value: weeklyChange.map { weightChangeString($0) } ?? "—",
                        unit: "\(unit)/wk",
                        valueColor: weeklyChange.map { weightChangeColor($0) } ?? .primary
                    )
                }
                if rawDelta != nil || trendDelta != nil {
                    deltaRow(rawDelta: rawDelta, trendDelta: trendDelta, unit: unit)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private var weightDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 1, height: 36)
    }

    /// Bottom row of the current-weight card: raw delta centered under LATEST, trend delta
    /// centered on the divider between TREND and PER WEEK. The zero-width Color.clear in the
    /// middle anchors the trend delta to that boundary x-position via overlay.
    private func deltaRow(rawDelta: Double?, trendDelta: Double?, unit: String) -> some View {
        HStack(spacing: 0) {
            Group {
                if let d = rawDelta {
                    deltaLabel(d, unit: unit)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: 1)
            Color.clear.frame(maxWidth: .infinity)
            Color.clear
                .frame(width: 1)
                .overlay {
                    if let d = trendDelta {
                        deltaLabel(d, unit: unit).fixedSize()
                    }
                }
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    private func deltaLabel(_ value: Double, unit: String) -> some View {
        Text("\(weightChangeString(value)) \(unit)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(weightChangeColor(value))
    }

    /// Regression-line endpoint readout shown above the chart. Colored indigo to match the
    /// dashed trend line on the chart so the eye connects them.
    private func trendEndpointLabel(_ value: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(String(format: "%.1f", value))
                .font(.caption.monospacedDigit().weight(.semibold))
            Text(preferredUnit.suffix)
                .font(.caption2)
        }
        .foregroundStyle(Color.indigo)
    }

    private func weightStat(title: String, value: String, unit: String, valueColor: Color = .primary) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func monthDayString(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day())
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

private struct MetricSummaryCard: Identifiable, Hashable {
    let id: String
    let title: String
    let value: Double
    let unit: String
}
