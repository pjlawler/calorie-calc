import SwiftUI
import SwiftData

struct WeekCalendarView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(HealthKitService.self) private var healthKitService

    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \DayLog.date) private var dayLogs: [DayLog]

    @State private var viewModel: WeekCalendarViewModel?
    @State private var selectedDate: Date?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Weekly Log")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .navigationDestination(item: $selectedDate) { date in
                    DayDetailView(date: date)
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
                .task { await ensureBootstrap() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let profile = profiles.first, let vm = viewModel {
            let calculation = vm.calculation(profile: profile, dayLogs: dayLogs)
            WeekCalendarBody(
                profile: profile,
                calculation: calculation,
                dayLogs: dayLogs,
                selectedDate: $selectedDate,
                viewModel: vm
            )
            .task(id: profile.id) { await vm.refreshHealthKit(for: profile) }
            .refreshable { await vm.refreshHealthKit(for: profile) }
        } else {
            ProgressView().controlSize(.large)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Button { viewModel?.shiftWeek(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous week")

                Button { viewModel?.jumpToCurrentWeek() } label: {
                    if let reference = viewModel?.referenceDate {
                        WeekRangeLabel(date: reference, weekStart: profiles.first?.weekStart ?? .monday)
                    }
                }
                .buttonStyle(.plain)

                Button { viewModel?.shiftWeek(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next week")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if showCurrentWeekButton {
                Button {
                    viewModel?.jumpToCurrentWeek()
                } label: {
                    Image(systemName: "calendar.badge.clock")
                }
                .accessibilityLabel("Jump to current week")
            }
        }
    }

    private var showCurrentWeekButton: Bool {
        guard let profile = profiles.first, let vm = viewModel else { return false }
        let dates = vm.assembler(for: profile).weekDates
        return !dates.contains { Calendar.current.isDate($0, inSameDayAs: .now) }
    }

    private func ensureBootstrap() async {
        if profiles.isEmpty {
            modelContext.insert(UserProfile())
            try? modelContext.save()
        }
        if viewModel == nil {
            viewModel = WeekCalendarViewModel(healthKitService: healthKitService)
        }
    }
}

private struct WeekCalendarBody: View {
    let profile: UserProfile
    let calculation: WeeklyCalculation
    let dayLogs: [DayLog]
    @Binding var selectedDate: Date?
    let viewModel: WeekCalendarViewModel

    private var weekDates: [Date] { viewModel.assembler(for: profile).weekDates }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Week Calorie Log")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                WeekSummaryCard(profile: profile, calculation: calculation)
                VStack(spacing: 8) {
                    ForEach(Array(zip(weekDates, calculation.dailyBudgets)), id: \.0) { date, budget in
                        let log = dayLog(for: date)
                        Button { selectedDate = date } label: {
                            DayCellView(
                                date: date,
                                budget: budget,
                                macros: DayCellView.Macros(
                                    protein: log?.totalProtein ?? 0,
                                    carbs: log?.totalCarbs ?? 0,
                                    fat: log?.totalFat ?? 0
                                ),
                                workoutGoal: profile.dailyWorkoutCalorieGoal
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func dayLog(for date: Date) -> DayLog? {
        let day = Calendar.current.startOfDay(for: date)
        return dayLogs.first { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }
}

private struct WeekSummaryCard: View {
    let profile: UserProfile
    let calculation: WeeklyCalculation

    private var caloriesRemaining: Double {
        calculation.weeklyNetTarget - calculation.runningWeeklyNetActual
    }

    var body: some View {
        VStack(spacing: 6) {
            row(label: "Net calories remaining", value: CalorieFormatter.whole(caloriesRemaining))
            varianceRow
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
        )
    }

    private var varianceRow: some View {
        HStack {
            Text("Net calorie variance")
                .font(.subheadline)
            Spacer()
            Text(calculation.planVariance.map(CalorieFormatter.signed) ?? "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(varianceColor)
        }
    }

    private var varianceColor: Color {
        guard let variance = calculation.planVariance else { return .primary }
        if variance > 0 { return .green }
        if variance < 0 { return .red }
        return .primary
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }
}

private struct WeekRangeLabel: View {
    let date: Date
    let weekStart: Weekday

    var body: some View {
        let dates = Calendar.current.daysOfWeek(containing: date, firstWeekday: weekStart.calendarValue)
        let first = dates.first ?? date
        let last = dates.last ?? date
        Text("\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))")
            .font(.subheadline.weight(.semibold))
    }
}
