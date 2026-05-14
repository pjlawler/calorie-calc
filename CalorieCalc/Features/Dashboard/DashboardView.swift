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
                       let firstDate = points.first?.date,
                       let lastDate = points.last?.date {
                        LineMark(
                            x: .value("Date", firstDate),
                            y: .value("Trend", trend.lineStart),
                            series: .value("Series", "trend")
                        )
                        .foregroundStyle(Color.indigo)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        LineMark(
                            x: .value("Date", lastDate),
                            y: .value("Trend", trend.lineEnd),
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
        let points = weightPoints
        if let last = points.last {
            let unit = preferredUnit.suffix
            let trend = weightTrend
            let weeklyChange = avgWeeklyChange
            let rawDelta: Double? = (points.first.map { $0.id == last.id } ?? true) ? nil : (last.weight - points.first!.weight)
            let trendDelta: Double? = trend.map { $0.fitChange }

            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    weightStat(
                        title: "LATEST (\(monthDayString(last.date)))",
                        value: String(format: "%.1f", last.weight),
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
