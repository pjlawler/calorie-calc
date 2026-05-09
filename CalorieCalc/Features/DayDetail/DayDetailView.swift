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

            dailyStatsPanel(log: dayLog)

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
                if showSteps {
                    stepsSection
                }
            }
        }
        .navigationTitle("Day Details")
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
    }

    @ViewBuilder
    private func dailyStatsPanel(log: DayLog?) -> some View {
        let hkBurn = viewModel?.includedHealthKitActiveEnergy ?? 0
        let manualBurn = log?.totalManualBurned ?? 0
        let totalBurn = Int((hkBurn + manualBurn).rounded())
        let consumed = Int((log?.totalConsumedCalories ?? 0).rounded())
        let isToday = Calendar.current.isDateInToday(date)

        VStack(alignment: .leading, spacing: 8) {
            statRow(label: "Planned", value: dailyPlanned)
            statRow(label: "Consumed (-)", value: consumed)
            macroRow(log: log)
                .padding(.bottom, 8)
            statRow(label: "Burned (+)", value: totalBurn)
            if isToday, let variance = priorDaysVariance {
                statRow(
                    label: "Variance (+)",
                    value: variance,
                    color: variance >= 0 ? .green : .red
                )
            }
            if isToday, let remaining = weeklyRemaining {
                Divider()
                statRow(
                    label: "Remaining",
                    value: remaining,
                    color: remaining >= 0 ? .green : .red
                )
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .padding(.horizontal)
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
            macroBadge(letter: "P", grams: log?.totalProtein ?? 0, color: .red)
            macroBadge(letter: "C", grams: log?.totalCarbs ?? 0, color: .orange)
            macroBadge(letter: "F", grams: log?.totalFat ?? 0, color: .blue)
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
        ForEach(MealType.allCases.sorted { $0.order < $1.order }, id: \.self) { meal in
            MealSectionView(
                mealType: meal,
                entries: log?.entries(for: meal) ?? [],
                onEdit: { entry in editingEntry = entry },
                onDelete: { entry in delete(entry: entry) }
            )
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
        } header: {
            HStack {
                Label("Workouts", systemImage: "figure.run")
                    .font(.headline)
                Spacer()
                Text("\(CalorieFormatter.whole(totalBurned)) kcal")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Reference-only daily step count. Steps are NOT folded into burned-calorie math
    /// (Apple's activeEnergyBurned already accounts for them, so any per-step formula here
    /// would double-count workouts that involve walking).
    @ViewBuilder
    private var stepsSection: some View {
        let steps = Int((viewModel?.dailySteps ?? 0).rounded())
        Section {
            EmptyView()
        } header: {
            HStack {
                Label("Steps", systemImage: "figure.walk")
                    .font(.headline)
                Spacer()
                Text(steps.formatted(.number))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
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
