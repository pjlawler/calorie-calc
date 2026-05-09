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
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .textSelection(.enabled)

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

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(inlineMarkdown(text))
                .font(.headline)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.body)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown(text))
                    .font(.body)
            }
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
    }
}

private enum MarkdownBlock {
    case heading(String)
    case paragraph(String)
    case bullet(String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            let joined = paragraphBuffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraphBuffer.removeAll()
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.heading(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraphBuffer.append(line)
            }
        }
        flushParagraph()
        return blocks
    }
}
