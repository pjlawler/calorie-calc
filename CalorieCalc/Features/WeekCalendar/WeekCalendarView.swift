import SwiftUI
import SwiftData

struct WeekCalendarView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(HealthKitService.self) private var healthKitService

    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \GoalPeriod.startDate) private var goalPeriods: [GoalPeriod]
    @Query(sort: \DayLog.date) private var dayLogs: [DayLog]

    @State private var viewModel: WeekCalendarViewModel?
    @State private var selectedDate: Date?
    @State private var showSettings = false

    private var currentPeriod: GoalPeriod? { GoalPeriod.current(in: goalPeriods) }
    private func period(for date: Date) -> GoalPeriod? {
        GoalPeriod.period(covering: date, in: goalPeriods)
    }

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
        if let vm = viewModel,
           let current = currentPeriod,
           let weekPeriod = period(for: vm.referenceDate) {
            let calculation = vm.calculation(period: weekPeriod, dayLogs: dayLogs)
            WeekCalendarBody(
                period: weekPeriod,
                currentPeriod: current,
                calculation: calculation,
                dayLogs: dayLogs,
                selectedDate: $selectedDate,
                viewModel: vm
            )
            .task(id: weekPeriod.id) { await vm.refreshHealthKit(for: weekPeriod) }
            .refreshable { await vm.refreshHealthKit(for: weekPeriod) }
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
                        WeekRangeLabel(date: reference, weekStart: currentPeriod?.weekStart ?? .monday)
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
        guard let current = currentPeriod,
              let vm = viewModel else { return false }
        let dates = vm.assembler(for: current).weekDates
        return !dates.contains { Calendar.current.isDate($0, inSameDayAs: .now) }
    }

    private func ensureBootstrap() async {
        if profiles.isEmpty {
            modelContext.insert(UserProfile())
            try? modelContext.save()
        }
        if let profile = profiles.first {
            GoalPeriod.ensureBootstrapped(in: modelContext, profile: profile, existing: goalPeriods)
        }
        if viewModel == nil {
            viewModel = WeekCalendarViewModel(healthKitService: healthKitService)
        }
    }
}

private struct WeekCalendarBody: View {
    let period: GoalPeriod
    let currentPeriod: GoalPeriod
    let calculation: WeeklyCalculation
    let dayLogs: [DayLog]
    @Binding var selectedDate: Date?
    let viewModel: WeekCalendarViewModel

    private var weekDates: [Date] { viewModel.assembler(for: period).weekDates }

    private var caloriesRemaining: Double {
        calculation.weeklyNetTarget - calculation.runningWeeklyNetActual
    }

    private var remainingColor: Color {
        caloriesRemaining < 0 ? .red : .primary
    }

    private var planColor: Color {
        guard let variance = calculation.planVariance else { return .primary }
        if variance > 0 { return .green }
        if variance < 0 { return .red }
        return .primary
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Week Calorie Log")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                                workoutGoal: period.dailyWorkoutCalorieGoal
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                weeklySummary
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var weeklySummary: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !hidePlanVariance {
                planSummary
            }
            remainingSummary
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private var hidePlanVariance: Bool {
        guard let lastDay = weekDates.last else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: .now) >= calendar.startOfDay(for: lastDay)
    }

    private var remainingSummary: some View {
        let isOver = caloriesRemaining < 0
        let magnitude = CalorieFormatter.whole(abs(caloriesRemaining))
        let value = Text("\(CalorieFormatter.whole(caloriesRemaining)) kCal")
            .foregroundStyle(remainingColor)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Remaining: \(value)")
                .font(.title2.monospacedDigit().weight(.semibold))
            Text(remainingParagraph(isOver: isOver, magnitude: magnitude))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remainingParagraph(isOver: Bool, magnitude: String) -> String {
        if isOver {
            let core = "You're \(magnitude) kCal over your weekly budget."
            let tail: String
            switch weekPosition {
            case .notCurrentWeek:
                return core
            case .earlyWeek:
                tail = "Don't be discouraged — the week is still young. Tighten things up over the next few days and you'll erase most of this."
            case .midWeek:
                tail = "Don't be discouraged. A couple of lighter days between now and the weekend can bring this back in line."
            case .lateWeek:
                tail = "Only one day left — eating lighter tomorrow will help, and don't be discouraged if it doesn't fully close. Next week is a fresh start."
            case .lastDay:
                tail = "Today's the last day, so this week is essentially locked in. Don't be discouraged — reset and get back on track next week."
            }
            return "\(core) \(tail)"
        } else {
            let core = "You have \(magnitude) kCal remaining to eat this week."
            let tail: String
            switch weekPosition {
            case .notCurrentWeek:
                return core
            case .earlyWeek:
                tail = "Plenty of week left to spend it — more workouts will earn you even more calories."
            case .midWeek:
                tail = "Nice cushion heading into the back half. Future workouts will add even more."
            case .lateWeek:
                tail = "Just one day left — you've got room to eat well tomorrow. Any workout you log will add to the budget."
            case .lastDay:
                tail = "Today's the last day of the week, so this is your remaining runway. Any exercise today adds to it."
            }
            return "\(core) \(tail)"
        }
    }

    @ViewBuilder
    private var planSummary: some View {
        if let variance = calculation.planVariance {
            let magnitude = CalorieFormatter.whole(abs(variance))
            let value = Text("\(CalorieFormatter.signed(variance)) kCal")
                .foregroundStyle(planColor)
            VStack(alignment: .leading, spacing: 6) {
                Text("Plan Variance: \(value)")
                    .font(.title2.monospacedDigit().weight(.semibold))
                Text(planParagraph(variance: variance, magnitude: magnitude))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func planParagraph(variance: Double, magnitude: String) -> String {
        if variance == 0 {
            return "You're right on plan for the week."
        }
        let direction = variance > 0 ? "under" : "over"
        let core = "You're \(magnitude) calories \(direction) your plan."
        let ahead = variance > 0
        let tail: String
        switch weekPosition {
        case .notCurrentWeek:
            return core
        case .earlyWeek:
            tail = ahead
                ? "Plenty of week left — keep this rhythm and it'll be a great one."
                : "The week just started, so there's plenty of room to dial it in from here."
        case .midWeek:
            tail = ahead
                ? "You've built a solid cushion heading into the back half."
                : "A few lighter days between now and the weekend will close the gap."
        case .lateWeek:
            tail = ahead
                ? "Just one day left — a steady finish locks this in."
                : "One day left to close the gap — a lighter day tomorrow makes the difference."
        case .lastDay:
            tail = ahead
                ? "Last day of the week — bring it home today."
                : "Today's the last day — eating a bit lighter will bring you closer to plan."
        }
        return "\(core) \(tail)"
    }

    private enum WeekPosition {
        case notCurrentWeek
        case earlyWeek
        case midWeek
        case lateWeek
        case lastDay
    }

    private var weekPosition: WeekPosition {
        guard let todayIndex = weekDates.firstIndex(where: { Calendar.current.isDate($0, inSameDayAs: .now) }) else {
            return .notCurrentWeek
        }
        switch todayIndex {
        case 0, 1: return .earlyWeek
        case 2, 3, 4: return .midWeek
        case 5: return .lateWeek
        default: return .lastDay
        }
    }

private func dayLog(for date: Date) -> DayLog? {
        let day = Calendar.current.startOfDay(for: date)
        return dayLogs.first { Calendar.current.isDate($0.date, inSameDayAs: day) }
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
