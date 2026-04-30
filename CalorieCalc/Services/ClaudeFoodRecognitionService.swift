import Foundation

final class ClaudeFoodRecognitionService: FoodRecognitionService, Sendable {

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

    func recognize(imageData: Data, hint: String?) async throws -> RecognizedMeal {
        guard !apiKey.isEmpty else { throw FoodRecognitionError.missingAPIKey }

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

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.addValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw FoodRecognitionError.invalidResponse
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw FoodRecognitionError.missingAPIKey
            }
            if http.statusCode == 429 {
                throw FoodRecognitionError.overQuota("Rate limited — try again in a moment.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw FoodRecognitionError.networkFailure(message)
            }

            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            guard let toolUse = decoded.content.first(where: { $0.type == "tool_use" }),
                  let input = toolUse.input else {
                throw FoodRecognitionError.noResult
            }
            return RecognizedMeal(
                name: input.name,
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
            throw FoodRecognitionError.networkFailure(error.localizedDescription)
        }
    }

    func estimate(description: String) async throws -> RecognizedMeal {
        guard !apiKey.isEmpty else { throw FoodRecognitionError.missingAPIKey }
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

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.addValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw FoodRecognitionError.invalidResponse
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw FoodRecognitionError.missingAPIKey
            }
            if http.statusCode == 429 {
                throw FoodRecognitionError.overQuota("Rate limited — try again in a moment.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw FoodRecognitionError.networkFailure(message)
            }

            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            guard let toolUse = decoded.content.first(where: { $0.type == "tool_use" }),
                  let input = toolUse.input else {
                throw FoodRecognitionError.noResult
            }
            return RecognizedMeal(
                name: input.name,
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
            throw FoodRecognitionError.networkFailure(error.localizedDescription)
        }
    }

    private func buildDescribePrompt(description: String) -> String {
        """
        You're a nutrition estimator. A user typed this description of a food item or meal:

        \"\(description)\"

        Estimate a single-serving nutritional profile:
        • A short, clean name (e.g. "Five Guys Cheeseburger").
        • A portion description starting with "1" + a single-word unit noun — "1 bar", "1 burger", "1 cup", "1 slice". Keep it simple: ONE word for the unit when possible. Avoid descriptors like "medium" or "generous" in the unit. If you must qualify, put it in the notes instead.
        • serving_grams — REQUIRED for any food with a meaningful weight (essentially everything that isn't a pure liquid). Provide it even when the natural unit isn't grams: an RX Bar's portion is "1 bar" but its serving_grams is ~52. Only omit for items where mass really isn't meaningful (pure liquids by volume, small drinks, "1 small coffee").
        • Calories, protein (g), carbs (g), and fat (g) for one serving.
        • Confidence — "high" for well-known menu items or canonical recipes; "medium" for ambiguous descriptions; "low" when the input is too vague to estimate safely.
        • A short caveat note if there's meaningful uncertainty (e.g. customization, size ambiguity).

        Prefer published chain-restaurant nutrition data when the description names one. For generic foods, use moderate standard portions.
        Submit via the log_meal tool only.
        """
    }

    private func buildPrompt(hint: String?) -> String {
        var text = """
        You're a nutrition estimator looking at a photo of a meal or food item.

        Estimate:
        • A short descriptive name of the primary food/meal.
        • A portion description starting with "1" + a single-word unit noun — "1 burger", "1 bowl", "1 slice", "1 taco". Keep it simple: ONE word for the unit. Put descriptors ("medium", "double") in the notes, not the portion.
        • serving_grams — REQUIRED for any food with a meaningful weight (essentially every solid food and most plates). Provide it even when the natural unit isn't grams: a burger photo's portion is "1 burger" but serving_grams is ~200. Only omit for pure liquids where mass isn't meaningful.
        • Total calories, protein (g), carbs (g), and fat (g) for that portion.
        • Your confidence — "high" for clear, well-known dishes in clear portions; "medium" for ambiguous portions or partially hidden food; "low" for unclear images.
        • A short caveat note if there's uncertainty (hidden sauces, portion ambiguity, multiple items).

        Be grounded. For ambiguous portions, choose a moderate estimate rather than an extreme.
        For mixed plates, estimate the whole plate together rather than breaking it into items.
        Submit via the log_meal tool only.
        """
        if let hint, !hint.trimmingCharacters(in: .whitespaces).isEmpty {
            text += "\n\nUser hint: \(hint)"
        }
        return text
    }

    private var logMealTool: Tool {
        Tool(
            name: "log_meal",
            description: "Submit the nutritional estimate for the meal in the photo.",
            inputSchema: Schema(
                type: "object",
                properties: [
                    "name": Property(type: "string", description: "Short descriptive meal name"),
                    "portion": Property(type: "string", description: "Plain-language portion description"),
                    "serving_grams": Property(type: "number", description: "Estimated weight of one serving in grams; omit if not meaningful"),
                    "calories": Property(type: "number", description: "Estimated calories (kcal) for the portion"),
                    "protein_grams": Property(type: "number", description: "Protein in grams for the portion"),
                    "carbs_grams": Property(type: "number", description: "Carbohydrates in grams for the portion"),
                    "fat_grams": Property(type: "number", description: "Fat in grams for the portion"),
                    "confidence": Property(type: "string", description: "high, medium, or low"),
                    "notes": Property(type: "string", description: "Short caveat or assumption"),
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

    enum CodingKeys: String, CodingKey {
        case type, description
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if let description { try c.encode(description, forKey: .description) }
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
    let portion: String
    let serving_grams: Double?
    let calories: Double
    let protein_grams: Double
    let carbs_grams: Double
    let fat_grams: Double
    let confidence: String?
    let notes: String?
}
