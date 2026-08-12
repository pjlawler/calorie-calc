import SwiftUI

/// Step 2 — the numbers the calorie math actually needs. Mirrors the AI Plan Analyzer's input
/// form field-for-field (same controls, same ranges, same footers) so a user who later opens
/// Settings → Build my plan with AI is looking at a form they've already seen.
struct OnboardingProfileStep: View {

    @Bindable var state: OnboardingState
    let onContinue: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Units", selection: $state.weightUnit) {
                    ForEach(WeightUnit.allCases, id: \.self) { unit in
                        Text(unit.systemName).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("About you")
            } footer: {
                Text("Sex and age are used only to estimate your calorie needs.")
            }

            Section {
                Picker("Sex", selection: $state.sex) {
                    Text("Select").tag(BiologicalSex?.none)
                    ForEach(BiologicalSex.allCases) { s in
                        Text(s.displayName).tag(BiologicalSex?.some(s))
                    }
                }
                Stepper(value: $state.age, in: 13...100) {
                    LabeledContent("Age") { Text("\(state.age)").monospacedDigit() }
                }
                if state.isMetric {
                    Stepper(value: $state.heightCm, in: 120...230, step: 1) {
                        LabeledContent("Height") {
                            Text("\(Int(state.heightCm)) cm").monospacedDigit()
                        }
                    }
                } else {
                    Stepper(value: $state.heightTotalInches, in: 48...96) {
                        LabeledContent("Height (\(state.heightTotalInches / 12)' \(state.heightTotalInches % 12)\")") {
                            Text("\(state.heightTotalInches)\"").monospacedDigit()
                        }
                    }
                }
                Stepper(value: $state.weight, in: weightRange, step: state.isMetric ? 0.5 : 1) {
                    LabeledContent("Current weight") {
                        Text(weightText(state.weight)).monospacedDigit()
                    }
                }
            }

            if state.pace != .maintain {
                Section {
                    Stepper(value: $state.goalWeight, in: goalWeightRange, step: state.isMetric ? 0.5 : 1) {
                        LabeledContent("Goal weight") {
                            Text(state.goalWeight > 0 ? weightText(state.goalWeight) : "Not set")
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Goal weight")
                } footer: {
                    Text("Optional. Used by the Progress tab to chart how far along you are.")
                }
            }

            Section {
                Picker("Daily activity", selection: $state.activity) {
                    ForEach(NonExerciseActivityLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Text(state.activity.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Everyday activity")
            } footer: {
                Text("How much you move during a normal day — NOT your workouts. An office job is still “Sedentary” even if you exercise.")
            }

            Section {
                Stepper(value: $state.workoutGoal, in: 0...3000, step: 25) {
                    LabeledContent("Workout goal") {
                        Text("\(state.workoutGoal) kcal/day").monospacedDigit()
                    }
                }
            } header: {
                Text("Workout goal")
            } footer: {
                Text("Your target average daily burn from deliberate exercise. Leave it at 0 if you're not tracking workouts yet.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                onContinue()
            } label: {
                Text("See my plan")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!state.profileIsComplete)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .onChange(of: state.weightUnit) { old, new in
            // Convert in place so switching systems doesn't reinterpret 170 lb as 170 kg.
            state.weight = old.convert(state.weight, to: new)
            if state.goalWeight > 0 { state.goalWeight = old.convert(state.goalWeight, to: new) }
        }
    }

    private var weightRange: ClosedRange<Double> {
        state.isMetric ? 35...250 : 70...550
    }

    /// Starts at 0 ("Not set") so the stepper can express "no goal weight" without a separate
    /// toggle; the flow only persists it when it's above zero.
    private var goalWeightRange: ClosedRange<Double> {
        state.isMetric ? 0...250 : 0...550
    }

    private func weightText(_ value: Double) -> String {
        let precision = state.isMetric ? 1 : 0
        return "\(value.formatted(.number.precision(.fractionLength(precision)))) \(state.weightUnit.suffix)"
    }
}
