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
            .task(id: vm.referenceDate) { await vm.refreshHealthKit(for: weekPeriod) }
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
    /// Last `MathCardData` we computed against fully-loaded HealthKit burns. Carried over
    /// while a new week is fetching so the hero number can smoothly animate from the
    /// previous week's value to the new one instead of flashing through `—`.
    @State private var stableMathData: MathCardData?

    private var weekDates: [Date] { viewModel.assembler(for: period).weekDates }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 12) {
                Color.clear.frame(height: 0).id("top")
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
                                workoutGoal: period.dailyWorkoutCalorieGoal,
                                varianceValue: budget.status == .today ? displayMathData.totalVariance : nil
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
        .navigationDestination(item: $selectedDate) { date in
            DayDetailView(
                date: date,
                currentWeekMathData: Calendar.current.isDateInToday(date) ? displayMathData : nil
            )
        }
        .onAppear { captureStableData() }
        .onChange(of: mathCardData) { _, _ in captureStableData() }
        .onChange(of: isHealthBurnLoaded) { _, _ in captureStableData() }
        .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { _ in
            withAnimation { proxy.scrollTo("top", anchor: .top) }
        }
        }
    }

    private var weeklySummary: some View {
        MathCard(
            data: displayMathData,
            isLastDayOrPast: isLastDayOrPast,
            isLoading: showLoadingPlaceholder,
            includeVariance: false
        )
        .padding(.top, 4)
        .animation(.easeInOut(duration: 0.25), value: displayMathData)
    }

    /// What we hand to MathCard. While HK is mid-fetch for the new week, fall back to the
    /// last week we successfully calculated — keeps the hero stable instead of jumping to
    /// nonsense values that would briefly compute from missing burn data.
    private var displayMathData: MathCardData {
        if isHealthBurnLoaded { return mathCardData }
        return stableMathData ?? mathCardData
    }

    /// Only redact on the very first launch where we have no prior value to fall back to.
    /// After that, week shifts cross-fade between known-good values.
    private var showLoadingPlaceholder: Bool {
        !isHealthBurnLoaded && stableMathData == nil
    }

    private func captureStableData() {
        guard isHealthBurnLoaded else { return }
        stableMathData = mathCardData
    }

    /// `true` once `viewModel.healthKitBurn` contains an entry for every day of the
    /// currently visible week. Re-visiting a previously loaded week reads from the cache
    /// and stays `true`, so navigation back to a known week is instant.
    private var isHealthBurnLoaded: Bool {
        let calendar = Calendar.current
        let normalized = weekDates.map { calendar.startOfDay(for: $0) }
        return normalized.allSatisfy { viewModel.healthKitBurn.keys.contains($0) }
    }

    /// True when the visible week has no future days — i.e. today is the last day,
    /// or the entire week has already finished.
    private var isLastDayOrPast: Bool {
        guard let lastStatus = calculation.dailyBudgets.last?.status else { return false }
        return lastStatus != .future
    }

    private var nonFutureBudgets: ArraySlice<DailyBudget> {
        calculation.dailyBudgets.prefix { $0.status != .future }
    }

    private var futureBudgets: [DailyBudget] {
        calculation.dailyBudgets.filter { $0.status == .future }
    }

    private var eatenThisWeek: Double {
        nonFutureBudgets.reduce(0) { $0 + $1.consumed }
    }

    private var workoutsCompleted: Double {
        nonFutureBudgets.reduce(0) { $0 + $1.burned }
    }

    private var mathCardData: MathCardData {
        // Sum each day's actual gross goal so bonus days (which have a higher gross budget than
        // bank days) contribute their real value to the running "should have eaten by now"
        // figure. Multiplying nonFutureBudgets.count by dailyGrossCalorieGoal would treat every
        // day like a bank day and under-count the goal on bonus-day weeks.
        let consumeGoalSoFar = nonFutureBudgets.reduce(0.0) { acc, day in
            acc + (day.grossBudget ?? Double(period.dailyGrossCalorieGoal))
        }
        return MathCardData(
            weeklyCalorieBudget: Int(calculation.weeklyNetTarget.rounded()),
            alreadyEatenThisWeek: Int(eatenThisWeek.rounded()),
            workoutsCompleted: Int(workoutsCompleted.rounded()),
            plannedToWorkout: futureBudgets.count * period.dailyWorkoutCalorieGoal,
            exerciseGoalSoFar: nonFutureBudgets.count * period.dailyWorkoutCalorieGoal,
            consumeGoalSoFar: Int(consumeGoalSoFar.rounded()),
            dailyGrossGoal: period.dailyGrossCalorieGoal,
            remainingDays: futureBudgets.count
        )
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

    private var sortedFavorites: [CachedFood] {
        favorites.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let lb = lhs.brand ?? ""
            let rb = rhs.brand ?? ""
            return lb.localizedCaseInsensitiveCompare(rb) == .orderedAscending
        }
    }

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
                    if sortedFavorites.isEmpty {
                        Text("No favorites yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedFavorites, id: \.id) { favorite in
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
                                            Text(favorite.rowCaption).lineLimit(1)
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

        // Quick-add from favorites uses the favorite preset when present, else last-used, else
        // 1 native unit.
        let initialUnit = food.favoriteSelectedUnit ?? food.lastSelectedUnit ?? food.nativeUnit
        let initialQty = food.favoriteSelectedQuantity ?? food.lastSelectedQuantity ?? 1
        let entry = FoodEntry(
            name: food.name,
            brand: food.brand,
            nativeUnit: food.nativeUnit,
            nativeUnitGrams: food.nativeUnitGrams,
            nativeUnitMilliliters: food.nativeUnitMilliliters,
            selectedUnit: initialUnit,
            quantity: initialQty,
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

extension MealType {
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
