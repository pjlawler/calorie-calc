import SwiftUI
import SwiftData

struct DashboardView: View {

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: [SortDescriptor(\WeightEntry.timestamp, order: .reverse)]) private var weightEntries: [WeightEntry]

    @State private var showWeightSheet = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let profile = profiles.first {
                        weightCard(profile: profile)
                        netAverageCard(profile: profile)
                        planCard(profile: profile)
                    } else {
                        ProgressView().padding(.top, 80)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Dashboard")
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

    private func weightCard(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("CURRENT WEIGHT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let latest = weightEntries.first {
                    Text(latest.weight(in: profile.weightUnit).formatted(.number.precision(.fractionLength(0...1))))
                        .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                    Text(profile.weightUnit.suffix)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }

            trendRow(profile: profile)
            goalRow(profile: profile)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [.accentColor.opacity(0.22), .accentColor.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func trendRow(profile: UserProfile) -> some View {
        if let latest = weightEntries.first, let starting = profile.startingWeight {
            let current = latest.weight(in: profile.weightUnit)
            let delta = current - starting
            HStack(spacing: 6) {
                Image(systemName: delta > 0 ? "arrow.up.right" : (delta < 0 ? "arrow.down.right" : "minus"))
                Text("\(CalorieFormatter.macro(abs(delta))) \(profile.weightUnit.suffix) from start (\(CalorieFormatter.weight(starting, unit: profile.weightUnit)))")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func goalRow(profile: UserProfile) -> some View {
        if let goal = profile.goalWeight {
            let remaining: Double? = weightEntries.first.map { latest in
                abs(latest.weight(in: profile.weightUnit) - goal)
            }
            HStack(spacing: 6) {
                Image(systemName: "flag.checkered")
                Text("Goal: \(CalorieFormatter.weight(goal, unit: profile.weightUnit))")
                if let remaining {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(CalorieFormatter.macro(remaining)) \(profile.weightUnit.suffix) to go")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "flag.checkered")
                Text("Set a goal weight in Settings")
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
        }
    }

    private func netAverageCard(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DAILY NET AVERAGE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(profile.dailyNetCalorieGoal.formatted())
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                Text("kcal")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text("Weekly target \(profile.dailyNetCalorieGoal * 7) kcal")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private func planCard(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR PLAN")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            planRow(label: "Plan-day gross", value: "\(profile.dailyGrossCalorieGoal) kcal")
            planRow(label: "Workout goal", value: "\(profile.dailyWorkoutCalorieGoal) kcal/day")
            planRow(label: "Week split", value: profile.bankSplit.displayName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
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

    private func ensureProfile() async {
        if profiles.isEmpty {
            modelContext.insert(UserProfile())
            try? modelContext.save()
        }
    }
}
