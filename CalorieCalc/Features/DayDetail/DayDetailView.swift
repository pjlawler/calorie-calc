import SwiftUI
import SwiftData

struct DayDetailView: View {

    let date: Date
    /// When viewing today and provided by the parent week view, the "Today's Variance"
    /// card renders at the top of the day. Nil for any other day or when math hasn't
    /// finished computing yet.
    var currentWeekMathData: MathCardData? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(HealthKitService.self) private var healthKitService
    @Query private var allDayLogs: [DayLog]
    @Query private var profiles: [UserProfile]

    @State private var viewModel: DayDetailViewModel?
    @State private var presentedMealSearch: MealType?
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
            totalsHeader(log: dayLog)
            if let mathData = currentWeekMathData,
               Calendar.current.isDateInToday(date) {
                MathCard(
                    data: mathData,
                    isLastDayOrPast: false,
                    includeRemaining: false
                )
                .padding(.horizontal)
            }
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
        .navigationTitle(date.formatted(.dateTime.weekday(.wide).month().day()))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentedMealSearch) { meal in
            FoodSearchView(mealType: meal, date: date)
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
    private func totalsHeader(log: DayLog?) -> some View {
        let hkBurn = viewModel?.includedHealthKitActiveEnergy ?? 0
        let manualBurn = log?.totalManualBurned ?? 0
        let totalBurn = hkBurn + manualBurn
        let consumed = log?.totalConsumedCalories ?? 0
        let net = consumed - totalBurn
        let roundedNet = net.rounded()
        let netDisplay = roundedNet < 0
            ? "(\(CalorieFormatter.whole(abs(roundedNet))))"
            : CalorieFormatter.whole(roundedNet)

        VStack(spacing: 12) {
            HStack {
                totalCell(title: "Consumed", value: CalorieFormatter.whole(consumed))
                Divider().frame(height: 36)
                totalCell(title: "Burned", value: CalorieFormatter.whole(totalBurn))
                Divider().frame(height: 36)
                totalCell(
                    title: "Net",
                    value: netDisplay,
                    valueColor: roundedNet < 0 ? .red : .primary
                )
            }
            macroRow(
                protein: log?.totalProtein ?? 0,
                carbs: log?.totalCarbs ?? 0,
                fat: log?.totalFat ?? 0
            )
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private func totalCell(title: String, value: String, valueColor: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(valueColor)
        }
        .frame(maxWidth: .infinity)
    }

    private func macroRow(protein: Double, carbs: Double, fat: Double) -> some View {
        HStack(spacing: 16) {
            macroPill(label: "P", value: protein, tint: .accentColor)
            macroPill(label: "C", value: carbs, tint: .orange)
            macroPill(label: "F", value: fat, tint: .pink)
        }
    }

    private func macroPill(label: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text("\(label) \(CalorieFormatter.macro(value))g")
                .font(.footnote.monospacedDigit())
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Capsule().fill(.regularMaterial))
    }

    @ViewBuilder
    private func mealsSections(log: DayLog?) -> some View {
        ForEach(MealType.allCases.sorted { $0.order < $1.order }, id: \.self) { meal in
            MealSectionView(
                mealType: meal,
                entries: log?.entries(for: meal) ?? [],
                onAdd: { presentedMealSearch = meal },
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

    /// Reference-only daily step count. Sits below the Workouts section. Steps are NOT folded
    /// into burned-calorie math (Apple's activeEnergyBurned already accounts for them, so any
    /// per-step formula here would double-count workouts that involve walking).
    @ViewBuilder
    private var stepsSection: some View {
        let steps = Int((viewModel?.dailySteps ?? 0).rounded())
        Section {
            HStack {
                Image(systemName: "figure.walk")
                    .foregroundStyle(.teal)
                Text("Steps")
                Spacer()
                Text(steps.formatted(.number))
                    .monospacedDigit()
            }
            .font(.subheadline)
        } header: {
            Label("Steps", systemImage: "figure.walk")
                .font(.headline)
        } footer: {
            Text("Reference only — Apple Health step count for the day. Doesn't contribute to burned calories.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

extension MealType: Identifiable {
    public var id: String { rawValue }
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
