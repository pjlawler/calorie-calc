import SwiftUI
import SwiftData

struct HistoryView: View {

    @Environment(HealthKitService.self) private var healthKitService
    @Query(sort: \DayLog.date) private var dayLogs: [DayLog]
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \GoalPeriod.startDate) private var goalPeriods: [GoalPeriod]
    @Query(sort: \SupplementEntry.timestamp) private var supplementEntries: [SupplementEntry]
    @Query(sort: \WeightEntry.timestamp) private var weightEntries: [WeightEntry]

    @AppStorage("history.timeframe") private var timeframe: HistoryTimeframe = .currentWeek
    @AppStorage("settings.showSteps") private var showSteps: Bool = true
    @AppStorage("history.customStart") private var customStartTS: Double = (Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now)) ?? .now).timeIntervalSinceReferenceDate
    @AppStorage("history.customEnd") private var customEndTS: Double = Calendar.current.startOfDay(for: .now).timeIntervalSinceReferenceDate
    @State private var workoutBurnByDay: [Date: Double] = [:]
    @State private var stepsByDay: [Date: Double] = [:]
    @State private var isLoadingHealthKit = false
    @State private var showSettings = false
    @State private var showAnalysis = false

    private var weekStart: Weekday { profiles.first?.weekStart ?? .monday }
    private var currentGoalPeriod: GoalPeriod? { GoalPeriod.current(in: goalPeriods) }
    private var tracksSupplements: Bool { profiles.first?.tracksSupplements ?? false }

    private var customStart: Date { Date(timeIntervalSinceReferenceDate: customStartTS) }
    private var customEnd: Date { Date(timeIntervalSinceReferenceDate: customEndTS) }
    private var customStartBinding: Binding<Date> {
        Binding(get: { customStart }, set: { customStartTS = $0.timeIntervalSinceReferenceDate })
    }
    private var customEndBinding: Binding<Date> {
        Binding(get: { customEnd }, set: { customEndTS = $0.timeIntervalSinceReferenceDate })
    }

    private var range: (start: Date, end: Date) {
        HistoryAggregator.dateRange(
            for: timeframe,
            reference: .now,
            weekStart: weekStart,
            customStart: customStart,
            customEnd: customEnd
        )
    }

    /// For the in-progress week, average only over days that have already ended so today's
    /// partial intake doesn't drag the daily average down.
    private var averageEnd: Date? {
        guard timeframe == .currentWeek else { return nil }
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))
    }

    private var visibleMetrics: [HistoryMetric] {
        HistoryMetric.allCases.filter { showSteps || $0 != .steps }
    }

    private var totals: [Date: HistoryAggregator.DailyTotals] {
        HistoryAggregator.dailyTotals(
            dayLogs: dayLogs,
            workoutBurnByDay: workoutBurnByDay,
            stepsByDay: stepsByDay
        )
    }

    private var supplementSummaries: [SupplementHistorySummary] {
        HistoryAggregator.supplementSummaries(
            entries: supplementEntries,
            start: range.start,
            end: range.end,
            averageEnd: averageEnd
        )
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear.frame(height: 0).id("top")
                    header
                    if timeframe == .custom {
                        customRangeEditor
                    }
                    ForEach(visibleMetrics) { metric in
                        metricSection(metric)
                    }
                    if tracksSupplements && !supplementSummaries.isEmpty {
                        supplementsSection
                    }
                    analyzeButton
                        .padding(.top, 8)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
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
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showAnalysis) {
                NutritionAnalysisSheet(data: analysisInput)
            }
            }
        }
        .task(id: timeframeRangeKey) { await loadHealthKit() }
    }

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
        let avgEnd = averageEnd
        let calories = HistoryAggregator.summary(metric: .calories, start: range.start, end: range.end, dailyTotals: totals, averageEnd: avgEnd)
        let protein = HistoryAggregator.summary(metric: .protein, start: range.start, end: range.end, dailyTotals: totals, averageEnd: avgEnd)
        let carbs = HistoryAggregator.summary(metric: .carbs, start: range.start, end: range.end, dailyTotals: totals, averageEnd: avgEnd)
        let fat = HistoryAggregator.summary(metric: .fat, start: range.start, end: range.end, dailyTotals: totals, averageEnd: avgEnd)
        let exercise = HistoryAggregator.summary(metric: .exercise, start: range.start, end: range.end, dailyTotals: totals, averageEnd: avgEnd)
        let net = HistoryAggregator.summary(metric: .net, start: range.start, end: range.end, dailyTotals: totals, averageEnd: avgEnd)
        let dayCount = max(1, (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: range.start), to: Calendar.current.startOfDay(for: range.end)).day ?? 0) + 1)

        let calendar = Calendar.current
        let rangeStartDay = calendar.startOfDay(for: range.start)
        let rangeEndDay = calendar.startOfDay(for: range.end)
        let exerciseDayCount = totals
            .filter { $0.key >= rangeStartDay && $0.key <= rangeEndDay && $0.value.exercise > 0 }
            .count

        // Pull a wider window of weight entries than the analysis range itself so the AI
        // can comment on trend even when the user is looking at a short period (e.g.
        // current week). 60 days back gives ~8 weeks of context, plenty for a confident
        // read once enough samples accumulate.
        let displayUnit = profiles.first?.weightUnit ?? .pounds
        let weightWindowStart = calendar.date(byAdding: .day, value: -60, to: rangeStartDay) ?? rangeStartDay
        let weightSamples = weightEntries
            .filter { $0.timestamp >= weightWindowStart && $0.timestamp <= range.end }
            .map { WeightSample(date: $0.timestamp, weight: $0.weight(in: displayUnit)) }
        let goalWeightInDisplayUnit = profiles.first?.goalWeight

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
            goalWeight: goalWeightInDisplayUnit,
            exerciseDayCount: exerciseDayCount
        )
    }

    // MARK: - Header / picker

    private var header: some View {
        HStack {
            Picker("Timeframe", selection: $timeframe) {
                ForEach(HistoryTimeframe.allCases) { tf in
                    Text(tf.displayName).tag(tf)
                }
            }
            .pickerStyle(.menu)
            if isLoadingHealthKit {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Text(rangeText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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

    private var rangeLabel: some View {
        Text(rangeText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var rangeText: String {
        let s = range.start.formatted(.dateTime.month(.abbreviated).day().year())
        let e = range.end.formatted(.dateTime.month(.abbreviated).day().year())
        if Calendar.current.isDate(range.start, inSameDayAs: range.end) { return s }
        return "\(s) – \(e)"
    }

    // MARK: - Metric section

    @ViewBuilder
    private func metricSection(_ metric: HistoryMetric) -> some View {
        let summary = HistoryAggregator.summary(
            metric: metric,
            start: range.start,
            end: range.end,
            dailyTotals: totals,
            averageEnd: averageEnd
        )
        let cards = cardsFor(metric: metric, summary: summary)

        VStack(alignment: .leading, spacing: 8) {
            Text(metric == .steps ? metric.displayName : "\(metric.displayName) (\(metric.unit))")
                .font(.subheadline.weight(.semibold))
            if cards.count > 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(cards) { card in
                            tile(card, metric: metric)
                                .frame(width: 140)
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    ForEach(cards) { card in
                        tile(card, metric: metric)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func cardsFor(metric: HistoryMetric, summary: HistorySummary) -> [SummaryCard] {
        let unit = metric.unit
        switch timeframe {
        case .day:
            return [
                SummaryCard(id: "day-total", title: "Day Total", value: summary.total, unit: unit)
            ]
        case .currentWeek, .lastWeek, .rolling7, .custom:
            return [
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                SummaryCard(id: "total", title: totalTitleForShortRange, value: summary.total, unit: unit)
            ]
        case .month:
            return [
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                SummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                SummaryCard(id: "month-total", title: "Month Total", value: summary.total, unit: unit)
            ]
        case .days90:
            return [
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                SummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                SummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                SummaryCard(id: "range-total", title: "90-Day Total", value: summary.total, unit: unit)
            ]
        case .days180:
            return [
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                SummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                SummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                SummaryCard(id: "range-total", title: "180-Day Total", value: summary.total, unit: unit)
            ]
        case .year:
            return [
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                SummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                SummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                SummaryCard(id: "year-total", title: "Year Total", value: summary.total, unit: unit)
            ]
        }
    }

    // MARK: - Supplements section

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
                            supplementTile(card)
                                .frame(width: 140)
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    ForEach(cards) { card in
                        supplementTile(card)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// Mirrors `cardsFor(metric:summary:)` so supplements render the same tile layout per
    /// timeframe — Day Total / Day+Total / Day+Week+Month+Range Total / etc.
    private func supplementCards(for summary: SupplementHistorySummary) -> [SummaryCard] {
        let unit = summary.unit
        switch timeframe {
        case .day:
            return [SummaryCard(id: "day-total", title: "Day Total", value: summary.total, unit: unit)]
        case .currentWeek, .lastWeek, .rolling7, .custom:
            return [
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                SummaryCard(id: "total", title: totalTitleForShortRange, value: summary.total, unit: unit),
            ]
        case .month:
            return [
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                SummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                SummaryCard(id: "month-total", title: "Month Total", value: summary.total, unit: unit),
            ]
        case .days90:
            return [
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                SummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                SummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                SummaryCard(id: "range-total", title: "90-Day Total", value: summary.total, unit: unit),
            ]
        case .days180:
            return [
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                SummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                SummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                SummaryCard(id: "range-total", title: "180-Day Total", value: summary.total, unit: unit),
            ]
        case .year:
            return [
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit),
                SummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                SummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                SummaryCard(id: "year-total", title: "Year Total", value: summary.total, unit: unit),
            ]
        }
    }

    private func supplementTile(_ card: SummaryCard) -> some View {
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

    private var totalTitleForShortRange: String {
        switch timeframe {
        case .currentWeek, .lastWeek: "Week Total"
        case .rolling7: "7-Day Total"
        case .custom: "Total"
        default: "Total"
        }
    }

    private func tile(_ card: SummaryCard, metric: HistoryMetric) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(formatted(card.value, metric: metric))
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

    private func formatted(_ value: Double, metric: HistoryMetric) -> String {
        switch metric {
        case .protein, .carbs, .fat:
            return CalorieFormatter.macro(value)
        case .steps:
            return Int(value.rounded()).formatted(.number)
        default:
            return CalorieFormatter.whole(value)
        }
    }

    // MARK: - HealthKit

    private var timeframeRangeKey: String {
        "\(timeframe.rawValue)-\(Int(range.start.timeIntervalSince1970))-\(Int(range.end.timeIntervalSince1970))"
    }

    private func loadHealthKit() async {
        isLoadingHealthKit = true
        defer { isLoadingHealthKit = false }
        async let burnTask = healthKitService.dailyWorkoutBurn(from: range.start, through: range.end)
        async let stepsTask = healthKitService.dailyStepsByDay(from: range.start, through: range.end)
        workoutBurnByDay = (try? await burnTask) ?? [:]
        stepsByDay = (try? await stepsTask) ?? [:]
    }
}

private struct SummaryCard: Identifiable, Hashable {
    let id: String
    let title: String
    let value: Double
    let unit: String
}
