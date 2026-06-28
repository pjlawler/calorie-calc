import SwiftUI

struct NutritionAnalysisSheet: View {

    let data: PeriodNutritionData

    @Environment(\.dismiss) private var dismiss
    @Environment(NutritionAnalysisEnvironment.self) private var env
    @State private var phase: Phase = .loading
    @State private var hasStarted = false
    @State private var showPaywall = false

    private enum Phase {
        case loading
        case ready(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(data.periodLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    content
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Period Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        runAnalysis()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Re-run analysis")
                    .disabled(isLoading)
                }
            }
            .sheet(isPresented: $showPaywall) { PaywallSheet() }
        }
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            await analyze()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Claude is analyzing this period…")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)

        case .ready(let text):
            MarkdownText(text: text)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't generate analysis", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try again") { runAnalysis() }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    private func runAnalysis() {
        Task { await analyze() }
    }

    private func analyze() async {
        phase = .loading
        do {
            let text = try await env.service.analyze(data)
            phase = .ready(text)
        } catch NutritionAnalysisError.outOfCredits {
            phase = .failed(NutritionAnalysisError.outOfCredits.localizedDescription)
            showPaywall = true
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
