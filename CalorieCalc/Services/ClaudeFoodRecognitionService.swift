import Foundation

final class ClaudeFoodRecognitionService: FoodRecognitionService, Sendable {

    private let attest: AppAttestService
    private let entitlements: EntitlementService?
    private let model: String
    private let session: URLSession
    private let endpoint: URL

    init(
        proxyBaseURL: URL,
        attest: AppAttestService,
        entitlements: EntitlementService? = nil,
        model: String = "claude-sonnet-4-6",
        session: URLSession = .shared
    ) {
        self.attest = attest
        self.entitlements = entitlements
        self.endpoint = proxyBaseURL.appendingPathComponent("v1/messages")
        self.model = model
        self.session = session
    }

    /// Builds an authenticated POST to the proxy. The proxy adds the Anthropic API key
    /// server-side; the device proves itself via App Attest assertion bound to `body`.
    private func authedRequest(body: Data) async throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "content-type")
        req.addValue(try await attest.deviceId(), forHTTPHeaderField: "X-Device-Id")
        req.addValue(try await attest.assertion(for: body), forHTTPHeaderField: "X-Assertion")
        #if DEBUG
        // Hint to the proxy that this is a debug build so it grants 1 initial credit
        // instead of the production amount, making the paywall flow easy to retest
        // on a fresh device record. Header is outside the assertion's bound bytes,
        // so this is purely a hint — App Attest still authenticates the device.
        req.addValue("1", forHTTPHeaderField: "X-Debug-Build")
        #endif
        req.httpBody = body
        return req
    }

    /// Centralized request execution for all three AI methods. Handles the status-code
    /// → `FoodRecognitionError` mapping (including the new 402 → `outOfCredits` case)
    /// and notifies `entitlements` of the outcome so the in-app credit display stays
    /// in sync with the proxy. Decrement is optimistic — `EntitlementService.refresh()`
    /// after the call still authoritatively reconciles with the server.
    private func executeAuthedRequest(body: Data) async throws -> Data {
        let req = try await authedRequest(body: body)
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
            model: model,
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
            let data = try await executeAuthedRequest(body: bodyData)
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            guard let toolUse = decoded.content.first(where: { $0.type == "tool_use" }),
                  let input = toolUse.input else {
                throw FoodRecognitionError.noResult
            }
            return RecognizedMeal(
                name: input.name,
                brand: input.brand.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t },
                portionDescription: input.portion,
                intakeAmount: input.intake_amount.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t },
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
            throw FoodRecognitionError.networkFailure(error.localizedDescription)
        }
    }

    func estimate(description: String) async throws -> RecognizedMeal {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FoodRecognitionError.noResult }

        let body = RequestBody(
            model: model,
            maxTokens: 1024,
            messages: [
                Message(role: "user", content: [.text(buildDescribePrompt(description: trimmed))])
            ],
            tools: [logMealTool],
            toolChoice: ToolChoice(type: "tool", name: "log_meal")
        )

        let bodyData = try JSONEncoder().encode(body)

        do {
            let data = try await executeAuthedRequest(body: bodyData)
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            guard let toolUse = decoded.content.first(where: { $0.type == "tool_use" }),
                  let input = toolUse.input else {
                throw FoodRecognitionError.noResult
            }
            return RecognizedMeal(
                name: input.name,
                brand: input.brand.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t },
                portionDescription: input.portion,
                intakeAmount: input.intake_amount.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t },
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
            throw FoodRecognitionError.networkFailure(error.localizedDescription)
        }
    }

    func analyzeRecipe(_ input: RecipeAnalysisInput) async throws -> AnalyzedRecipe {
        guard !input.ingredients.isEmpty else { throw FoodRecognitionError.noResult }

        let body = RequestBody(
            model: model,
            maxTokens: 1024,
            messages: [
                Message(role: "user", content: [.text(buildRecipePrompt(input: input))])
            ],
            tools: [logRecipeTool],
            toolChoice: ToolChoice(type: "tool", name: "log_recipe")
        )

        let bodyData = try JSONEncoder().encode(body)

        do {
            let data = try await executeAuthedRequest(body: bodyData)
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
            throw FoodRecognitionError.networkFailure(error.localizedDescription)
        }
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
    private var sharedReturnRules: String {
        """
        Return a single-portion nutritional profile through the log_meal tool only. Fields:

        • name — the item itself with an optional parenthetical descriptor; the brand goes in its own field, NEVER in the name. Format: "<Item> (<Descriptor>)" when a descriptor adds useful info, otherwise just "<Item>". Examples:
          – "Skippy Creamy Peanut Butter" → name: "Peanut Butter (Creamy)", brand: "Skippy".
          – "RX Bar Chocolate Sea Salt" → name: "Protein Bar (Chocolate Sea Salt)", brand: "RX Bar".
          – "Five Guys Cheeseburger" → name: "Cheeseburger", brand: "Five Guys".
          – "Diet Coke 12 oz can" → name: "Diet Coke", brand: "Coca-Cola".
          – Home-cooked "ribeye dinner" → name: "Ribeye Dinner", brand omitted.
        • brand — manufacturer or restaurant chain when one applies (e.g. "Skippy", "RX Bar", "Coca-Cola", "Five Guys", "Chipotle"). Always pull the brand out of the name into this field. Omit only for generic / home-cooked / unbranded items.
        • portion — pick the format that matches the food:
          – Multi-item meal (a plate with several distinct components, e.g. steak + sides + drink, or a combo): use exactly "1 meal". Do NOT include grams or items in this field — the breakdown goes in notes.
          – Single packaged item with a labeled serving (peanut butter, protein bar, cereal, canned drink): use the canonical product label serving — natural unit followed by parenthetical grams, e.g. "2 Tbsp (32g)", "1 bar (52g)", "3/4 cup (40g)", "1 can (355ml)". This lets the app scale by either unit. IMPORTANT: even if the user's description names a quantity (e.g. "Skippy peanut butter 100g", "two bars"), still return the canonical label serving here. The user's quantity is a UI concern — the app handles scaling. Don't substitute "100g" or "2 bars" into this field.
          – Single non-packaged item (no label, no breakdown): use "1" + a single-word unit noun, e.g. "1 burger", "1 slice", "1 bowl", "1 taco". Put descriptors ("medium", "double") in notes, not the portion.
        • serving_grams — gram weight of the portion you described above.
          – REQUIRED for any single item with meaningful weight (essentially every solid food).
          – OMIT for the "1 meal" case (we don't track a single weight for the whole plate) and for pure-liquid items where mass isn't meaningful.
        • calories, protein_grams, carbs_grams, fat_grams — totals for the WHOLE portion above. For packaged items that means PER ONE LABEL SERVING (not for any user-mentioned quantity). For "1 meal" that means the entire plate combined.
        • intake_amount — optional. The actual amount the user is logging when it's clearly known: the quantity they typed in the description ("100g of peanut butter" → "100g"; "two bars" → "2 bars"; "8 fl oz" → "8 fl oz") OR a clearly visible amount in a photo (e.g. "looks like roughly 100g of peanut butter on the toast" → "100g"). Use standard units the app understands: g, oz, lb, kg, ml, fl oz, cup, tbsp, tsp, l, or the same countable noun used in `portion`. If the user gave a vague unit ("half a jar"), convert to grams. OMIT when no specific quantity was given (e.g. just "Skippy peanut butter") and for the "1 meal" case (the meal is the meal).
        • confidence — "high" / "medium" / "low".
        • notes —
          – For a "1 meal" portion: REQUIRED. Itemize the components with rough portions, e.g. "4 oz ribeye, 6 oz mashed potatoes with gravy, 12 oz Coke".
          – Otherwise: short caveat if there's meaningful uncertainty (customization, size ambiguity, hidden sauces). Omit if nothing useful to add.

        Be grounded. For ambiguous portions, choose a moderate estimate rather than an extreme. Prefer published chain-restaurant or branded-product nutrition data when the food is identifiable.
        """
    }

    private func buildDescribePrompt(description: String) -> String {
        """
        You're a nutrition estimator. A user typed this description of a food item or meal:

        \"\(description)\"

        \(sharedReturnRules)
        """
    }

    private func buildPrompt(hint: String?) -> String {
        let trimmedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hintLine = (trimmedHint?.isEmpty == false) ? trimmedHint! : "(none)"
        return """
        You're a nutrition estimator looking at a photo of a meal or food item. Identify what's in the image — brand for packaged products, item identity, portion size, and any distinct components if it's a multi-item plate (e.g. "4 oz ribeye, 6 oz mashed potatoes, 12 oz Coke").

        If the user provided a description below, treat it as ground truth. It OVERRIDES the photo on identity, brand, portion size, and meal composition — for example, if the photo looks like a 4 oz steak but the description says 6 oz, use 6 oz. Use the photo only for whatever the description leaves unspecified.

        User description: \(hintLine)

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
                    "portion": Property(type: "string", description: "'1 meal' for multi-item plates; '<unit> (<grams>g)' like '2 Tbsp (32g)' for packaged items with labeled servings; '1 burger' / '1 slice' for single non-packaged items"),
                    "serving_grams": Property(type: "number", description: "Gram weight of the portion; omit for the '1 meal' case and for pure-liquid items"),
                    "calories": Property(type: "number", description: "Total calories (kcal) for the whole portion"),
                    "protein_grams": Property(type: "number", description: "Protein in grams for the whole portion"),
                    "carbs_grams": Property(type: "number", description: "Carbohydrates in grams for the whole portion"),
                    "fat_grams": Property(type: "number", description: "Fat in grams for the whole portion"),
                    "intake_amount": Property(type: "string", description: "The actual amount the user is logging (from explicit user mention or photo-visible amount), e.g. '100g', '2 Tbsp', '4 oz', '2 bars'. Omit if no specific quantity was given."),
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
    let intake_amount: String?
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
