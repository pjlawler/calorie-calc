import Foundation

/// Identifies which AI feature a /v1/messages call serves. Drives two things: the
/// per-flow default model this build sends, and the `X-AI-Flow` header that lets the
/// proxy re-route the model server-side in future without an App Store release.
/// Builds shipped before this header existed send no flow, so proxy routing can
/// never touch them.
enum AIFlow: String {
    case photo = "photo"
    case describe = "describe"
    case recipeAnalyze = "recipe-analyze"
    case recipeImport = "recipe-import"
    case insights = "insights"
    case planAnalyze = "plan-analyze"
    case planQuestion = "plan-question"

    /// Cost-tiered defaults: Sonnet for the structured food-estimation flows, Haiku
    /// for narrating numbers the app already computed, Opus only where its high-res
    /// vision earns the cost (reading nutrition labels / small print on import).
    var model: String {
        switch self {
        case .photo, .describe, .recipeAnalyze: return "claude-sonnet-4-6"
        case .recipeImport: return "claude-opus-4-8"
        case .insights: return "claude-haiku-4-5"
        // Structured reasoning (pick a split that fits preferences, sanity-check the math)
        // plus coaching prose — same tier as the other reasoning flows.
        case .planAnalyze: return "claude-sonnet-4-6"
        // Reasoning over the user's plan + progress to answer a free-form question — Sonnet
        // rather than the insights Haiku, since it has to diagnose, not just narrate numbers.
        case .planQuestion: return "claude-sonnet-4-6"
        }
    }
}

final class ClaudeFoodRecognitionService: FoodRecognitionService, Sendable {

    private let attest: AppAttestService
    private let entitlements: EntitlementService?
    private let modelOverride: String?
    private let session: URLSession
    private let endpoint: URL

    init(
        proxyBaseURL: URL,
        attest: AppAttestService,
        entitlements: EntitlementService? = nil,
        modelOverride: String? = nil,
        session: URLSession = .shared
    ) {
        self.attest = attest
        self.entitlements = entitlements
        self.endpoint = proxyBaseURL.appendingPathComponent("v1/messages")
        self.modelOverride = modelOverride
        self.session = session
    }

    private func model(for flow: AIFlow) -> String {
        modelOverride ?? flow.model
    }

    /// Builds an authenticated POST to the proxy. The proxy adds the Anthropic API key
    /// server-side; the device proves itself via App Attest assertion bound to `body`.
    private func authedRequest(body: Data, flow: AIFlow) async throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "content-type")
        let attested = try await attest.attestedHeaders(for: body)
        req.addValue(attested.deviceId, forHTTPHeaderField: "X-Device-Id")
        req.addValue(attested.assertion, forHTTPHeaderField: "X-Assertion")
        let installId = InstallIdentity.shared.id
        if !installId.isEmpty {
            // iCloud-synced identifier so reinstalling on the same Apple ID can't
            // re-roll the initial free-credit grant. See InstallIdentity for details.
            req.addValue(installId, forHTTPHeaderField: "X-Install-Id")
        }
        if let skEnv = StoreKitEnvironment.shared.value {
            // Lets the proxy limit the free-AI promo to Production (App Store) users —
            // Sandbox (App Review / TestFlight) falls through to the paywall. See
            // StoreKitEnvironment. Omitted until resolved; the proxy treats absence as
            // production.
            req.addValue(skEnv, forHTTPHeaderField: "X-StoreKit-Env")
        }
        #if DEBUG
        // Hint to the proxy that this is a debug build so it grants 1 initial credit
        // instead of the production amount, making the paywall flow easy to retest
        // on a fresh device record. Header is outside the assertion's bound bytes,
        // so this is purely a hint — App Attest still authenticates the device.
        req.addValue("1", forHTTPHeaderField: "X-Debug-Build")
        #endif
        // Names the AI feature this call serves so the proxy can re-route the model
        // server-side (cost tuning without an App Store release). Outside the
        // assertion's bound bytes — routing is a cost lever, not a security boundary.
        req.addValue(flow.rawValue, forHTTPHeaderField: "X-AI-Flow")
        req.httpBody = body
        return req
    }

    /// Centralized request execution for all three AI methods. Handles the status-code
    /// → `FoodRecognitionError` mapping (including the new 402 → `outOfCredits` case)
    /// and notifies `entitlements` of the outcome so the in-app credit display stays
    /// in sync with the proxy. Decrement is optimistic — `EntitlementService.refresh()`
    /// after the call still authoritatively reconciles with the server.
    private func executeAuthedRequest(body: Data, flow: AIFlow) async throws -> Data {
        let req = try await authedRequest(body: body, flow: flow)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FoodRecognitionError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw FoodRecognitionError.missingAPIKey
        }
        if http.statusCode == 402 {
            if let entitlements {
                await MainActor.run { entitlements.handle402() }
            }
            throw FoodRecognitionError.outOfCredits
        }
        if http.statusCode == 429 {
            throw FoodRecognitionError.overQuota("Rate limited — try again in a moment.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw FoodRecognitionError.networkFailure(message)
        }
        if let entitlements {
            await MainActor.run { entitlements.decrementOptimistically() }
        }
        return data
    }

    func recognize(imageData: Data, hint: String?) async throws -> RecognizedMeal {
        let body = RequestBody(
            model: model(for: .photo),
            maxTokens: 1024,
            messages: [
                Message(role: "user", content: [
                    .image(source: ImageSource(
                        type: "base64",
                        mediaType: "image/jpeg",
                        data: imageData.base64EncodedString()
                    )),
                    .text(buildPrompt(hint: hint)),
                ]),
            ],
            tools: [logMealTool],
            toolChoice: ToolChoice(type: "tool", name: "log_meal")
        )

        let bodyData = try JSONEncoder().encode(body)

        do {
            let data = try await executeAuthedRequest(body: bodyData, flow: .photo)
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            guard let toolUse = decoded.content.first(where: { $0.type == "tool_use" }),
                  let input = toolUse.input else {
                throw FoodRecognitionError.noResult
            }
            return RecognizedMeal(
                name: input.name,
                brand: input.brand.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t },
                portionDescription: input.portion,
                servingGrams: input.serving_grams,
                caloriesPerServing: input.calories,
                proteinPerServing: input.protein_grams,
                carbsPerServing: input.carbs_grams,
                fatPerServing: input.fat_grams,
                confidence: input.confidence,
                notes: input.notes
            )
        } catch is DecodingError {
            throw FoodRecognitionError.invalidResponse
        } catch let err as FoodRecognitionError {
            throw err
        } catch {
            throw FoodRecognitionError.from(error)
        }
    }

    func estimate(description: String) async throws -> RecognizedMeal {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FoodRecognitionError.noResult }

        let body = RequestBody(
            model: model(for: .describe),
            maxTokens: 1024,
            messages: [
                Message(role: "user", content: [.text(buildDescribePrompt(description: trimmed))])
            ],
            tools: [logMealTool],
            toolChoice: ToolChoice(type: "tool", name: "log_meal")
        )

        let bodyData = try JSONEncoder().encode(body)

        do {
            let data = try await executeAuthedRequest(body: bodyData, flow: .describe)
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            guard let toolUse = decoded.content.first(where: { $0.type == "tool_use" }),
                  let input = toolUse.input else {
                throw FoodRecognitionError.noResult
            }
            return RecognizedMeal(
                name: input.name,
                brand: input.brand.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t },
                portionDescription: input.portion,
                servingGrams: input.serving_grams,
                caloriesPerServing: input.calories,
                proteinPerServing: input.protein_grams,
                carbsPerServing: input.carbs_grams,
                fatPerServing: input.fat_grams,
                confidence: input.confidence,
                notes: input.notes
            )
        } catch is DecodingError {
            throw FoodRecognitionError.invalidResponse
        } catch let err as FoodRecognitionError {
            throw err
        } catch {
            throw FoodRecognitionError.from(error)
        }
    }

    func analyzeRecipe(_ input: RecipeAnalysisInput) async throws -> AnalyzedRecipe {
        guard !input.ingredients.isEmpty else { throw FoodRecognitionError.noResult }

        let body = RequestBody(
            model: model(for: .recipeAnalyze),
            maxTokens: 1024,
            messages: [
                Message(role: "user", content: [.text(buildRecipePrompt(input: input))])
            ],
            tools: [logRecipeTool],
            toolChoice: ToolChoice(type: "tool", name: "log_recipe")
        )

        let bodyData = try JSONEncoder().encode(body)

        do {
            let data = try await executeAuthedRequest(body: bodyData, flow: .recipeAnalyze)
            let decoded = try JSONDecoder().decode(RecipeResponseBody.self, from: data)
            guard let toolUse = decoded.content.first(where: { $0.type == "tool_use" }),
                  let toolInput = toolUse.input else {
                throw FoodRecognitionError.noResult
            }
            let yieldOptions = (toolInput.yield_options ?? [])
                .filter { $0.amount > 0 && $0.servings_in_recipe > 0 && !$0.unit.isEmpty }
                .map { RecipeYieldOption(amount: $0.amount, unit: $0.unit, servingsInRecipe: $0.servings_in_recipe) }
            guard !yieldOptions.isEmpty else { throw FoodRecognitionError.noResult }
            return AnalyzedRecipe(
                name: toolInput.name,
                totalCalories: toolInput.total_calories,
                totalProtein: toolInput.total_protein_grams,
                totalCarbs: toolInput.total_carbs_grams,
                totalFat: toolInput.total_fat_grams,
                yieldOptions: yieldOptions,
                confidence: toolInput.confidence,
                notes: toolInput.notes
            )
        } catch is DecodingError {
            throw FoodRecognitionError.invalidResponse
        } catch let err as FoodRecognitionError {
            throw err
        } catch {
            throw FoodRecognitionError.from(error)
        }
    }

    func importRecipe(images: [Data]) async throws -> ImportedRecipe {
        guard !images.isEmpty else { throw FoodRecognitionError.noResult }

        // Cap the image count to bound the request payload (multi-page scans / PDFs).
        var content: [ContentBlock] = images.prefix(5).map { data in
            .image(source: ImageSource(
                type: "base64",
                mediaType: "image/jpeg",
                data: data.base64EncodedString()
            ))
        }
        content.append(.text(buildImportRecipePrompt()))

        let body = RequestBody(
            model: model(for: .recipeImport),
            maxTokens: 2048,
            messages: [Message(role: "user", content: content)],
            tools: [importRecipeTool],
            toolChoice: ToolChoice(type: "tool", name: "import_recipe")
        )

        let bodyData = try JSONEncoder().encode(body)

        do {
            let data = try await executeAuthedRequest(body: bodyData, flow: .recipeImport)
            let decoded = try JSONDecoder().decode(ImportRecipeResponseBody.self, from: data)
            guard let toolUse = decoded.content.first(where: { $0.type == "tool_use" }),
                  let input = toolUse.input else {
                throw FoodRecognitionError.noResult
            }
            let ingredients = (input.ingredients ?? [])
                .compactMap { raw -> ImportedIngredient? in
                    let name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return nil }
                    let amount = (raw.amount ?? 0) > 0 ? raw.amount! : 1
                    let unit = raw.unit.flatMap { $0.isEmpty ? nil : $0 } ?? "g"
                    let brand = raw.brand.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
                    return ImportedIngredient(name: name, amount: amount, unit: unit, brand: brand)
                }
            guard !ingredients.isEmpty else { throw FoodRecognitionError.noResult }
            return ImportedRecipe(
                name: (input.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                ingredients: ingredients,
                servingAmount: input.serving_amount.flatMap { $0 > 0 ? $0 : nil },
                servingUnit: input.serving_unit.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t },
                notes: input.notes.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
            )
        } catch is DecodingError {
            throw FoodRecognitionError.invalidResponse
        } catch let err as FoodRecognitionError {
            throw err
        } catch {
            throw FoodRecognitionError.from(error)
        }
    }

    private func buildImportRecipePrompt() -> String {
        """
        The image(s) show a recipe — it may be a photo of a cookbook page, a handwritten card, a screenshot, or a scanned/printed document. Read it and transcribe the recipe so it can be analyzed for nutrition.

        Extract:
        • name — the recipe's title. If none is visible, infer a short descriptive name.
        • ingredients — every ingredient listed, with its quantity. For each: name (the food, with any brand split into the brand field), amount (a number), and unit (g, oz, lb, kg, ml, l, cup, tbsp, tsp, fl oz, or a singular countable noun like egg, clove, slice). Convert fractions to decimals (½ → 0.5). If an ingredient has no stated amount, use amount 1 with a sensible unit. Do NOT invent ingredients that aren't in the recipe.
        • serving_amount / serving_unit — only if the recipe states a yield ("makes 12 muffins", "serves 4"): e.g. 12 + "muffin", or 4 + "serving". Omit if not stated.
        • notes — any short prep note worth keeping. Optional.

        Transcribe only — do NOT estimate nutrition here. Submit via the import_recipe tool only.
        """
    }

    private var importRecipeTool: Tool {
        Tool(
            name: "import_recipe",
            description: "Submit a recipe transcribed from an image — name, ingredient list, and optional yield.",
            inputSchema: Schema(
                type: "object",
                properties: [
                    "name": Property(type: "string", description: "Recipe title (inferred if none is shown)"),
                    "ingredients": Property(
                        type: "array",
                        description: "Every ingredient in the recipe with its quantity.",
                        items: Property(
                            type: "object",
                            description: "One ingredient.",
                            properties: [
                                "name": Property(type: "string", description: "Ingredient name; split any brand into the brand field"),
                                "amount": Property(type: "number", description: "Numeric quantity; fractions as decimals (0.5). Use 1 if not stated."),
                                "unit": Property(type: "string", description: "Unit token: g, oz, lb, kg, ml, l, cup, tbsp, tsp, fl oz, or a singular countable noun (egg, clove, slice)"),
                                "brand": Property(type: "string", description: "Brand if named; omit otherwise"),
                            ]
                        )
                    ),
                    "serving_amount": Property(type: "number", description: "Stated yield amount (12 for '12 muffins', 4 for 'serves 4'); omit if not stated"),
                    "serving_unit": Property(type: "string", description: "Unit for serving_amount ('muffin', 'serving'); omit if not stated"),
                    "notes": Property(type: "string", description: "Short prep note worth keeping; omit if none"),
                ],
                required: ["ingredients"]
            )
        )
    }

    private func buildRecipePrompt(input: RecipeAnalysisInput) -> String {
        var lines: [String] = []
        let recipeName = input.recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = recipeName.isEmpty ? "Untitled recipe" : recipeName
        lines.append("Estimate total nutrition and suggest serving sizes for this recipe.")
        lines.append("")
        lines.append("Recipe: \(displayName)")
        lines.append("")
        lines.append("Ingredients:")
        for (i, ing) in input.ingredients.enumerated() {
            let brand = ing.brand.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            var line = "\(i + 1). \(formattedAmount(ing.amount)) \(ing.unit) \(ing.name)\(brand)"
            if let cals = ing.knownCalories {
                let macroParts = [
                    "\(Int(cals.rounded())) kcal",
                    ing.knownProtein.map { "\(formattedGrams($0))g protein" },
                    ing.knownCarbs.map { "\(formattedGrams($0))g carbs" },
                    ing.knownFat.map { "\(formattedGrams($0))g fat" }
                ].compactMap { $0 }.joined(separator: ", ")
                line += " — known: \(macroParts)"
            }
            lines.append(line)
        }
        lines.append("")
        lines.append("""
        Sum the ingredients into TOTAL recipe nutrition (kcal + protein/carbs/fat in grams). \
        For ingredients flagged "known" use those exact totals — do not re-estimate them. For \
        ingredients without known macros, estimate from standard nutrition references using \
        the given amount/unit. If amounts are ambiguous, choose moderate values rather than \
        extreme ones.

        Then suggest 2–4 serving-size options describing how the user might portion this \
        recipe. Each option is (amount, unit, servings_in_recipe) — `amount × servings_in_recipe` \
        equals the recipe's total quantity in `unit`s. Examples:

          • A 1000 g pot of chili → {"amount": 100, "unit": "g", "servings_in_recipe": 10} \
            (10 servings of 100 g each) and {"amount": 1, "unit": "cup", "servings_in_recipe": 4} \
            (4 servings of 1 cup each).
          • 6 muffins → {"amount": 1, "unit": "muffin", "servings_in_recipe": 6}.
          • A whole-recipe option, when reasonable: {"amount": 1, "unit": "batch", "servings_in_recipe": 1}.

        Pick options that match how a person would naturally portion the dish. Prefer at \
        least one mass option (g) when the dish is a pot/bowl/loose mass, one volume option \
        (cup/tbsp) when the dish is a sauce/soup/drink, or one count option (muffin/cookie/ \
        slice/patty) when the dish has discrete units. Use singular unit nouns ("muffin", \
        "cookie", "slice"). Keep amounts to clean numbers (50, 100, 1, 0.5).

        Submit via the log_recipe tool only.
        """)
        return lines.joined(separator: "\n")
    }

    private var logRecipeTool: Tool {
        Tool(
            name: "log_recipe",
            description: "Submit total nutrition and serving-size options for a multi-ingredient recipe.",
            inputSchema: Schema(
                type: "object",
                properties: [
                    "name": Property(type: "string", description: "Short recipe name"),
                    "total_calories": Property(type: "number", description: "TOTAL kcal for the entire recipe (sum of all ingredients)"),
                    "total_protein_grams": Property(type: "number", description: "TOTAL grams of protein for the entire recipe"),
                    "total_carbs_grams": Property(type: "number", description: "TOTAL grams of carbs for the entire recipe"),
                    "total_fat_grams": Property(type: "number", description: "TOTAL grams of fat for the entire recipe"),
                    "yield_options": Property(
                        type: "array",
                        description: "2–4 suggested serving-size options. Each is (amount, unit, servings_in_recipe).",
                        items: Property(
                            type: "object",
                            description: "One way to portion the recipe. amount × servings_in_recipe = total recipe quantity in `unit`s.",
                            properties: [
                                "amount": Property(type: "number", description: "Amount of `unit` per single serving (100 for '100 g', 1 for '1 cup')"),
                                "unit": Property(type: "string", description: "Unit token: g, oz, lb, kg, ml, l, cup, tbsp, tsp, fl oz, or a singular countable noun like muffin, cookie, slice, patty, batch"),
                                "servings_in_recipe": Property(type: "number", description: "How many servings of (amount × unit) the whole recipe yields"),
                            ]
                        )
                    ),
                    "confidence": Property(type: "string", description: "high, medium, or low"),
                    "notes": Property(type: "string", description: "Short caveat or assumption"),
                ],
                required: ["name", "total_calories", "total_protein_grams", "total_carbs_grams", "total_fat_grams", "yield_options"]
            )
        )
    }

    private func formattedGrams(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private func formattedAmount(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// Shared field/format rules used by both the describe and photo flows so they return the
    /// same shape of data. The entry preamble (text vs. photo) is supplied separately.
    /// Single source of truth for the tool-call contract. The describe and photo flows share
    /// this verbatim so the output is identical in shape regardless of how the user invoked
    /// the AI — same fields, same semantics, same rounding expectations.
    ///
    /// Key contract: `portion` IS what the user is logging. If they named a quantity, that's
    /// the portion. If not, fall back to a canonical label serving. The macros are always
    /// for the portion as described — no separate "intake amount" / "canonical" split.
    /// The user's preferred language, named in English (e.g. "Japanese", "Spanish"), so the
    /// model can return human-readable text in the user's language. Falls back to English.
    private var responseLanguageName: String {
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        let code = Locale(identifier: preferred).language.languageCode?.identifier ?? "en"
        // Name the language in English so the instruction itself reads cleanly to the model.
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    private var sharedReturnRules: String {
        """
        Return one nutritional profile through the log_meal tool only. The output must be SELF-CONSISTENT: every macro value is for exactly the portion you describe.

        Language: write all human-readable text values (name, the parenthetical descriptor, portion, and notes) in \(responseLanguageName), regardless of what language the user's input is in. Keep brand names in their original form (do NOT translate "Five Guys", "Skippy", etc.), and keep the tool field keys, units, and numeric formatting exactly as specified below.

        Fields:

        • name — the food itself, brand stripped out into its own field. Format "<Item>" or "<Item> (<Descriptor>)". Examples:
          – "Skippy Creamy Peanut Butter" → name: "Peanut Butter (Creamy)", brand: "Skippy".
          – "RX Bar Chocolate Sea Salt" → name: "Protein Bar (Chocolate Sea Salt)", brand: "RX Bar".
          – "Five Guys Cheeseburger" → name: "Cheeseburger", brand: "Five Guys".
          – Home-cooked "ribeye dinner" → name: "Ribeye Dinner", brand omitted.
        • brand — manufacturer or restaurant chain when one applies. Omit for generic / home-cooked / unbranded items.
        • portion — what the user is logging. Pick by priority:
          1. If the user named a SPECIFIC quantity ("100g of mac and cheese", "two bars", "8 fl oz milk", "1/2 cup rice"): use that EXACT quantity verbatim. e.g. "100g", "2 bars", "8 fl oz", "0.5 cup". The macros below must be for THIS amount.
          2. If the photo clearly shows a specific amount the user is eating (e.g. one apple in their hand, a single slice on a plate): describe that amount. e.g. "1 medium apple", "1 slice".
          3. Otherwise (no quantity from user, no obvious amount): use the canonical product/label serving. Format: "<unit> (<grams>g)" — e.g. "2 Tbsp (32g)", "1 bar (52g)", "3/4 cup (40g)", "1 can (355ml)".
          4. Multi-item meal (a plate of distinct components, e.g. steak + sides + drink): use exactly "1 meal".
        • serving_grams — gram weight of the portion above.
          – REQUIRED for any solid/packaged item.
          – OMIT for "1 meal" and for pure-liquid items where mass isn't meaningful.
        • calories, protein_grams, carbs_grams, fat_grams — totals for the WHOLE portion above. NOT per-100g, NOT per-canonical-serving when portion is the user's quantity. Round protein/carbs/fat to one decimal place.
        • confidence — "high" / "medium" / "low".
        • notes —
          – For "1 meal": REQUIRED. Itemize the components, e.g. "4 oz ribeye, 6 oz mashed potatoes with gravy, 12 oz Coke".
          – Otherwise: short caveat for meaningful uncertainty (customization, hidden sauces, size ambiguity). Omit if nothing useful.

        Be grounded. Prefer published label or chain-restaurant nutrition data when the food is identifiable. For ambiguous portions, choose a moderate estimate, not an extreme.
        """
    }

    private func buildDescribePrompt(description: String) -> String {
        """
        You're a nutrition estimator. The user typed this description:

        \"\(description)\"

        \(sharedReturnRules)
        """
    }

    private func buildPrompt(hint: String?) -> String {
        let trimmedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hintLine = (trimmedHint?.isEmpty == false) ? trimmedHint! : "(none)"
        return """
        You're a nutrition estimator. The user took a photo of a food and added this description: \"\(hintLine)\"

        Treat the description as ground truth — it OVERRIDES the photo on identity, brand, and portion. If the description names a quantity (e.g. "100g of mac and cheese"), use that quantity directly in `portion` even if the photo looks like more or less food. Use the photo only for what the description leaves unspecified.

        \(sharedReturnRules)
        """
    }

    private var logMealTool: Tool {
        Tool(
            name: "log_meal",
            description: "Submit the nutritional estimate for the meal in the photo.",
            inputSchema: Schema(
                type: "object",
                properties: [
                    "name": Property(type: "string", description: "Item with an optional parenthetical descriptor, e.g. 'Peanut Butter (Creamy)'. Do NOT include the brand here — it goes in the brand field."),
                    "brand": Property(type: "string", description: "Brand or restaurant chain (e.g. 'Skippy', 'Five Guys'). Always extract the brand out of the name into this field. Omit only for generic / home-cooked / unbranded items."),
                    "portion": Property(type: "string", description: "What the user is logging. If they named a specific quantity, use that verbatim ('100g', '2 bars', '8 fl oz'). If the photo shows a clear amount, describe that ('1 medium apple'). Otherwise canonical label serving '<unit> (<grams>g)' like '2 Tbsp (32g)'. '1 meal' for multi-item plates."),
                    "serving_grams": Property(type: "number", description: "Gram weight of the portion above; omit for the '1 meal' case and for pure-liquid items"),
                    "calories": Property(type: "number", description: "Total calories (kcal) for the portion above"),
                    "protein_grams": Property(type: "number", description: "Protein in grams for the portion above"),
                    "carbs_grams": Property(type: "number", description: "Carbohydrates in grams for the portion above"),
                    "fat_grams": Property(type: "number", description: "Fat in grams for the portion above"),
                    "confidence": Property(type: "string", description: "high, medium, or low"),
                    "notes": Property(type: "string", description: "For '1 meal' portions: itemized breakdown like '4 oz ribeye, 6 oz mashed potatoes, 12 oz Coke'. Otherwise: short caveat if there's uncertainty."),
                ],
                required: ["name", "portion", "calories", "protein_grams", "carbs_grams", "fat_grams"]
            )
        )
    }
}

// MARK: - Request DTOs

private struct RequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [Message]
    let tools: [Tool]
    let toolChoice: ToolChoice

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
        case tools
        case toolChoice = "tool_choice"
    }
}

private struct Message: Encodable {
    let role: String
    let content: [ContentBlock]
}

private enum ContentBlock: Encodable {
    case text(String)
    case image(source: ImageSource)

    enum CodingKeys: String, CodingKey {
        case type, text, source
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .image(let source):
            try c.encode("image", forKey: .type)
            try c.encode(source, forKey: .source)
        }
    }
}

private struct ImageSource: Encodable {
    let type: String
    let mediaType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }
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
    /// JSON-schema element descriptor for `type: "array"`. Heap-boxed via `PropertyBox` so the
    /// struct doesn't recursively contain itself.
    let items: PropertyBox?
    /// JSON-schema property map for `type: "object"`.
    let properties: [String: Property]?

    init(type: String, description: String? = nil, items: Property? = nil, properties: [String: Property]? = nil) {
        self.type = type
        self.description = description
        self.items = items.map(PropertyBox.init)
        self.properties = properties
    }

    enum CodingKeys: String, CodingKey {
        case type, description, items, properties
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if let description { try c.encode(description, forKey: .description) }
        if let items { try c.encode(items, forKey: .items) }
        if let properties { try c.encode(properties, forKey: .properties) }
    }
}

private final class PropertyBox: Encodable {
    let value: Property
    init(_ value: Property) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

private struct ToolChoice: Encodable {
    let type: String
    let name: String
}

// MARK: - Response DTOs

private struct ResponseBody: Decodable {
    let content: [ResponseContent]
}

private struct ResponseContent: Decodable {
    let type: String
    let input: ToolInput?
}

private struct ToolInput: Decodable {
    let name: String
    let brand: String?
    let portion: String
    let serving_grams: Double?
    let calories: Double
    let protein_grams: Double
    let carbs_grams: Double
    let fat_grams: Double
    let confidence: String?
    let notes: String?
}

private struct RecipeResponseBody: Decodable {
    let content: [RecipeResponseContent]
}

private struct RecipeResponseContent: Decodable {
    let type: String
    let input: RecipeToolInput?
}

private struct RecipeToolInput: Decodable {
    let name: String
    let total_calories: Double
    let total_protein_grams: Double
    let total_carbs_grams: Double
    let total_fat_grams: Double
    let yield_options: [YieldOptionInput]?
    let confidence: String?
    let notes: String?
}

private struct YieldOptionInput: Decodable {
    let amount: Double
    let unit: String
    let servings_in_recipe: Double
}

private struct ImportRecipeResponseBody: Decodable {
    let content: [ImportRecipeResponseContent]
}

private struct ImportRecipeResponseContent: Decodable {
    let type: String
    let input: ImportRecipeToolInput?
}

private struct ImportRecipeToolInput: Decodable {
    let name: String?
    let ingredients: [ImportIngredientInput]?
    let serving_amount: Double?
    let serving_unit: String?
    let notes: String?
}

private struct ImportIngredientInput: Decodable {
    let name: String
    let amount: Double?
    let unit: String?
    let brand: String?
}
