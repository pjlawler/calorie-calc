import SwiftUI
import SwiftData

/// "Ask about my plan" — the user types a free-form question (e.g. "how can I lose another pound
/// a week?") and Claude answers it grounded in their CURRENT plan and all progress logged since
/// that plan took effect. Unlike the Progress-tab Analyze button, this ignores any timeframe
/// selection: it always looks at the current plan window (see `PlanProgressGatherer`), because
/// data from before the current plan is irrelevant to a question about the current plan.
struct PlanQuestionSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(NutritionAnalysisEnvironment.self) private var env
    @Environment(AIConsentService.self) private var aiConsent
    @Environment(HealthKitService.self) private var healthKit

    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \GoalPeriod.startDate) private var goalPeriods: [GoalPeriod]
    @Query(sort: \DayLog.date) private var dayLogs: [DayLog]
    @Query(sort: \WeightEntry.timestamp) private var weightEntries: [WeightEntry]

    @State private var question = ""
    @State private var phase: Phase = .input
    @State private var showConsent = false
    @State private var showPaywall = false
    @State private var pendingQuestion: String?

    private enum Phase {
        case input
        case loading
        case answer(String)
        case failed(String)
    }

    private let examples = [
        "Why am I not losing weight as fast as I expected?",
        "How can I lose another ½ lb per week?",
        "Is my calorie target too aggressive?",
        "Am I eating too much on my bonus days?"
    ]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Ask about my plan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                    if case .answer = phase {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                phase = .input
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .accessibilityLabel("Ask another question")
                        }
                    }
                }
                .sheet(isPresented: $showConsent, onDismiss: { pendingQuestion = nil }) {
                    AIConsentSheet(onAllow: {
                        if let q = pendingQuestion { runAsk(q) }
                        pendingQuestion = nil
                    })
                }
                .sheet(isPresented: $showPaywall) { PaywallSheet() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .input:
            inputForm
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Claude is reviewing your plan…")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .answer(let text):
            answerView(text)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("Couldn't answer that", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try again") { ask() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var inputForm: some View {
        Form {
            Section {
                TextField("e.g. How can I lose another pound a week?", text: $question, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("Your question")
            } footer: {
                Text("Claude looks at your current plan and everything you've logged since it started — calories, exercise, and weight trend — to answer.")
            }

            Section("Examples") {
                ForEach(examples, id: \.self) { example in
                    Button {
                        question = example
                        ask()
                    } label: {
                        Text(example)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button {
                    ask()
                } label: {
                    Label("Ask", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func answerView(_ text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(question)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                MarkdownText(text: text)

                medicalDisclaimer
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var medicalDisclaimer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("This is AI-generated guidance and doesn't account for any medical conditions that limiting your calories or setting a workout goal could affect. Talk to your primary care provider before starting any significant change to your diet or fitness routine.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
    }

    private func ask() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if aiConsent.isGranted {
            runAsk(trimmed)
        } else {
            pendingQuestion = trimmed
            showConsent = true
        }
    }

    private func runAsk(_ trimmed: String) {
        guard let profile = profiles.first else { return }
        phase = .loading
        Task {
            let data = await PlanProgressGatherer.currentPlanData(
                profile: profile,
                goalPeriods: goalPeriods,
                dayLogs: dayLogs,
                weightEntries: weightEntries,
                healthKit: healthKit
            )
            do {
                let text = try await env.service.answer(question: trimmed, data)
                phase = .answer(text)
            } catch NutritionAnalysisError.outOfCredits {
                phase = .input
                showPaywall = true
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}
