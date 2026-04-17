import SwiftUI
import SwiftData

struct DayDetailView: View {

    let date: Date

    @Environment(\.modelContext) private var modelContext
    @Environment(HealthKitService.self) private var healthKitService
    @Query private var allDayLogs: [DayLog]

    @State private var viewModel: DayDetailViewModel?
    @State private var presentedMealSearch: MealType?
    @State private var showManualWorkout = false

    private var dayLog: DayLog? {
        allDayLogs.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    var body: some View {
        List {
            if let log = dayLog {
                totalsSection(log: log)
                mealsSections(log: log)
                workoutsSection(log: log)
            } else {
                Section {
                    Button {
                        _ = ensureDayLog()
                    } label: {
                        Label("Start logging this day", systemImage: "plus")
                    }
                }
            }
        }
        .navigationTitle(date.formatted(.dateTime.weekday(.wide).month().day()))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentedMealSearch) { meal in
            FoodSearchView(mealType: meal, date: date)
        }
        .sheet(isPresented: $showManualWorkout) {
            ManualWorkoutSheet(date: date)
        }
        .task {
            if viewModel == nil {
                viewModel = DayDetailViewModel(date: date, healthKitService: healthKitService)
            }
            await viewModel?.refresh()
        }
    }

    @ViewBuilder
    private func totalsSection(log: DayLog) -> some View {
        let hkBurn = viewModel?.includedHealthKitActiveEnergy ?? 0
        let manualBurn = log.totalManualBurned
        let totalBurn = hkBurn + manualBurn
        let consumed = log.totalConsumedCalories
        let net = consumed - totalBurn

        Section {
            VStack(spacing: 12) {
                HStack {
                    totalCell(title: "Consumed", value: CalorieFormatter.whole(consumed))
                    Divider().frame(height: 36)
                    totalCell(title: "Burned", value: CalorieFormatter.whole(totalBurn))
                    Divider().frame(height: 36)
                    totalCell(title: "Net", value: CalorieFormatter.signed(net))
                }
                macroRow(log: log)
            }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    private func totalCell(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private func macroRow(log: DayLog) -> some View {
        HStack(spacing: 16) {
            macroPill(label: "P", value: log.totalProtein, tint: .accentColor)
            macroPill(label: "C", value: log.totalCarbs, tint: .orange)
            macroPill(label: "F", value: log.totalFat, tint: .pink)
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
    private func mealsSections(log: DayLog) -> some View {
        ForEach(MealType.allCases.sorted { $0.order < $1.order }, id: \.self) { meal in
            MealSectionView(
                mealType: meal,
                entries: log.entries(for: meal),
                onAdd: { presentedMealSearch = meal },
                onDelete: { entry in delete(entry: entry) }
            )
        }
    }

    @ViewBuilder
    private func workoutsSection(log: DayLog) -> some View {
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
            ForEach(log.manualWorkouts) { workout in
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
            Label("Workouts", systemImage: "figure.run")
                .font(.headline)
        }
    }

    private func ensureDayLog() -> DayLog {
        if let log = dayLog { return log }
        let new = DayLog(date: date)
        modelContext.insert(new)
        try? modelContext.save()
        return new
    }

    private func delete(entry: FoodEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
    }

    private func delete(workout: ManualWorkout) {
        modelContext.delete(workout)
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
