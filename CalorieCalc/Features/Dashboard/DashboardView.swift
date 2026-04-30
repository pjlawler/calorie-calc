import SwiftUI
import SwiftData
import Charts

/// "My Plan" + "Progress" merged into a single scrolling view. Plan cards (current weight, plan
/// summary) sit on top; Progress section (timeframe picker, weight chart, summary tiles) below.
/// The "Log" CTA that used to live in the weight card header now sits next to the "Progress"
/// section title to keep both screens collapsed into one.
struct DashboardView: View {

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \GoalPeriod.startDate) private var goalPeriods: [GoalPeriod]
    @Query(sort: [SortDescriptor(\WeightEntry.timestamp, order: .reverse)]) private var weightEntries: [WeightEntry]

    @State private var showWeightSheet = false
    @State private var showSettings = false

    @AppStorage("progress.timeframe") private var timeframe: ProgressTrendTimeframe = .days90
    @AppStorage("progress.customStart") private var customStartTS: Double = (Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: .now)) ?? .now).timeIntervalSinceReferenceDate
    @AppStorage("progress.customEnd") private var customEndTS: Double = Calendar.current.startOfDay(for: .now).timeIntervalSinceReferenceDate
    @AppStorage("dashboard.planCardExpanded") private var planCardExpanded: Bool = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let profile = profiles.first {
                        planCard(profile: profile)
                        progressSection(profile: profile)
                    } else {
                        ProgressView().padding(.top, 80)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("My Plan")
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
            .sheet(isPresented: $showWeightSheet) {
                WeightLogView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .task { await ensureProfile() }
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
        To reach your goal weight, we're targeting an average of \(profile.dailyNetCalorieGoal) net calories per day — the weekly total is your true budget, not a strict daily ceiling. Early in the week, hit your plan-day goal of \(profile.dailyGrossCalorieGoal) kcal eaten and \(profile.dailyWorkoutCalorieGoal) kcal burned. Every day you stay on plan banks headroom toward the end of the week, so a dinner out, a drink, or a treat on your flex days won't derail your progress.
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
            HStack(alignment: .firstTextBaseline) {
                Text("Progress")
                    .font(.title2.weight(.bold))
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
            .padding(.top, 4)

            timeframePicker
            if timeframe == .custom {
                customRangeEditor
            }
            weightChartCard(profile: profile)
            summaryCard(profile: profile)
        }
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
                .chartXScale(domain: range.start...range.end)
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
            let delta = last.weight - first.weight
            HStack(spacing: 12) {
                summaryTile(
                    title: "Latest",
                    value: String(format: "%.1f", last.weight),
                    unit: preferredUnit.suffix
                )
                if first.id != last.id {
                    summaryTile(
                        title: "Change",
                        value: (delta > 0 ? "+" : "") + String(format: "%.1f", delta),
                        unit: preferredUnit.suffix
                    )
                }
            }
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
