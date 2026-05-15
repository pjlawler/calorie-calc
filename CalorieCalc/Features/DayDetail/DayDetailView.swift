import SwiftUI
import SwiftData

struct DayDetailView: View {

    let date: Date
    /// Daily gross calorie goal from the user's plan. Shown on the "Planned" row.
    var dailyPlanned: Int = 0
    /// (Σ planned_eat + Σ planned_exercise) − (Σ actual_eaten + Σ actual_exercise) summed
    /// across the prior days of the week. Non-nil only when `date` is today.
    var priorDaysVariance: Int? = nil
    /// Same number rendered in the weekly list's "Remaining" column for today —
    /// `displayMathData.totalVariance`. Non-nil only when `date` is today.
    var weeklyRemaining: Int? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(HealthKitService.self) private var healthKitService
    @Query private var allDayLogs: [DayLog]
    @Query private var profiles: [UserProfile]

    @State private var viewModel: DayDetailViewModel?
    @State private var showAddSheet = false
    @State private var editingEntry: FoodEntry?
    @State private var showManualWorkout = false
    @State private var showSupplementPicker = false
    @AppStorage("settings.showSteps") private var showSteps: Bool = true

    /// All sections start collapsed on every open of the day-detail screen. State is
    /// view-local (not persisted) so leaving and coming back resets the view to a tidy
    /// collapsed state. Adding a new entry auto-expands the relevant section via the
    /// onChange handlers below.
    @State private var collapsedMeals: Set<MealType> = Set(MealType.allCases)
    @State private var workoutsCollapsed: Bool = true
    @State private var summaryCollapsed: Bool = true
    /// Last-observed counts so the onChange handlers can detect *additions* (which
    /// expand the section) and ignore deletions (which leave the user's choice alone).
    @State private var lastFoodCounts: [MealType: Int] = [:]
    @State private var lastManualWorkoutCount: Int = 0

    private var tracksSupplements: Bool { profiles.first?.tracksSupplements ?? false }

    private var dayLog: DayLog? {
        DayLog.preferredForDay(allDayLogs, on: date)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom) {
                Text(date.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Log", systemImage: "plus.circle.fill")
                        .labelStyle(TitleAndIconLabelStyle())
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Log food")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 12)

            List {
                mealsSections(log: dayLog)
                if tracksSupplements {
                    SupplementSectionView(
                        entries: (dayLog?.supplementEntriesList ?? []).sorted { $0.timestamp < $1.timestamp },
                        onAdd: { showSupplementPicker = true },
                        onDelete: { entry in delete(supplement: entry) }
                    )
                }
                workoutsSection(log: dayLog)
                summarySection(log: dayLog)
            }
            .listSectionSpacing(0)
        }
        .navigationTitle("Daily Log")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddSheet) {
            // initialMealType defaults to MealType.quickAddDefaultForCurrentTime() so the
            // meal picker lands on whichever slot matches "now". The user can change it
            // inside the sheet.
            FoodSearchView(date: date)
        }
        .sheet(item: $editingEntry) { entry in
            FoodPortionSheet(editing: entry) { editingEntry = nil }
        }
        .sheet(isPresented: $showManualWorkout) {
            ManualWorkoutSheet(date: date)
        }
        .sheet(isPresented: $showSupplementPicker) {
            SupplementPickerSheet(date: date) { }
        }
        .task {
            if viewModel == nil {
                viewModel = DayDetailViewModel(date: date, healthKitService: healthKitService)
            }
            await viewModel?.refresh()
        }
        .onAppear {
            // Seed last-seen counts so existing entries don't trigger an auto-expand
            // on first paint — only NEW entries logged while this view is open do.
            for meal in MealType.allCases {
                lastFoodCounts[meal] = dayLog?.entries(for: meal).count ?? 0
            }
            lastManualWorkoutCount = dayLog?.manualWorkoutsList.count ?? 0
        }
        .onChange(of: mealEntryCountsSnapshot) { _, newSnapshot in
            for meal in MealType.allCases {
                let newCount = newSnapshot[meal] ?? 0
                let previous = lastFoodCounts[meal] ?? newCount
                if newCount > previous {
                    withAnimation(.snappy) { collapsedMeals.remove(meal) }
                }
                lastFoodCounts[meal] = newCount
            }
        }
        .onChange(of: dayLog?.manualWorkoutsList.count ?? 0) { _, newCount in
            if newCount > lastManualWorkoutCount {
                withAnimation(.snappy) { workoutsCollapsed = false }
            }
            lastManualWorkoutCount = newCount
        }
    }

    /// Per-meal entry counts captured as an Equatable dictionary so `.onChange` can
    /// react to entries being added (or removed). Recomputed each render — cheap because
    /// it's just counting elements.
    private var mealEntryCountsSnapshot: [MealType: Int] {
        var snap: [MealType: Int] = [:]
        for meal in MealType.allCases {
            snap[meal] = dayLog?.entries(for: meal).count ?? 0
        }
        return snap
    }

    /// Summary rows rendered as individual `List` rows (default white background +
    /// row separators) so the section reads consistently with Meals / Workouts above.
    /// No outer card / padding / divider — `List` provides those.
    @ViewBuilder
    private func summarySectionRows(log: DayLog?) -> some View {
        let hkBurn = viewModel?.includedHealthKitActiveEnergy ?? 0
        let manualBurn = log?.totalManualBurned ?? 0
        let totalBurn = Int((hkBurn + manualBurn).rounded())
        let consumed = Int((log?.totalConsumedCalories ?? 0).rounded())
        let isToday = Calendar.current.isDateInToday(date)

        statRow(label: "Planned", value: dailyPlanned)
        // Consumed + its macro breakdown share a single row — the macros are a
        // subpart of the consumed total, not a peer of Burned / Planned.
        VStack(alignment: .leading, spacing: 6) {
            statRow(label: "Consumed (-)", value: consumed)
            macroRow(log: log)
        }
        statRow(label: "Burned (+)", value: totalBurn)
        if isToday, let variance = priorDaysVariance {
            statRow(
                label: "Variance (+)",
                value: variance,
                color: variance >= 0 ? .green : .red
            )
        }
        if isToday, let remaining = weeklyRemaining {
            statRow(
                label: "Remaining",
                value: remaining,
                color: remaining >= 0 ? .green : .red
            )
        }
    }

    private func statRow(label: String, value: Int, color: Color = .primary) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value.formatted(.number)) \(Text("kcal").font(.system(size: 13, weight: .semibold)))")
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .font(.system(size: 17, weight: .semibold))
    }

    /// Single-row macronutrient totals: colored dot + initial + grams. Mirrors the
    /// macro display elsewhere in the app and keeps the day-detail panel terse —
    /// users get the calorie picture above the divider, the macro split below.
    private func macroRow(log: DayLog?) -> some View {
        HStack(spacing: 14) {
            macroBadge(letter: "P", grams: log?.totalProtein ?? 0, color: HistoryMetric.protein.color)
            macroBadge(letter: "C", grams: log?.totalCarbs ?? 0, color: HistoryMetric.carbs.color)
            macroBadge(letter: "F", grams: log?.totalFat ?? 0, color: HistoryMetric.fat.color)
        }
        .padding(.leading, 16)
    }

    private func macroBadge(letter: String, grams: Double, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(letter) \(Int(grams.rounded()))g")
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    @ViewBuilder
    private func mealsSections(log: DayLog?) -> some View {
        let collapsed = collapsedMeals
        let sortedMeals = MealType.allCases.sorted { $0.order < $1.order }
        ForEach(Array(sortedMeals.enumerated()), id: \.element) { idx, meal in
            let entries = log?.entries(for: meal) ?? []
            MealSectionView(
                mealType: meal,
                entries: entries,
                totalProtein: entries.reduce(0) { $0 + $1.totalProtein },
                totalCarbs: entries.reduce(0) { $0 + $1.totalCarbs },
                totalFat: entries.reduce(0) { $0 + $1.totalFat },
                isCollapsed: collapsed.contains(meal),
                showTopDivider: idx > 0,
                onToggleCollapse: { toggleCollapse(meal) },
                onEdit: { entry in editingEntry = entry },
                onDelete: { entry in delete(entry: entry) }
            )
        }
    }

    private func toggleCollapse(_ meal: MealType) {
        if collapsedMeals.contains(meal) {
            collapsedMeals.remove(meal)
        } else {
            collapsedMeals.insert(meal)
        }
    }

    @ViewBuilder
    private func workoutsSection(log: DayLog?) -> some View {
        let hkBurn: Double = {
            guard let vm = viewModel else { return 0 }
            return vm.healthKitWorkouts.isEmpty ? vm.healthKitActiveEnergy : vm.includedHealthKitActiveEnergy
        }()
        let totalBurned = hkBurn + (log?.totalManualBurned ?? 0)
        Section {
            workoutsHeaderRow(totalBurned: totalBurned)
            if !workoutsCollapsed {
                if let vm = viewModel {
                    ForEach(vm.healthKitWorkouts) { workout in
                        HealthKitWorkoutRow(
                            workout: workout,
                            isExcluded: vm.excludedHealthKitWorkoutIDs.contains(workout.id),
                            onToggleExclude: { viewModel?.toggleExclude(workout.id) }
                        )
                    }
                    if vm.healthKitActiveEnergy > 0 && vm.healthKitWorkouts.isEmpty {
                        HStack {
                            Label("Active energy (Health)", systemImage: "heart.fill")
                            Spacer()
                            Text("\(CalorieFormatter.whole(vm.healthKitActiveEnergy)) kcal")
                                .monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    }
                }
                ForEach(log?.manualWorkoutsList ?? []) { workout in
                    ManualWorkoutRow(workout: workout)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(workout: workout) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                Button {
                    showManualWorkout = true
                } label: {
                    Label("Add workout", systemImage: "plus.circle")
                }
            }
        }
    }

    private func workoutsHeaderRow(totalBurned: Double) -> some View {
        Button {
            withAnimation(.snappy) { workoutsCollapsed.toggle() }
        } label: {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(workoutsCollapsed ? 0 : 90))
                    Image(systemName: "figure.run")
                        .font(.headline)
                        .foregroundStyle(totalBurned > 0 ? Color.accentColor : Color.secondary)
                        .frame(width: 22, alignment: .center)
                    HStack(spacing: 4) {
                        Text("Workouts")
                            .font(.headline)
                            .foregroundStyle(totalBurned > 0 ? .primary : .secondary)
                        if showSteps {
                            let steps = Int((viewModel?.dailySteps ?? 0).rounded())
                            Text("(\(steps.formatted(.number)) steps)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(CalorieFormatter.whole(totalBurned)) kcal")
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundStyle(totalBurned > 0 ? .primary : .secondary)
                }
                .padding(.vertical, 14)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func summarySection(log: DayLog?) -> some View {
        Section {
            summaryHeaderRow
            if !summaryCollapsed {
                summarySectionRows(log: log)
            }
        }
    }

    private var summaryHeaderRow: some View {
        Button {
            withAnimation(.snappy) { summaryCollapsed.toggle() }
        } label: {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(summaryCollapsed ? 0 : 90))
                    Image(systemName: "chart.bar.fill")
                        .font(.headline)
                        .foregroundStyle(.tint)
                        .frame(width: 22, alignment: .center)
                    Text("Summary")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 14)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func delete(entry: FoodEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
    }

    private func delete(workout: ManualWorkout) {
        modelContext.delete(workout)
        try? modelContext.save()
    }

    private func delete(supplement: SupplementEntry) {
        modelContext.delete(supplement)
        try? modelContext.save()
    }
}

private struct HealthKitWorkoutRow: View {
    let workout: HealthKitWorkout
    let isExcluded: Bool
    let onToggleExclude: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "heart.fill")
                .foregroundStyle(isExcluded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.displayName)
                    .strikethrough(isExcluded)
                Text("\(Int(workout.duration / 60)) min · Apple Health")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(CalorieFormatter.whole(workout.activeEnergyBurned)) kcal")
                .monospacedDigit()
                .foregroundStyle(isExcluded ? .tertiary : .primary)
            Button {
                onToggleExclude()
            } label: {
                Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(isExcluded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExcluded ? "Include in totals" : "Exclude from totals")
        }
        .font(.subheadline)
    }
}

private struct ManualWorkoutRow: View {
    let workout: ManualWorkout

    var body: some View {
        HStack {
            Image(systemName: "figure.run")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.name)
                Text(DurationFormatter.minutesAndSeconds(workout.durationSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(CalorieFormatter.whole(workout.caloriesBurned)) kcal")
                .monospacedDigit()
        }
        .font(.subheadline)
    }
}
