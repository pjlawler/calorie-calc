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
    @State private var showFavoriteQuickAdd = false

    /// Favourite-bolted foods, hoisted up here from the inner body so the toolbar
    /// can disable its bolt button when there are none. Same query as before; the
    /// quick-add sheet renders these as a one-tap list.
    @Query(
        filter: #Predicate<CachedFood> { $0.isFavorite == true },
        sort: [SortDescriptor(\CachedFood.lastUsed, order: .reverse)]
    )
    private var favoriteFoods: [CachedFood]

    private var currentPeriod: GoalPeriod? { GoalPeriod.current(in: goalPeriods) }
    private func period(for date: Date) -> GoalPeriod? {
        GoalPeriod.period(covering: date, in: goalPeriods)
    }

    /// Single source of truth for which weekday anchors the visible 7-day window. Always the
    /// *current* setting, so changing weekStart re-anchors every historical week the user
    /// scrolls back to (same range as the header + same banking-day layout in cells).
    private var displayWeekStart: Weekday {
        currentPeriod?.weekStart ?? profiles.first?.weekStart ?? .monday
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
                .sheet(isPresented: $showFavoriteQuickAdd) {
                    FavoriteQuickAddListSheet(favorites: favoriteFoods)
                }
                .task { await ensureBootstrap() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel,
           let current = currentPeriod,
           let weekPeriod = period(for: vm.referenceDate) {
            let ws = displayWeekStart
            let calculation = vm.calculation(period: weekPeriod, weekStart: ws, dayLogs: dayLogs)
            WeekCalendarBody(
                period: weekPeriod,
                currentPeriod: current,
                calculation: calculation,
                dayLogs: dayLogs,
                selectedDate: $selectedDate,
                viewModel: vm
            )
            .task(id: vm.referenceDate) { await vm.refreshHealthKit(for: weekPeriod, weekStart: ws) }
            .refreshable { await vm.refreshHealthKit(for: weekPeriod, weekStart: ws) }
        } else {
            ProgressView().controlSize(.large)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // Leading-side jump button balances the gear icon on the trailing side
            // when the user has navigated away from the current week. Putting it
            // here (vs. trailing) keeps the principal date selector centred —
            // a single button on each side gives the principal equal margins.
            if showCurrentWeekButton {
                Button {
                    viewModel?.jumpToCurrentWeek()
                } label: {
                    Image(systemName: "calendar.badge.clock")
                }
                .accessibilityLabel("Jump to current week")
            }
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Button { viewModel?.shiftWeek(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous week")

                Button { viewModel?.jumpToCurrentWeek() } label: {
                    if let reference = viewModel?.referenceDate {
                        WeekRangeLabel(date: reference, weekStart: displayWeekStart)
                    }
                }
                .buttonStyle(.plain)

                Button { viewModel?.shiftWeek(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next week")
            }
        }
        // Orange filled bolt — same visual treatment as the favourite/My Staples bolt
        // used everywhere else in the app, so the entry point reads as the same concept.
        // Disabled when there are no favourites so the button doesn't open an empty sheet.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showFavoriteQuickAdd = true
            } label: {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.orange)
            }
            .disabled(favoriteFoods.isEmpty)
            .accessibilityLabel("My Staples")
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
        let dates = vm.assembler(for: current, weekStart: displayWeekStart).weekDates
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

    /// Last `MathCardData` we computed against fully-loaded HealthKit burns. Carried over
    /// while a new week is fetching so the hero number can smoothly animate from the
    /// previous week's value to the new one instead of flashing through `—`.
    @State private var stableMathData: MathCardData?
    @State private var showAddSheet = false

    private var weekDates: [Date] {
        viewModel.assembler(for: period, weekStart: currentPeriod.weekStart).weekDates
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 12) {
                Color.clear.frame(height: 0).id("top")
                HStack(alignment: .bottom) {
                    Text("CalorieCalc")
                        .font(.largeTitle.bold())
                    Spacer()
                    // Same "Log" button as the day-detail screen. Opens to today's log and the
                    // time-of-day-appropriate meal (FoodSearchView defaults its meal slot).
                    LogFoodButton { showAddSheet = true }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 8) {
                    DayCellHeader()
                    ForEach(Array(zip(weekDates, calculation.dailyBudgets)), id: \.0) { date, budget in
                        Button { selectedDate = date } label: {
                            DayCellView(
                                date: date,
                                budget: budget,
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
        // `.always` (not `.basedOnSize`) so the ScrollView bounces even when the
        // week's content fits in the viewport. Pull-to-refresh on the parent
        // .refreshable needs the bounce to trigger, so without this the gesture
        // does nothing on short weeks.
        .scrollBounceBehavior(.always)
        .navigationDestination(item: $selectedDate) { date in
            let isToday = Calendar.current.isDateInToday(date)
            // Per-day plan, NOT the global bank-day goal: bonus days have a higher planned
            // gross than `period.dailyGrossCalorieGoal`. Fall back to the bank-day goal only
            // when the budget didn't compute one (past off-days with no logged data).
            let budget = zip(weekDates, calculation.dailyBudgets)
                .first { Calendar.current.isDate($0.0, inSameDayAs: date) }?.1
            let plannedForDay = Int((budget?.grossBudget ?? Double(period.dailyGrossCalorieGoal)).rounded())
            DayDetailView(
                date: date,
                dailyPlanned: plannedForDay,
                priorDaysVariance: isToday ? priorDaysVariance : nil,
                weeklyRemaining: isToday ? displayMathData.totalVariance : nil
            )
        }
        .sheet(isPresented: $showAddSheet) {
            // Same sheet as the day-detail "Log" button — seeded to today, date changeable inside.
            FoodSearchView(date: Calendar.current.startOfDay(for: .now))
        }
        .onAppear { captureStableData() }
        .onChange(of: mathCardData) { _, _ in captureStableData() }
        .onChange(of: isHealthBurnLoaded) { _, _ in captureStableData() }
        .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { _ in
            selectedDate = nil
            withAnimation { proxy.scrollTo("top", anchor: .top) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToCurrentWeek)) { _ in
            viewModel.jumpToCurrentWeek()
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

    /// Day-detail "Variance" — how prior-day plan adherence is tracking.
    ///
    /// Variance = (Σ priorPlannedEat − Σ priorActualEat)
    ///          + (Σ priorActualBurn − Σ priorPlannedExercise)
    ///          − todayPlannedExercise
    ///
    /// The trailing `− todayPlannedExercise` ties this number to the parent week's
    /// `totalVariance` (used as Remaining) so that Remaining = todayPlanned −
    /// todayConsumed + todayBurned + Variance holds.
    private var priorDaysVariance: Int {
        let priorDays = nonFutureBudgets.filter { $0.status == .past }
        let priorPlannedEat = priorDays.reduce(0.0) { acc, day in
            acc + (day.grossBudget ?? Double(period.dailyGrossCalorieGoal))
        }
        let priorActualEat = priorDays.reduce(0.0) { $0 + $1.consumed }
        let priorPlannedExercise = Double(priorDays.count * period.dailyWorkoutCalorieGoal)
        let priorActualBurn = priorDays.reduce(0.0) { $0 + $1.burned }
        let todayPlannedExercise = Double(period.dailyWorkoutCalorieGoal)
        let value = (priorPlannedEat - priorActualEat)
                  + (priorActualBurn - priorPlannedExercise)
                  - todayPlannedExercise
        return Int(value.rounded())
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
}

private struct FavoriteQuickAddListSheet: View {
    let favorites: [CachedFood]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var dayLogs: [DayLog]
    @Query(sort: \FoodTag.name) private var allTags: [FoodTag]

    @State private var selectedMeal: MealType = MealType.quickAddDefaultForCurrentTime()
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var searchText: String = ""
    @State private var selectedTagIds: Set<UUID> = []
    @State private var sheetTab: SheetTab = .quickAdd

    private enum SheetTab: String, CaseIterable, Hashable {
        case quickAdd = "My Staples"
        case manual = "Quick Add"
    }

    private var sortedFavorites: [CachedFood] {
        let base = favorites
            .filter { matchesTagFilter($0) }
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                let lb = lhs.brand ?? ""
                let rb = rhs.brand ?? ""
                return lb.localizedCaseInsensitiveCompare(rb) == .orderedAscending
            }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base.filter { food in
            food.name.localizedCaseInsensitiveContains(trimmed)
                || (food.brand?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    /// AND semantics: a favorite passes only if it carries every selected tag id.
    /// Mirrors the filter logic in FoodsView / FoodSearchView for consistency.
    private func matchesTagFilter(_ food: CachedFood) -> Bool {
        guard !selectedTagIds.isEmpty else { return true }
        let foodTagIds = Set(food.tagsList.map(\.id))
        return selectedTagIds.isSubset(of: foodTagIds)
    }

    /// Total kcal for the food at its favourite-preset serving (or last-used, or 1
    /// native unit if neither exists). `caloriesPerServing` on `CachedFood` is the
    /// per-native value (per-gram, per-batch, etc.), so a 0.4-batch pancake row was
    /// previously rendering 1,010 — the per-batch number — instead of 404.
    /// Matches the unit/quantity used by `addFavoriteToLog` below so the row total
    /// and the logged entry agree.
    private func favoriteCalories(_ food: CachedFood) -> Double {
        let unit = food.favoriteSelectedUnit ?? food.lastSelectedUnit ?? food.nativeUnit
        let qty = food.favoriteSelectedQuantity ?? food.lastSelectedQuantity ?? 1
        let factor = ServingMath.nativeUnitsConsumed(
            selectedUnit: unit,
            quantity: qty,
            nativeUnit: food.nativeUnit,
            nativeUnitGrams: food.nativeUnitGrams,
            nativeUnitMilliliters: food.nativeUnitMilliliters
        )
        return food.caloriesPerServing * factor
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                metadataHeader

                Picker("Mode", selection: $sheetTab) {
                    ForEach(SheetTab.allCases, id: \.self) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 8)

                Group {
                    switch sheetTab {
                    case .quickAdd:
                        quickAddList
                    case .manual:
                        QuickMacroEntryForm(
                            mealType: selectedMeal,
                            date: normalizedSelectedDay(from: selectedDate),
                            onSaved: { dismiss() }
                        )
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                // Custom principal title: bolt + "My Staples". `navigationTitle`
                // can't render an SF Symbol inline, so we replace the title with
                // a labelled HStack here.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.orange)
                        Text("My Staples")
                            .font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("My Staples")
                }
            }
        }
    }

    /// Persistent "Add to" controls displayed above the tab picker so both Quick Add
    /// and Manual Entry log against the same meal + date selection. Compact inline
    /// pickers — the menu/datepicker pair takes one row instead of a Form section.
    private var metadataHeader: some View {
        HStack {
            Menu {
                Picker("Meal", selection: $selectedMeal) {
                    ForEach(MealType.allCases.sorted(by: { $0.order < $1.order }), id: \.self) { meal in
                        Label(meal.displayName, systemImage: meal.symbolName).tag(meal)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Add to \(selectedMeal.displayName)")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }

            Spacer()

            DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                .labelsHidden()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// The original Quick Add list — search, tag filter, and the favourites list.
    /// Pulled out so the manual-entry tab can swap in `QuickAddForm` cleanly.
    private var quickAddList: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search My Staples", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !allTags.isEmpty {
                Section("Filter by tag") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(allTags) { tag in
                                Button {
                                    if selectedTagIds.contains(tag.id) {
                                        selectedTagIds.remove(tag.id)
                                    } else {
                                        selectedTagIds.insert(tag.id)
                                    }
                                } label: {
                                    TagChipView(name: tag.name, color: tag.color, isSelected: selectedTagIds.contains(tag.id))
                                }
                                .buttonStyle(.plain)
                            }
                            if !selectedTagIds.isEmpty {
                                Button { selectedTagIds.removeAll() } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "xmark.circle.fill")
                                        Text("Clear")
                                    }
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }

            Section("My Staples") {
                if sortedFavorites.isEmpty {
                    Text(selectedTagIds.isEmpty
                        ? "Nothing in My Staples yet."
                        : "Nothing in My Staples matches the selected tags.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedFavorites, id: \.id) { favorite in
                        Button {
                            addFavoriteToLog(favorite)
                            dismiss()
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(favorite.name)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
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
                                Text("\(CalorieFormatter.whole(favoriteCalories(favorite))) kcal")
                                    .font(.subheadline.monospacedDigit())
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
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

/// Lightweight macro-only entry form used inside the Calc tab's Quick Add sheet.
/// Unlike `QuickAddForm` this does NOT collect a name/brand/serving, does NOT create
/// a `CachedFood`, and so does NOT appear in Recents or My Foods. Every entry from
/// this form is logged as "Quick Add Entry" — a transient way to add macros to a meal
/// when the user doesn't want to invent a name for the food.
private struct QuickMacroEntryForm: View {
    let mealType: MealType
    let date: Date
    let onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var dayLogs: [DayLog]

    @State private var caloriesText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var notesText: String = ""

    private var calories: Double? { Double(caloriesText) }
    private var canSave: Bool {
        guard let cals = calories, cals > 0 else { return false }
        return true
    }

    var body: some View {
        Form {
            Section("Nutrition") {
                macroField(label: "Calories", text: $caloriesText, suffix: "kcal")
                macroField(label: "Protein", text: $proteinText, suffix: "g")
                macroField(label: "Carbs", text: $carbsText, suffix: "g")
                macroField(label: "Fat", text: $fatText, suffix: "g")
            }

            Section("Notes") {
                TextField("Add notes — what this was for, source, etc.", text: $notesText, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section {
                Button {
                    save()
                } label: {
                    Text("Add to \(mealType.displayName)")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSave)
            }
        }
    }

    private func macroField(label: String, text: Binding<String>, suffix: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 100)
            Text(suffix)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func save() {
        guard let cals = calories, cals > 0 else { return }
        let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let log = ensureDayLog()
        let entry = FoodEntry(
            name: "Quick Add Entry",
            nativeUnit: "ea",
            selectedUnit: "ea",
            quantity: 1,
            caloriesPerServing: cals,
            proteinPerServing: Double(proteinText) ?? 0,
            carbsPerServing: Double(carbsText) ?? 0,
            fatPerServing: Double(fatText) ?? 0,
            mealType: mealType,
            source: .manual,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            timestamp: defaultTimestamp(),
            dayLog: log
        )
        modelContext.insert(entry)
        try? modelContext.save()
        onSaved()
    }

    private func ensureDayLog() -> DayLog {
        if let existing = DayLog.preferredForDay(dayLogs, on: date) {
            return existing
        }
        let new = DayLog(date: date)
        modelContext.insert(new)
        return new
    }

    private func defaultTimestamp() -> Date {
        if Calendar.current.isDateInToday(date) {
            return .now
        }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }
}
