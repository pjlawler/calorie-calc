import SwiftUI
import SwiftData

struct HistoryView: View {

    @Environment(HealthKitService.self) private var healthKitService
    @Query(sort: \DayLog.date) private var dayLogs: [DayLog]
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \GoalPeriod.startDate) private var goalPeriods: [GoalPeriod]

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if timeframe == .custom {
                        customRangeEditor
                    }
                    rangeLabel
                    ForEach(visibleMetrics) { metric in
                        metricSection(metric)
                    }
                    analyzeButton
                        .padding(.top, 8)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
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
        .task(id: timeframeRangeKey) { await loadHealthKit() }
    }

    private var analyzeButton: some View {
        Button {
            showAnalysis = true
        } label: {
            Label("Analyze", systemImage: "sparkles")
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
            dailyExerciseGoal: currentGoalPeriod?.dailyWorkoutCalorieGoal
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
            Spacer()
            if isLoadingHealthKit {
                ProgressView().controlSize(.small)
            }
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
            Text(metric.displayName)
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
                SummaryCard(id: "total", title: totalTitleForShortRange, value: summary.total, unit: unit),
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit)
            ]
        case .month:
            return [
                SummaryCard(id: "month-total", title: "Month Total", value: summary.total, unit: unit),
                SummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit)
            ]
        case .year:
            return [
                SummaryCard(id: "year-total", title: "Year Total", value: summary.total, unit: unit),
                SummaryCard(id: "month-avg", title: "Month Avg", value: summary.monthAvg, unit: unit),
                SummaryCard(id: "week-avg", title: "Week Avg", value: summary.weekAvg, unit: unit),
                SummaryCard(id: "day-avg", title: "Day Avg", value: summary.dayAvg, unit: unit)
            ]
        }
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
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatted(card.value, metric: metric))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(metric.color)
                Text(card.unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
