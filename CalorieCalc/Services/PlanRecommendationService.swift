import DeviceCheck
import Foundation

/// Inputs the user enters in the AI Plan Analyzer. Heights/weights are pre-converted to
/// metric (the BMR formula's native units); `weightUnitSuffix` is carried only so the
/// narrative can speak in the user's display unit.
struct PlanAnalysisInput: Sendable {
    let heightCm: Double
    let weightKg: Double
    let age: Int
    let sex: BiologicalSex
    let activity: NonExerciseActivityLevel
    /// The user's target AVERAGE daily workout burn (kcal). Tracked separately from activity
    /// level — this is deliberate exercise, the activity level is everyday movement.
    let workoutCalorieGoal: Int
    let pace: WeightGoalPace
    let preferencesNote: String
    let weightUnitSuffix: String
    /// The user's current week-start preference, so the model keeps it unless a preference
    /// (e.g. "my weekends are Sat/Sun") clearly calls for a different anchor.
    let currentWeekStart: Weekday
}

/// The AI's recommendation. The three goals + split map straight onto `GoalDraft`; the
/// `estimated*` figures are app-computed (via `TDEECalculator`) and surfaced for transparency,
/// never taken from the model.
struct RecommendedPlan: Sendable {
    let narrative: String
    let dailyNetCalorieGoal: Int
    let dailyGrossCalorieGoal: Int
    let dailyWorkoutCalorieGoal: Int
    let bankSplit: BankSplit
    let weekStart: Weekday
    let notes: String?

    let estimatedBMR: Int
    let estimatedTDEE: Int
    let suggestedNet: Int
}

/// Calls the proxy to turn a `PlanAnalysisInput` into a narrative + structured `RecommendedPlan`.
///
/// Mirrors `NutritionAnalysisService`'s networking (same App Attest headers, 402→credits
/// handling, optimistic decrement) but uses Claude's tool-use to get both prose and machine
/// values back in one call. The deterministic calorie math (BMR/TDEE/suggested net) is computed
/// here with `TDEECalculator` and handed to the model as ground truth — the model chooses the
/// week split and eating goal around it and writes the coaching narrative.
final class PlanRecommendationService: Sendable {

    private let attest: AppAttestService
    private let entitlements: EntitlementService?
    private let model: String
    private let session: URLSession
    private let endpoint: URL

    init(
        proxyBaseURL: URL,
        attest: AppAttestService,
        entitlements: EntitlementService? = nil,
        model: String = AIFlow.planAnalyze.model,
        session: URLSession = .shared
    ) {
        self.attest = attest
        self.entitlements = entitlements
        self.endpoint = proxyBaseURL.appendingPathComponent("v1/messages")
        self.model = model
        self.session = session
    }

    func recommend(_ input: PlanAnalysisInput) async throws -> RecommendedPlan {
        let bmr = TDEECalculator.bmr(sex: input.sex, weightKg: input.weightKg, heightCm: input.heightCm, age: input.age)
        let tdee = TDEECalculator.tdee(bmr: bmr, activity: input.activity)
        let suggestedNet = TDEECalculator.suggestedNet(tdee: tdee, pace: input.pace)
        let paceClamped = suggestedNet > Int((tdee - Double(input.pace.dailyDeficit)).rounded())

        let body = RequestBody(
            model: model,
            maxTokens: 1_536,
            system: systemPrompt,
            messages: [Message(role: "user", content: userPrompt(input: input, bmr: bmr, tdee: tdee, suggestedNet: suggestedNet, paceClamped: paceClamped))],
            tools: [recommendPlanTool],
            toolChoice: ToolChoice(type: "tool", name: "recommend_plan")
        )
        let bodyData = try JSONEncoder().encode(body)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "content-type")
        let attested = try await attest.attestedHeaders(for: bodyData)
        req.addValue(attested.deviceId, forHTTPHeaderField: "X-Device-Id")
        req.addValue(attested.assertion, forHTTPHeaderField: "X-Assertion")
        let installId = InstallIdentity.shared.id
        if !installId.isEmpty {
            req.addValue(installId, forHTTPHeaderField: "X-Install-Id")
        }
        if let skEnv = StoreKitEnvironment.shared.value {
            req.addValue(skEnv, forHTTPHeaderField: "X-StoreKit-Env")
        }
        #if DEBUG
        req.addValue("1", forHTTPHeaderField: "X-Debug-Build")
        #endif
        req.addValue(AIFlow.planAnalyze.rawValue, forHTTPHeaderField: "X-AI-Flow")
        req.httpBody = bodyData

        do {
            let (responseData, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw NutritionAnalysisError.invalidResponse
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw NutritionAnalysisError.missingAPIKey
            }
            if http.statusCode == 402 {
                if let entitlements {
                    await MainActor.run { entitlements.handle402() }
                }
                throw NutritionAnalysisError.outOfCredits
            }
            if http.statusCode == 429 {
                throw NutritionAnalysisError.overQuota("Rate limited — try again in a moment.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: responseData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw NutritionAnalysisError.networkFailure(message)
            }

            if let entitlements {
                await MainActor.run { entitlements.decrementOptimistically() }
            }

            let decoded = try JSONDecoder().decode(ResponseBody.self, from: responseData)
            guard let toolInput = decoded.content.first(where: { $0.type == "tool_use" })?.input else {
                throw NutritionAnalysisError.noResult
            }
            let narrative = toolInput.narrative.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !narrative.isEmpty else { throw NutritionAnalysisError.noResult }

            return RecommendedPlan(
                narrative: narrative,
                dailyNetCalorieGoal: Int(toolInput.daily_net_calorie_goal.rounded()),
                dailyGrossCalorieGoal: Int(toolInput.daily_gross_calorie_goal.rounded()),
                dailyWorkoutCalorieGoal: Int(toolInput.daily_workout_calorie_goal.rounded()),
                bankSplit: Self.parseBankSplit(toolInput.bank_split),
                weekStart: toolInput.week_start.flatMap { Weekday(rawValue: Int($0.rounded())) } ?? input.currentWeekStart,
                notes: toolInput.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                estimatedBMR: Int(bmr.rounded()),
                estimatedTDEE: Int(tdee.rounded()),
                suggestedNet: suggestedNet
            )
        } catch is DecodingError {
            throw NutritionAnalysisError.invalidResponse
        } catch let err as NutritionAnalysisError {
            throw err
        } catch {
            throw NutritionAnalysisError.from(error)
        }
    }

    /// Tolerant mapping of the model's `bank_split` string onto `BankSplit`. Accepts the exact
    /// enum token ("fiveTwo") or a "5/2"-style string; falls back to a balanced 6/1 if the model
    /// returns something unrecognized (`PlanValidator` still guards the final math downstream).
    private static func parseBankSplit(_ raw: String) -> BankSplit {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = BankSplit(rawValue: trimmed) { return exact }
        let digits = trimmed.filter(\.isNumber)
        switch digits {
        case "70": return .sevenZero
        case "61": return .sixOne
        case "52": return .fiveTwo
        case "43": return .fourThree
        case "34": return .threeFour
        default: return .sixOne
        }
    }

    // MARK: - Prompt construction

    private var systemPrompt: String {
        """
        Write the `narrative` and `notes` text in \(AIResponseLanguage.resolvedLanguageName()) \
        (keep every other tool field — numbers and the bank_split / week_start tokens — exactly \
        as specified).

        You're a friendly nutrition coach helping the user set up their calorie plan in this \
        app. Write conversationally — second person ("you"), short sentences, plain English. \
        No clinical jargon, no disclaimers, no "as an AI".

        How this app's plan works — you MUST recommend settings in these exact terms:
          • "Daily net" is the adherence number: calories eaten minus calories burned in \
            workouts. Weight is stable when daily net equals maintenance energy from everyday \
            movement (we give you that number below as TDEE). To lose weight, daily net sits \
            below it.
          • "Workout goal" is the user's target AVERAGE daily burn from deliberate exercise. \
            It's tracked separately from everyday activity, so it is NOT baked into the \
            maintenance number — don't double-count it.
          • "Daily eating goal" is how much to eat on a normal on-plan day.
          • "Week split" lets the user eat less on most days and bank the difference for \
            higher-calorie bonus day(s) — e.g. a 5/2 split is 5 on-plan days + 2 bonus days. \
            Never call these "bank days" — say "bonus day(s)" and "week split".

        The math that must hold (so the plan is consistent):
          weekly allowance = (daily net + workout goal) × 7
          on-plan days spend = on-plan day count × daily eating goal
          each bonus day's net = (daily net × 7 − on-plan days × (eating goal − workout goal)) ÷ bonus day count
        Pick a daily eating goal and split where every bonus day's net stays comfortably above \
        ~1,200 kcal and never negative. For a 7/0 split (no bonus days) the daily eating goal \
        must equal daily net + workout goal.

        Choosing the plan:
          • Use the suggested daily net we give you (it already reflects their pace and is \
            floored for safety). You may nudge it ±100 if their preferences justify it, but \
            don't exceed maintenance for a weight-loss goal.
          • Set the workout goal to the number they gave you.
          • Pick the week split from their preferences: if they like big weekends or social \
            meals, lean toward 5/2 or 4/3; if they prefer the same target every day, use 7/0; \
            6/1 is a gentle default. Then set the daily eating goal so the math above lands.

        Call the recommend_plan tool exactly once with both the structured settings and a \
        `narrative` written in markdown with these two sections, nothing else:

        ## Your plan
        Two short paragraphs. Lead with the headline (their estimated maintenance and the pace \
        you're setting). Then tell them plainly what to set: the daily net, workout goal, week \
        split, and daily eating goal, and what a bonus day will feel like. If their pace was \
        clamped to a safe floor, say so kindly.

        ## Why this works
        Three short markdown bullets, each one sentence, explaining the trade-offs and one \
        concrete habit that will help them hit it.

        Keep the whole narrative under 280 words.
        """
    }

    private func userPrompt(input: PlanAnalysisInput, bmr: Double, tdee: Double, suggestedNet: Int, paceClamped: Bool) -> String {
        var lines: [String] = []
        lines.append("About the user:")
        lines.append("- Sex (for BMR math): \(input.sex.displayName)")
        lines.append("- Age: \(input.age)")
        lines.append("- Height: \(Int(input.heightCm.rounded())) cm")
        lines.append("- Weight: \(input.weightKg.formatted(.number.precision(.fractionLength(1)))) kg (show weights to them in \(input.weightUnitSuffix))")
        lines.append("- Everyday (non-exercise) activity: \(input.activity.displayName) — \(input.activity.detail)")
        lines.append("- Target average daily workout burn: \(input.workoutCalorieGoal) kcal")
        lines.append("- Weight goal pace: \(input.pace.displayName) (\(input.pace.detail))")
        lines.append("- Current week start: \(input.currentWeekStart.fullName)")
        lines.append("")
        lines.append("Calorie math we computed for you (ground truth — do not recompute):")
        lines.append("- BMR: \(Int(bmr.rounded())) kcal")
        lines.append("- Maintenance (TDEE) from everyday activity only: \(Int(tdee.rounded())) kcal — this is the daily-net level for weight maintenance")
        lines.append("- Suggested daily net for their pace (already floored for safety): \(suggestedNet) kcal")
        if paceClamped {
            lines.append("- NOTE: their requested pace was clamped up to this safe floor — going faster would push net too low. Mention this gently.")
        }
        lines.append("")
        let prefs = input.preferencesNote.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Their preferences / anything else they told you:")
        lines.append(prefs.isEmpty ? "(none provided)" : "\"\(prefs)\"")
        lines.append("")
        lines.append("Recommend their plan via the recommend_plan tool, following the system prompt.")
        return lines.joined(separator: "\n")
    }

    private var recommendPlanTool: Tool {
        Tool(
            name: "recommend_plan",
            description: "Submit the recommended calorie-plan settings plus a narrative explaining them.",
            inputSchema: Schema(
                type: "object",
                properties: [
                    "narrative": Property(type: "string", description: "Markdown narrative with the two sections defined in the system prompt. Under 280 words. Never use the term 'bank days' — say 'bonus day(s)'."),
                    "daily_net_calorie_goal": Property(type: "number", description: "Recommended daily NET calorie target (eaten minus workout burn). Usually the suggested net you were given."),
                    "daily_gross_calorie_goal": Property(type: "number", description: "Recommended daily eating goal on a normal on-plan day, chosen so the week split math lands."),
                    "daily_workout_calorie_goal": Property(type: "number", description: "Recommended target average daily workout burn — normally the value the user provided."),
                    "bank_split": Property(type: "string", description: "Week split token: one of sevenZero, sixOne, fiveTwo, fourThree, threeFour (on-plan days / bonus days)."),
                    "week_start": Property(type: "number", description: "Optional. Day the week starts on, 1=Sunday … 7=Saturday. Omit to keep the user's current setting."),
                    "notes": Property(type: "string", description: "Optional short caveat (e.g. assumptions made)."),
                ],
                required: ["narrative", "daily_net_calorie_goal", "daily_gross_calorie_goal", "daily_workout_calorie_goal", "bank_split"]
            )
        )
    }
}

// MARK: - DTOs

private struct RequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]
    let tools: [Tool]
    let toolChoice: ToolChoice

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case tools
        case toolChoice = "tool_choice"
    }
}

private struct Message: Encodable {
    let role: String
    let content: String
}

private struct Tool: Encodable {
    let name: String
    let description: String
    let inputSchema: Schema

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

private struct Schema: Encodable {
    let type: String
    let properties: [String: Property]
    let required: [String]
}

private struct Property: Encodable {
    let type: String
    let description: String?

    init(type: String, description: String? = nil) {
        self.type = type
        self.description = description
    }
}

private struct ToolChoice: Encodable {
    let type: String
    let name: String
}

private struct ResponseBody: Decodable {
    let content: [ResponseContent]
}

private struct ResponseContent: Decodable {
    let type: String
    let input: PlanToolInput?
}

/// Numbers are decoded as `Double` then rounded to `Int` by the caller — models sometimes emit
/// integer values with a trailing `.0`, which a direct `Int` decode would reject.
private struct PlanToolInput: Decodable {
    let narrative: String
    let daily_net_calorie_goal: Double
    let daily_gross_calorie_goal: Double
    let daily_workout_calorie_goal: Double
    let bank_split: String
    let week_start: Double?
    let notes: String?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
