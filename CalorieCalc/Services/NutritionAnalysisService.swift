import Foundation

struct PeriodNutritionData: Sendable {
    let periodLabel: String
    let dayCount: Int
    let totalCalories: Double
    let avgCalories: Double
    let totalProtein: Double
    let avgProtein: Double
    let totalCarbs: Double
    let avgCarbs: Double
    let totalFat: Double
    let avgFat: Double
    let totalExercise: Double
    let avgExercise: Double
    let totalNetCalories: Double
    let avgNetCalories: Double
    let dailyCalorieGoal: Int?
    let dailyNetCalorieGoal: Int?
    let dailyExerciseGoal: Int?
}

enum NutritionAnalysisError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case overQuota(String)
    case networkFailure(String)
    case noResult

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No Claude API key found. Add ANTHROPIC_API_KEY to Secrets.xcconfig."
        case .invalidResponse:
            "Claude returned an unexpected response."
        case .overQuota(let message):
            message
        case .networkFailure(let message):
            "Network error: \(message)"
        case .noResult:
            "Claude didn't return any analysis text."
        }
    }
}

final class NutritionAnalysisService: Sendable {

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(
        apiKey: String? = nil,
        model: String = "claude-sonnet-4-6",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
            ?? (Bundle.main.object(forInfoDictionaryKey: "ANTHROPIC_API_KEY") as? String)
            ?? ""
        self.model = model
        self.session = session
    }

    func analyze(_ data: PeriodNutritionData) async throws -> String {
        guard !apiKey.isEmpty else { throw NutritionAnalysisError.missingAPIKey }

        let body = RequestBody(
            model: model,
            maxTokens: 1024,
            system: systemPrompt,
            messages: [Message(role: "user", content: userPrompt(for: data))]
        )

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.addValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)

        do {
            let (responseData, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw NutritionAnalysisError.invalidResponse
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw NutritionAnalysisError.missingAPIKey
            }
            if http.statusCode == 429 {
                throw NutritionAnalysisError.overQuota("Rate limited — try again in a moment.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: responseData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw NutritionAnalysisError.networkFailure(message)
            }

            let decoded = try JSONDecoder().decode(ResponseBody.self, from: responseData)
            let text = decoded.content
                .compactMap { $0.text }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw NutritionAnalysisError.noResult }
            return text
        } catch is DecodingError {
            throw NutritionAnalysisError.invalidResponse
        } catch let err as NutritionAnalysisError {
            throw err
        } catch {
            throw NutritionAnalysisError.networkFailure(error.localizedDescription)
        }
    }

    // MARK: - Prompt construction

    private var systemPrompt: String {
        """
        You're a friendly nutrition coach talking directly to the user about how their \
        last period went. Write conversationally — second person ("you"), short \
        sentences, plain English. No clinical jargon, no disclaimers, no "as an AI". \
        Don't list raw numbers back at them unless one is genuinely notable.

        Use exactly these two markdown sections, no more:

        ## How you did
        One short paragraph (3–5 sentences) summarizing the period overall. Lead with \
        the headline — e.g. "Solid week" / "Rough week on calories" / "Strong on \
        protein, light on exercise". Mention how intake compared to their goal (if \
        provided) and how exercise factored in. End with one sentence of context on \
        what's driving the picture (carbs heavy? not enough protein? skipped \
        workouts?).

        ## What to try next
        Three short, concrete recommendations as a markdown bulleted list. Each \
        bullet starts with an imperative verb and is one sentence max. Be specific \
        and directive — say what to cut, swap, add, or do, not vague principles. \
        Examples of the style:
        - "Reduce carbs by ~50 g/day — swap one daily snack for protein + veg."
        - "Add a 30-minute walk on Wednesday and Friday to lift your weekly burn."
        - "Bump protein to ~140 g/day — add a Greek yogurt or protein shake at \
          breakfast."

        Always keep the response under 200 words total.
        """
    }

    private func userPrompt(for d: PeriodNutritionData) -> String {
        let proteinKcal = d.totalProtein * 4
        let carbsKcal = d.totalCarbs * 4
        let fatKcal = d.totalFat * 9
        let macroKcal = max(1, proteinKcal + carbsKcal + fatKcal)
        let proteinPct = Int((proteinKcal / macroKcal * 100).rounded())
        let carbsPct = Int((carbsKcal / macroKcal * 100).rounded())
        let fatPct = Int((fatKcal / macroKcal * 100).rounded())

        var lines: [String] = []
        lines.append("Period: \(d.periodLabel) (\(d.dayCount) day\(d.dayCount == 1 ? "" : "s"))")
        lines.append("")
        lines.append("Totals over the period:")
        lines.append("- Calories consumed: \(formatted(d.totalCalories)) kCal (avg \(formatted(d.avgCalories)) kCal/day)")
        lines.append("- Protein: \(formatted(d.totalProtein)) g (avg \(formatted(d.avgProtein)) g/day)")
        lines.append("- Carbs: \(formatted(d.totalCarbs)) g (avg \(formatted(d.avgCarbs)) g/day)")
        lines.append("- Fat: \(formatted(d.totalFat)) g (avg \(formatted(d.avgFat)) g/day)")
        lines.append("- Exercise burn: \(formatted(d.totalExercise)) kCal (avg \(formatted(d.avgExercise)) kCal/day)")
        lines.append("- Net calories (consumed − exercise): \(formatted(d.totalNetCalories)) kCal (avg \(formatted(d.avgNetCalories)) kCal/day)")
        lines.append("")
        lines.append("Macro split by calorie share: protein \(proteinPct)%, carbs \(carbsPct)%, fat \(fatPct)%.")

        if d.dailyCalorieGoal != nil || d.dailyNetCalorieGoal != nil || d.dailyExerciseGoal != nil {
            lines.append("")
            lines.append("User's daily goals:")
            if let g = d.dailyCalorieGoal {
                lines.append("- Calorie intake goal: \(g) kCal/day")
            }
            if let g = d.dailyNetCalorieGoal {
                lines.append("- Net calorie goal: \(g) kCal/day")
            }
            if let g = d.dailyExerciseGoal {
                lines.append("- Exercise goal: \(g) kCal/day")
            }
        }

        lines.append("")
        lines.append("Analyze this period and give your assessment in the format described in the system prompt.")
        return lines.joined(separator: "\n")
    }

    private func formatted(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }
}

// MARK: - DTOs

private struct RequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct Message: Encodable {
    let role: String
    let content: String
}

private struct ResponseBody: Decodable {
    let content: [ResponseContent]
}

private struct ResponseContent: Decodable {
    let type: String
    let text: String?
}
