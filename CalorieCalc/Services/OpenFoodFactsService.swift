import Foundation

final class OpenFoodFactsService: FoodDataSource, Sendable {

    private let session: URLSession
    private let baseURL = URL(string: "https://world.openfoodfacts.org/api/v2")!
    // OFF rejects anonymous clients (503/rate-limit) and documents that every caller must send
    // a User-Agent identifying the app + platform + contact. Format per their API docs.
    private let userAgent = "CalorieCalc/1.0 (iOS; github.com/patricklawler/CalorieCalc)"

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func request(for url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    func search(query: String) async throws -> [FoodSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        // `countries_tags_en=united-states` trims the global catalog down to products actually sold
        // in the US so results line up with what a US user is likely to be scanning.
        // `sort_by=popularity_key` pushes frequently-scanned items to the top, which cuts the
        // long tail of half-populated entries OFF is known for.
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: trimmed),
            URLQueryItem(name: "fields", value: "code,product_name,brands,serving_size,serving_quantity,nutriments"),
            URLQueryItem(name: "page_size", value: "25"),
            URLQueryItem(name: "sort_by", value: "popularity_key"),
            URLQueryItem(name: "countries_tags_en", value: "united-states"),
        ]

        do {
            let (data, response) = try await session.data(for: request(for: components.url!))
            guard let http = response as? HTTPURLResponse else {
                throw FoodDataSourceError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw FoodDataSourceError.networkFailure("HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(OFFSearchResponse.self, from: data)
            return decoded.products.compactMap { product -> FoodSearchResult? in
                guard let code = product.code, !code.isEmpty else { return nil }
                guard let name = product.productName, !name.isEmpty else { return nil }
                let result = product.toSearchResult(barcode: code)
                guard result.caloriesPerServing > 0 else { return nil }
                return result
            }
        } catch is DecodingError {
            throw FoodDataSourceError.invalidResponse
        } catch let err as FoodDataSourceError {
            throw err
        } catch {
            throw FoodDataSourceError.networkFailure(error.localizedDescription)
        }
    }

    func details(for id: String) async throws -> FoodSearchResult {
        let barcode = id.hasPrefix("off:") ? String(id.dropFirst(4)) : id
        if let result = try await lookup(barcode: barcode) {
            return result
        }
        throw FoodDataSourceError.notFound
    }

    func lookup(barcode: String) async throws -> FoodSearchResult? {
        let url = baseURL.appendingPathComponent("product/\(barcode).json")
        do {
            let (data, response) = try await session.data(for: request(for: url))
            guard let http = response as? HTTPURLResponse else {
                throw FoodDataSourceError.invalidResponse
            }
            if http.statusCode == 404 { return nil }
            guard (200..<300).contains(http.statusCode) else {
                throw FoodDataSourceError.networkFailure("HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(OFFResponse.self, from: data)
            guard decoded.status == 1, let product = decoded.product else {
                return nil
            }
            return product.toSearchResult(barcode: barcode)
        } catch is DecodingError {
            throw FoodDataSourceError.invalidResponse
        } catch let err as FoodDataSourceError {
            throw err
        } catch {
            throw FoodDataSourceError.networkFailure(error.localizedDescription)
        }
    }
}

// MARK: - OFF DTOs

private struct OFFResponse: Decodable {
    let status: Int
    let product: OFFProduct?
}

private struct OFFSearchResponse: Decodable {
    let products: [OFFProduct]
}

private struct OFFProduct: Decodable {
    let code: String?
    let productName: String?
    let brands: String?
    let servingSize: String?
    let servingQuantity: FlexibleNumber?
    let nutriments: OFFNutriments?

    enum CodingKeys: String, CodingKey {
        case code
        case productName = "product_name"
        case brands
        case servingSize = "serving_size"
        case servingQuantity = "serving_quantity"
        case nutriments
    }

    func toSearchResult(barcode: String) -> FoodSearchResult {
        let name = (productName?.isEmpty == false ? productName : nil) ?? "Scanned product"
        let quantity = servingQuantity?.doubleValue
        // OFF stores `serving_quantity` as a plain number in g (solids) or ml (liquids), with the
        // unit only disambiguated via the free-text `serving_size`. We look for an "ml"/"l" token
        // there to decide which family the food belongs to; absent a hint we default to grams.
        let isVolume = servingSize.map(Self.looksLikeVolume) ?? false
        var servingGrams = isVolume ? nil : quantity
        var servingMilliliters = isVolume ? quantity : nil
        // Many OFF entries omit `serving_quantity`. Fall back to 100 g (or 100 ml) so the UI
        // still has a sensible native serving and the `_100g` scale math resolves to 1×.
        if servingGrams == nil && servingMilliliters == nil {
            if isVolume { servingMilliliters = 100 } else { servingGrams = 100 }
        }

        let servingDescription: String = {
            if let raw = servingSize, !raw.isEmpty { return raw }
            if let g = servingGrams { return "\(g.formatted(.number.precision(.fractionLength(0...1)))) g" }
            if let ml = servingMilliliters { return "\(ml.formatted(.number.precision(.fractionLength(0...1)))) ml" }
            return "1 serving"
        }()

        // The `_serving` fields come pre-scaled by OFF; the `_100g` fields are per 100 g / 100 ml
        // and need a per-serving scale factor. We scale using whichever native basis is in play.
        let perServingBasis = servingGrams ?? servingMilliliters
        let calories = nutriments?.perServing(servingKey: \.energyKcalServing, per100gKey: \.energyKcal100g, servingBasis: perServingBasis) ?? 0
        let protein = nutriments?.perServing(servingKey: \.proteinsServing, per100gKey: \.proteins100g, servingBasis: perServingBasis) ?? 0
        let carbs = nutriments?.perServing(servingKey: \.carbsServing, per100gKey: \.carbs100g, servingBasis: perServingBasis) ?? 0
        let fat = nutriments?.perServing(servingKey: \.fatServing, per100gKey: \.fat100g, servingBasis: perServingBasis) ?? 0

        let saturated = nutriments?.optionalPerServing(servingKey: \.saturatedFatServing, per100gKey: \.saturatedFat100g, servingBasis: perServingBasis)
        let trans = nutriments?.optionalPerServing(servingKey: \.transFatServing, per100gKey: \.transFat100g, servingBasis: perServingBasis)
        let mono = nutriments?.optionalPerServing(servingKey: \.monoFatServing, per100gKey: \.monoFat100g, servingBasis: perServingBasis)
        let poly = nutriments?.optionalPerServing(servingKey: \.polyFatServing, per100gKey: \.polyFat100g, servingBasis: perServingBasis)
        // OFF stores cholesterol/sodium in grams per serving; the rest of our app treats them as
        // milligrams (USDA convention, nutrition-label convention) — scale once at the boundary.
        let cholesterol = nutriments?.optionalPerServing(servingKey: \.cholesterolServing, per100gKey: \.cholesterol100g, servingBasis: perServingBasis).map { $0 * 1_000 }
        let sodium = nutriments?.optionalPerServing(servingKey: \.sodiumServing, per100gKey: \.sodium100g, servingBasis: perServingBasis).map { $0 * 1_000 }
        let fiber = nutriments?.optionalPerServing(servingKey: \.fiberServing, per100gKey: \.fiber100g, servingBasis: perServingBasis)
        let sugars = nutriments?.optionalPerServing(servingKey: \.sugarsServing, per100gKey: \.sugars100g, servingBasis: perServingBasis)
        let addedSugars = nutriments?.optionalPerServing(servingKey: \.addedSugarsServing, per100gKey: \.addedSugars100g, servingBasis: perServingBasis)

        return FoodSearchResult(
            id: "off:\(barcode)",
            name: name,
            brand: brands,
            servingDescription: servingDescription,
            servingSizeGrams: servingGrams,
            servingSizeMilliliters: servingMilliliters,
            caloriesPerServing: calories,
            proteinPerServing: protein,
            carbsPerServing: carbs,
            fatPerServing: fat,
            saturatedFatPerServing: saturated,
            transFatPerServing: trans,
            monounsaturatedFatPerServing: mono,
            polyunsaturatedFatPerServing: poly,
            cholesterolPerServing: cholesterol,
            sodiumPerServing: sodium,
            fiberPerServing: fiber,
            sugarsPerServing: sugars,
            addedSugarsPerServing: addedSugars,
            source: .barcode
        )
    }

    /// True when the free-text serving description starts with a volume unit (ml, l, cl).
    /// Only considers the first numeric+unit token; "1 cup (240 ml)" is treated as volume.
    private static func looksLikeVolume(_ servingSize: String) -> Bool {
        let lower = servingSize.lowercased()
        // Grab the first unit token after a number. Handles "240 ml", "240ml", "1 L", "1l".
        let pattern = #"(?i)\b\d+(?:\.\d+)?\s*(ml|milliliter|millilitre|cl|centiliter|centilitre|l\b|liter|litre|fl\s*oz|cup|tbsp|tablespoon|tsp|teaspoon|g\b|gram|kg|kilogram|oz|ounce)"#
        guard let range = lower.range(of: pattern, options: .regularExpression) else {
            return false
        }
        let token = lower[range]
        let volumeMarkers = ["ml", "milliliter", "millilitre", "cl", "centiliter", "centilitre", "liter", "litre", "fl oz", "floz", "cup", "tbsp", "tablespoon", "tsp", "teaspoon"]
        if volumeMarkers.contains(where: { token.contains($0) }) { return true }
        // Bare `l` needs word-boundary care so "14 g" doesn't match "liter" etc. The regex already
        // anchors `l\b`, but we still need to distinguish it from a stray letter in a mass unit.
        if token.range(of: #"\b\d+(?:\.\d+)?\s*l\b"#, options: .regularExpression) != nil { return true }
        return false
    }
}

private struct OFFNutriments: Decodable {
    let energyKcalServing: Double?
    let energyKcal100g: Double?
    let proteinsServing: Double?
    let proteins100g: Double?
    let carbsServing: Double?
    let carbs100g: Double?
    let fatServing: Double?
    let fat100g: Double?
    let saturatedFatServing: Double?
    let saturatedFat100g: Double?
    let transFatServing: Double?
    let transFat100g: Double?
    let monoFatServing: Double?
    let monoFat100g: Double?
    let polyFatServing: Double?
    let polyFat100g: Double?
    let cholesterolServing: Double?
    let cholesterol100g: Double?
    let sodiumServing: Double?
    let sodium100g: Double?
    let fiberServing: Double?
    let fiber100g: Double?
    let sugarsServing: Double?
    let sugars100g: Double?
    let addedSugarsServing: Double?
    let addedSugars100g: Double?

    enum CodingKeys: String, CodingKey {
        case energyKcalServing = "energy-kcal_serving"
        case energyKcal100g = "energy-kcal_100g"
        case proteinsServing = "proteins_serving"
        case proteins100g = "proteins_100g"
        case carbsServing = "carbohydrates_serving"
        case carbs100g = "carbohydrates_100g"
        case fatServing = "fat_serving"
        case fat100g = "fat_100g"
        case saturatedFatServing = "saturated-fat_serving"
        case saturatedFat100g = "saturated-fat_100g"
        case transFatServing = "trans-fat_serving"
        case transFat100g = "trans-fat_100g"
        case monoFatServing = "monounsaturated-fat_serving"
        case monoFat100g = "monounsaturated-fat_100g"
        case polyFatServing = "polyunsaturated-fat_serving"
        case polyFat100g = "polyunsaturated-fat_100g"
        case cholesterolServing = "cholesterol_serving"
        case cholesterol100g = "cholesterol_100g"
        case sodiumServing = "sodium_serving"
        case sodium100g = "sodium_100g"
        case fiberServing = "fiber_serving"
        case fiber100g = "fiber_100g"
        case sugarsServing = "sugars_serving"
        case sugars100g = "sugars_100g"
        case addedSugarsServing = "added-sugars_serving"
        case addedSugars100g = "added-sugars_100g"
    }

    /// For required macros — returns 0 when the nutrient is missing on both the `_serving` and
    /// `_100g` paths, matching what the UI expects (no nil for calories/protein/carbs/fat).
    func perServing(
        servingKey: KeyPath<OFFNutriments, Double?>,
        per100gKey: KeyPath<OFFNutriments, Double?>,
        servingBasis: Double?
    ) -> Double {
        optionalPerServing(servingKey: servingKey, per100gKey: per100gKey, servingBasis: servingBasis) ?? 0
    }

    /// For optional nutrients (fiber, sodium, etc.) — returns nil when the source doesn't report
    /// the value on either key, so the UI can hide the row instead of showing a misleading zero.
    func optionalPerServing(
        servingKey: KeyPath<OFFNutriments, Double?>,
        per100gKey: KeyPath<OFFNutriments, Double?>,
        servingBasis: Double?
    ) -> Double? {
        if let direct = self[keyPath: servingKey] { return direct }
        if let per100 = self[keyPath: per100gKey], let basis = servingBasis, basis > 0 {
            return per100 * (basis / 100)
        }
        return self[keyPath: per100gKey]
    }
}

/// OFF sometimes returns numeric fields as either strings or numbers. This pulls whichever form in.
private struct FlexibleNumber: Decodable {
    let doubleValue: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) {
            doubleValue = d
        } else if let s = try? container.decode(String.self) {
            doubleValue = Double(s)
        } else {
            doubleValue = nil
        }
    }
}
