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
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
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
    @Query(
        filter: #Predicate<CachedFood> { $0.isFavorite == true },
        sort: [SortDescriptor(\CachedFood.lastUsed, order: .reverse)]
    )
    private var favoriteFoods: [CachedFood]

    let period: GoalPeriod
    let currentPeriod: GoalPeriod
    let calculation: WeeklyCalculation
    let dayLogs: [DayLog]
    @Binding var selectedDate: Date?
    let viewModel: WeekCalendarViewModel

    @State private var showFavoriteQuickAdd = false

    private var weekDates: [Date] { viewModel.assembler(for: period).weekDates }

    private var caloriesRemaining: Double {
        calculation.weeklyNetTarget - calculation.runningWeeklyNetActual
    }

    private var remainingColor: Color {
        caloriesRemaining < 0 ? .red : .primary
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(alignment: .center) {
                    Text("CalorieCalc")
                        .font(.largeTitle.bold())
                    Spacer()
                    Button {
                        showFavoriteQuickAdd = true
                    } label: {
                        Label("Add", systemImage: "star.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(favoriteFoods.isEmpty)
                    .accessibilityLabel("Quick add favorite food")
                }
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
        .sheet(isPresented: $showFavoriteQuickAdd) {
            FavoriteQuickAddListSheet(favorites: favoriteFoods)
        }
    }

    private var weeklySummary: some View {
        VStack(alignment: .leading, spacing: 20) {
            plannedRemainingTodaySummary
            remainingSummary
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private var eatingRemainingThroughToday: Double? {
        guard let todayIndex = weekDates.firstIndex(where: {
            Calendar.current.isDate($0, inSameDayAs: .now)
        }) else { return nil }
        let inclusive = calculation.dailyBudgets.prefix(todayIndex + 1)
        let plannedSum = inclusive.reduce(0.0) { $0 + ($1.grossBudget ?? 0) }
        let consumedSum = inclusive.reduce(0.0) { $0 + $1.consumed }
        return plannedSum - consumedSum
    }

    private var workoutSurplusThroughToday: Double? {
        guard let todayIndex = weekDates.firstIndex(where: {
            Calendar.current.isDate($0, inSameDayAs: .now)
        }) else { return nil }
        let inclusive = calculation.dailyBudgets.prefix(todayIndex + 1)
        let plannedSum = Double(period.dailyWorkoutCalorieGoal) * Double(todayIndex + 1)
        let burnedSum = inclusive.reduce(0.0) { $0 + $1.burned }
        return burnedSum - plannedSum
    }

    @ViewBuilder
    private var plannedRemainingTodaySummary: some View {
        if let eatingRemaining = eatingRemainingThroughToday,
           let workoutSurplus = workoutSurplusThroughToday {
            let combined = eatingRemaining + workoutSurplus
            let eatingUnderGoal = eatingRemaining >= 0
            let workoutOverGoal = workoutSurplus >= 0
            let aheadOfPlan = combined >= 0
            let eatingNumber = Text(CalorieFormatter.whole(abs(eatingRemaining)))
                .foregroundStyle(eatingUnderGoal ? .green : .red)
            let workoutNumber = Text(CalorieFormatter.whole(abs(workoutSurplus)))
                .foregroundStyle(workoutOverGoal ? .green : .red)
            let combinedNumber = Text(CalorieFormatter.whole(abs(combined)))
                .foregroundStyle(aheadOfPlan ? .green : .red)
            VStack(alignment: .leading, spacing: 6) {
                Text("Plan progress")
                    .font(.title2.weight(.semibold))
                progressParagraph(
                    eatingUnderGoal: eatingUnderGoal,
                    eatingNumber: eatingNumber,
                    workoutOverGoal: workoutOverGoal,
                    workoutNumber: workoutNumber,
                    aheadOfPlan: aheadOfPlan,
                    combinedNumber: combinedNumber
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func progressParagraph(
        eatingUnderGoal: Bool,
        eatingNumber: Text,
        workoutOverGoal: Bool,
        workoutNumber: Text,
        aheadOfPlan: Bool,
        combinedNumber: Text
    ) -> Text {
        let eatingSide = eatingUnderGoal ? "under" : "over"
        let workoutSide = workoutOverGoal ? "over" : "under"
        let planSide = aheadOfPlan ? "ahead of" : "behind"
        let encouragement = aheadOfPlan
            ? "Keep up the great work!"
            : "There's still time to turn it around."
        return Text("So far you're \(eatingNumber) kCal \(eatingSide) your eating goal and \(workoutNumber) kCal \(workoutSide) your workout goal — that puts you \(combinedNumber) kCal \(planSide) your plan. \(encouragement)")
    }

    private var remainingSummary: some View {
        let isOver = caloriesRemaining < 0
        let magnitude = CalorieFormatter.whole(abs(caloriesRemaining))
        let number = Text(magnitude)
            .foregroundStyle(remainingColor)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Net calories remaining")
                .font(.title2.weight(.semibold))
            remainingParagraph(isOver: isOver, number: number)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remainingParagraph(isOver: Bool, number: Text) -> Text {
        if isOver {
            let tail: String
            switch weekPosition {
            case .notCurrentWeek:
                return Text("You're \(number) kCal over your weekly budget.")
            case .earlyWeek:
                tail = "Don't be discouraged — the week is still young. Tighten things up over the next few days and you'll erase most of this."
            case .midWeek:
                tail = "Don't be discouraged. A couple of lighter days between now and the weekend can bring this back in line."
            case .lateWeek:
                tail = "Only one day left — eating lighter tomorrow will help, and don't be discouraged if it doesn't fully close. Next week is a fresh start."
            case .lastDay:
                tail = "Today's the last day, so this week is essentially locked in. Don't be discouraged — reset and get back on track next week."
            }
            return Text("You're \(number) kCal over your weekly budget. \(tail)")
        } else {
            let tail: String
            switch weekPosition {
            case .notCurrentWeek:
                return Text("You have \(number) kCal remaining to eat this week.")
            case .earlyWeek:
                tail = "Plenty of week left to spend it — more workouts will earn you even more calories."
            case .midWeek:
                tail = "Nice cushion heading into the back half. Future workouts will add even more."
            case .lateWeek:
                tail = "Just one day left — you've got room to eat well tomorrow. Any workout you log will add to the budget."
            case .lastDay:
                tail = "Today's the last day of the week, so this is your remaining runway. Any exercise today adds to it."
            }
            return Text("You have \(number) kCal remaining to eat this week. \(tail)")
        }
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
        DayLog.preferredForDay(dayLogs, on: date)
    }
}

private struct FavoriteQuickAddListSheet: View {
    let favorites: [CachedFood]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var dayLogs: [DayLog]

    @State private var selectedMeal: MealType = MealType.quickAddDefaultForCurrentTime()
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: .now)

    var body: some View {
        NavigationStack {
            List {
                Section("Add to") {
                    Picker("Meal", selection: $selectedMeal) {
                        ForEach(MealType.allCases.sorted(by: { $0.order < $1.order }), id: \.self) { meal in
                            Text(meal.displayName).tag(meal)
                        }
                    }
                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                }

                Section("Favorites") {
                    if favorites.isEmpty {
                        Text("No favorites yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(favorites, id: \.id) { favorite in
                            Button {
                                addFavoriteToLog(favorite)
                                dismiss()
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(favorite.name)
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            if let brand = favorite.brand {
                                                Text(brand).lineLimit(1)
                                            }
                                            Text(favorite.defaultServingDescription).lineLimit(1)
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(CalorieFormatter.whole(favorite.caloriesPerServing)) kcal")
                                        .font(.subheadline.monospacedDigit())
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Quick Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
    
    private func addFavoriteToLog(_ food: CachedFood) {
        let day = normalizedSelectedDay(from: selectedDate)
        let dayLog = ensureDayLog(for: day)
        let timestamp = defaultTimestamp(for: day)

        let entry = FoodEntry(
            name: food.name,
            brand: food.brand,
            servingDescription: food.defaultServingDescription,
            servingSizeGrams: food.defaultServingSizeGrams,
            servingSizeMilliliters: food.defaultServingSizeMilliliters,
            quantity: 1,
            caloriesPerServing: food.caloriesPerServing,
            proteinPerServing: food.proteinPerServing,
            carbsPerServing: food.carbsPerServing,
            fatPerServing: food.fatPerServing,
            saturatedFatPerServing: food.saturatedFatPerServing,
            transFatPerServing: food.transFatPerServing,
            monounsaturatedFatPerServing: food.monounsaturatedFatPerServing,
            polyunsaturatedFatPerServing: food.polyunsaturatedFatPerServing,
            cholesterolPerServing: food.cholesterolPerServing,
            sodiumPerServing: food.sodiumPerServing,
            fiberPerServing: food.fiberPerServing,
            sugarsPerServing: food.sugarsPerServing,
            addedSugarsPerServing: food.addedSugarsPerServing,
            mealType: selectedMeal,
            source: food.source,
            externalId: food.externalId,
            notes: food.notes,
            timestamp: timestamp,
            dayLog: dayLog
        )
        modelContext.insert(entry)
        food.lastUsed = .now
        food.useCount += 1
        try? modelContext.save()
    }

    private func ensureDayLog(for day: Date) -> DayLog {
        if let existing = DayLog.preferredForDay(dayLogs, on: day) {
            return existing
        }
        let new = DayLog(date: day)
        modelContext.insert(new)
        return new
    }

    private func defaultTimestamp(for day: Date) -> Date {
        if Calendar.current.isDateInToday(day) {
            return .now
        }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    private func normalizedSelectedDay(from pickerDate: Date) -> Date {
        // DatePicker(.date) may round-trip through GMT and shift a day for some locales.
        // Read Y/M/D in UTC, then rebuild in local calendar to preserve the user's chosen date.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = utc.dateComponents([.year, .month, .day], from: pickerDate)
        let localDate = Calendar.current.date(from: components) ?? pickerDate
        return Calendar.current.startOfDay(for: localDate)
    }
}

private extension MealType {
    static func quickAddDefaultForCurrentTime(date: Date = .now, calendar: Calendar = .current) -> MealType {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<10:
            return .breakfast
        case 10..<15:
            return .lunch
        case 15..<20:
            return .dinner
        default:
            return .snack
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
