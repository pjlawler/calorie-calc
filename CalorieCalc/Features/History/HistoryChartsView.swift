import SwiftUI
import SwiftData
import Charts

struct HistoryChartsView: View {

    @Environment(HealthKitService.self) private var healthKitService
    @Query(sort: \DayLog.date) private var dayLogs: [DayLog]
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \GoalPeriod.startDate) private var goalPeriods: [GoalPeriod]

    @State private var metric: HistoryMetric = .calories
    @State private var timeframe: HistoryTimeframe = .currentWeek
    @State private var workoutBurnByDay: [Date: Double] = [:]
    @State private var isLoadingHealthKit = false

    private var weekStart: Weekday { profiles.first?.weekStart ?? .monday }
    private var currentGoalPeriod: GoalPeriod? { GoalPeriod.current(in: goalPeriods) }

    private var goals: HistoryAggregator.Goals {
        HistoryAggregator.Goals(
            dailyCalorieGoal: currentGoalPeriod.map { Double($0.dailyGrossCalorieGoal) },
            dailyWorkoutGoal: currentGoalPeriod.map { Double($0.dailyWorkoutCalorieGoal) }
        )
    }

    private var range: (start: Date, end: Date) {
        HistoryAggregator.dateRange(for: timeframe, reference: .now, weekStart: weekStart)
    }

    private var chartData: HistoryChartData {
        let totals = HistoryAggregator.dailyTotals(dayLogs: dayLogs, workoutBurnByDay: workoutBurnByDay)
        return HistoryAggregator.chartData(
            metric: metric,
            timeframe: timeframe,
            reference: .now,
            weekStart: weekStart,
            dailyTotals: totals,
            dayLogs: dayLogs,
            goals: goals
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    timeframePicker
                    metricPicker
                    chartCard
                    summaryCard
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
        }
        .task(id: timeframeRangeKey) { await loadHealthKit() }
    }

    // MARK: - Pickers

    private var timeframePicker: some View {
        Picker("Timeframe", selection: $timeframe) {
            ForEach(HistoryTimeframe.allCases) { tf in
                Text(tf.displayName).tag(tf)
            }
        }
        .pickerStyle(.segmented)
    }

    private var metricPicker: some View {
        Picker("Metric", selection: $metric) {
            ForEach(HistoryMetric.allCases) { m in
                Text(m.displayName).tag(m)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline)
                    .font(.headline)
                Spacer()
                if isLoadingHealthKit {
                    ProgressView().controlSize(.small)
                }
            }
            chart
                .frame(height: 260)
            if let goalLabel = chartData.goalLabel, let goal = chartData.goal {
                HStack(spacing: 6) {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                    Text("\(goalLabel): \(Int(goal.rounded())) \(metric.unit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    @ChartContentBuilder
    private var chartContent: some ChartContent {
        ForEach(chartData.buckets) { bucket in
            BarMark(
                x: .value("Bucket", bucket.label),
                y: .value(metric.displayName, bucket.value)
            )
            .foregroundStyle(metric.color.gradient)
            .cornerRadius(4)
        }
        if let goal = chartData.goal {
            RuleMark(y: .value("Goal", goal))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Chart { chartContent }
            .chartXAxis { xAxis }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(CalorieFormatter.whole(v))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
    }

    @AxisContentBuilder
    private var xAxis: some AxisContent {
        switch timeframe {
        case .month:
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisTick()
                AxisValueLabel()
            }
        default:
            AxisMarks { _ in
                AxisTick()
                AxisValueLabel()
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        HStack(spacing: 12) {
            summaryTile(title: totalLabel, value: CalorieFormatter.whole(chartData.total), unit: metric.unit)
            summaryTile(title: averageLabel, value: CalorieFormatter.whole(chartData.average), unit: metric.unit)
        }
    }

    private func summaryTile(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    // MARK: - Copy

    private var headline: String {
        switch timeframe {
        case .day: "\(metric.displayName) by meal today"
        case .currentWeek: "\(metric.displayName) this week"
        case .rolling7: "\(metric.displayName), last 7 days"
        case .month: "\(metric.displayName), last 30 days"
        case .year: "\(metric.displayName), last 12 months"
        }
    }

    private var totalLabel: String {
        switch timeframe {
        case .day: "Today"
        case .currentWeek, .rolling7: "Week total"
        case .month: "Month total"
        case .year: "Year total"
        }
    }

    private var averageLabel: String {
        switch timeframe {
        case .day: "Per meal avg"
        case .currentWeek, .rolling7, .month: "Daily avg"
        case .year: "Monthly avg"
        }
    }

    // MARK: - HealthKit load

    private var timeframeRangeKey: String {
        "\(timeframe.rawValue)-\(Int(range.start.timeIntervalSince1970))-\(Int(range.end.timeIntervalSince1970))"
    }

    private func loadHealthKit() async {
        isLoadingHealthKit = true
        defer { isLoadingHealthKit = false }
        do {
            let result = try await healthKitService.dailyWorkoutBurn(
                from: range.start,
                through: range.end
            )
            workoutBurnByDay = result
        } catch {
            workoutBurnByDay = [:]
        }
    }
}
