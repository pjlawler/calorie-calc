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
    /// Weight log entries the AI uses to estimate trend. Already converted to the
    /// user's display unit (`weightUnitSuffix`). Chronologically ascending. The
    /// window typically extends ~60 days before the analysis period start so the
    /// AI can comment on trend even when the period itself is short.
    let weightSamples: [WeightSample]
    let weightUnitSuffix: String
    let goalWeight: Double?
    /// Number of days the workout history covers — passed so the AI can judge
    /// exercise consistency (daily vs. spotty) honestly against the period length.
    let exerciseDayCount: Int
}

struct WeightSample: Sendable {
    let date: Date
    let weight: Double
}

enum NutritionAnalysisError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case overQuota(String)
    case networkFailure(String)
    case noResult
    case outOfCredits

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "AI features are unavailable on this device right now. Please try again later."
        case .invalidResponse:
            "Claude returned an unexpected response."
        case .overQuota(let message):
            message
        case .networkFailure(let message):
            "Network error: \(message)"
        case .noResult:
            "Claude didn't return any analysis text."
        case .outOfCredits:
            "Out of AI credits. Watch a short ad to earn more, or upgrade for unlimited."
        }
    }
}

final class NutritionAnalysisService: Sendable {

    private let attest: AppAttestService
    private let entitlements: EntitlementService?
    private let model: String
    private let session: URLSession
    private let endpoint: URL

    init(
        proxyBaseURL: URL,
        attest: AppAttestService,
        entitlements: EntitlementService? = nil,
        model: String = AIFlow.insights.model,
        session: URLSession = .shared
    ) {
        self.attest = attest
        self.entitlements = entitlements
        self.endpoint = proxyBaseURL.appendingPathComponent("v1/messages")
        self.model = model
        self.session = session
    }

    func analyze(_ data: PeriodNutritionData) async throws -> String {
        let body = RequestBody(
            model: model,
            maxTokens: 1024,
            system: systemPrompt,
            messages: [Message(role: "user", content: userPrompt(for: data))]
        )
        let bodyData = try JSONEncoder().encode(body)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "content-type")
        req.addValue(try await attest.deviceId(), forHTTPHeaderField: "X-Device-Id")
        req.addValue(try await attest.assertion(for: bodyData), forHTTPHeaderField: "X-Assertion")
        let installId = InstallIdentity.shared.id
        if !installId.isEmpty {
            // Mirrors the header sent on /v1/messages by ClaudeFoodRecognitionService —
            // either endpoint can trip the initial grant, so both carry the install id.
            req.addValue(installId, forHTTPHeaderField: "X-Install-Id")
        }
        if let skEnv = StoreKitEnvironment.shared.value {
            // Limits the free-AI promo to Production users — see StoreKitEnvironment and
            // ClaudeFoodRecognitionService for the full rationale.
            req.addValue(skEnv, forHTTPHeaderField: "X-StoreKit-Env")
        }
        #if DEBUG
        // Mirror of the same header sent on /v1/messages by ClaudeFoodRecognitionService —
        // signals a debug iOS build so the proxy grants 1 initial credit instead of 50.
        req.addValue("1", forHTTPHeaderField: "X-Debug-Build")
        #endif
        // Names the AI feature this call serves so the proxy can re-route the model
        // server-side — mirrors ClaudeFoodRecognitionService.authedRequest.
        req.addValue(AIFlow.insights.rawValue, forHTTPHeaderField: "X-AI-Flow")
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

        Important — how to judge calorie adherence:
          • The user's "daily calorie plan" is the planned intake on an ON-PLAN day \
            (typically weekdays). It is NOT a daily average target. The whole point \
            of this app is that they eat at the plan number on plan days and eat \
            more on off days (weekends, social occasions), with exercise balancing \
            the average down. So the period's average gross calories WILL be above \
            the plan number by design — that is not a problem and you must not flag \
            it as one. Do not say things like "you went over your calorie goal" \
            based on gross intake.
          • The number that actually matters is NET calories vs. the NET calorie \
            goal. That is the adherence signal. Praise or coach against the net \
            number, not the gross.
          • If net is off-target, the levers are (in order): reduce off-day \
            indulgences, add exercise, or — only if those don't fit the user's \
            life — adjust the plan itself. Don't suggest lowering the gross plan \
            number as a first move.

        Use exactly these two markdown sections, no more:

        ## How you did
        Two short paragraphs.

        Paragraph 1 — period summary (3–5 sentences). Lead with the headline (e.g. \
        "Solid week on net" / "Net came in high" / "Strong on protein, light on \
        exercise"). Compare AVERAGE NET calories to the net calorie goal — that's \
        the adherence read. Do not compare gross intake to the gross plan number; \
        treat the gross plan only as background context for what an on-plan day \
        looks like. Then be honest about exercise — don't sugarcoat:
          • Daily or near-daily workouts with a strong burn (≥500 kcal most days) → \
            warm praise: "you're crushing it — daily workouts above 500 kcal is no \
            joke, keep it up."
          • Consistent but moderate (3–5 days/week, decent burn) → positive but \
            note room to push if their goals warrant it.
          • Spotty (a few random days, mostly zeros) → call it out kindly and suggest \
            a steadier rhythm like 3–4 days/week.
          • Almost none → encourage starting small (e.g. two 30-min walks this week).

        Paragraph 2 — weight trend and outlook (3–5 sentences). Use the weight \
        samples to estimate direction and a rough rate (e.g. "trending down ~0.4 \
        lb/week", "up about 1 lb/week", "basically flat"). Tie the trend back to net \
        calories where relevant (a ~500 kcal/day deficit ≈ 1 lb/week loss). Calibrate \
        confidence by the data you have:
          • No weight entries → say so plainly and encourage them to start logging \
            ("we can't read a trend yet — weigh in once or twice a week and we'll \
            have a clearer picture in a few weeks").
          • Sparse (<4 samples or <~3 weeks span) → give your best read but flag it \
            as preliminary, e.g. "we only have ~3 weeks of data but your weight has \
            been trending down — keep going and keep logging, with more time we'll \
            be able to make a sharper call."
          • Ample (~4+ weeks with regular entries) → speak more confidently about \
            direction and rate.
        If they have a goal weight, briefly note whether the trend is moving toward \
        or away from it.

        ## What to try next
        Three short, concrete recommendations as a markdown bulleted list. Each \
        bullet starts with an imperative verb and is one sentence max. Be specific \
        and directive — say what to cut, swap, add, or do, not vague principles. If \
        weight is trending the wrong way for their goal, one bullet should target \
        net calories specifically (eat less of X, OR add more exercise — pick the \
        lever that fits their pattern). Examples of the style:
        - "Reduce carbs by ~50 g/day — swap one daily snack for protein + veg."
        - "Add a 30-minute walk on Wednesday and Friday to lift your weekly burn."
        - "Bump protein to ~140 g/day — add a Greek yogurt or protein shake at \
          breakfast."

        Always keep the response under 260 words total.
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
        lines.append("- Exercise burn: \(formatted(d.totalExercise)) kCal (avg \(formatted(d.avgExercise)) kCal/day; logged on \(d.exerciseDayCount) of \(d.dayCount) day\(d.dayCount == 1 ? "" : "s"))")
        lines.append("- Net calories (consumed − exercise): \(formatted(d.totalNetCalories)) kCal (avg \(formatted(d.avgNetCalories)) kCal/day)")
        lines.append("")
        lines.append("Macro split by calorie share: protein \(proteinPct)%, carbs \(carbsPct)%, fat \(fatPct)%.")

        if d.dailyCalorieGoal != nil || d.dailyNetCalorieGoal != nil || d.dailyExerciseGoal != nil {
            lines.append("")
            lines.append("User's daily goals:")
            if let g = d.dailyCalorieGoal {
                lines.append("- On-plan day calorie target: \(g) kCal (the planned intake on a typical weekday; the app expects higher intake on off days, so PERIOD AVERAGE GROSS WILL BE ABOVE THIS NUMBER BY DESIGN — do not flag that as a problem)")
            }
            if let g = d.dailyNetCalorieGoal {
                lines.append("- Net calorie goal: \(g) kCal/day (THIS is the adherence target — judge the period against this, not the gross number above)")
            }
            if let g = d.dailyExerciseGoal {
                lines.append("- Exercise goal: \(g) kCal/day")
            }
        }

        lines.append("")
        lines.append(weightSection(for: d))

        lines.append("")
        lines.append("Analyze this period and give your assessment in the format described in the system prompt.")
        return lines.joined(separator: "\n")
    }

    private func weightSection(for d: PeriodNutritionData) -> String {
        var out: [String] = []
        if d.weightSamples.isEmpty {
            out.append("Weight log: no entries logged yet.")
            if let goal = d.goalWeight {
                out.append("Goal weight: \(formatted(goal)) \(d.weightUnitSuffix).")
            }
            return out.joined(separator: "\n")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let sorted = d.weightSamples.sorted { $0.date < $1.date }
        let firstDate = sorted.first!.date
        let lastDate = sorted.last!.date
        let spanDays = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: firstDate), to: Calendar.current.startOfDay(for: lastDate)).day ?? 0)

        let granularity: String
        if sorted.count < 4 || spanDays < 21 {
            granularity = "sparse — preliminary read only, encourage continued logging"
        } else if spanDays >= 42 {
            granularity = "ample — speak with confidence about trend"
        } else {
            granularity = "moderate"
        }

        out.append("Weight log (\(sorted.count) sample\(sorted.count == 1 ? "" : "s") spanning \(spanDays) day\(spanDays == 1 ? "" : "s"); data density: \(granularity)):")
        for sample in sorted {
            let date = formatter.string(from: sample.date)
            out.append("- \(date): \(formattedWeight(sample.weight)) \(d.weightUnitSuffix)")
        }
        if let goal = d.goalWeight {
            out.append("Goal weight: \(formattedWeight(goal)) \(d.weightUnitSuffix).")
        }
        return out.joined(separator: "\n")
    }

    private func formattedWeight(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(1)))
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
