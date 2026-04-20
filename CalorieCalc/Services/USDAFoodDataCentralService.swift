import Foundation

final class USDAFoodDataCentralService: FoodDataSource, Sendable {

    private let apiKey: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.nal.usda.gov/fdc/v1")!

    init(apiKey: String? = nil, session: URLSession = .shared) {
        self.apiKey = apiKey
            ?? (Bundle.main.object(forInfoDictionaryKey: "USDA_API_KEY") as? String)
            ?? ""
        self.session = session
    }

    func search(query: String) async throws -> [FoodSearchResult] {
        try await performSearch(query: query, pageSize: 25)
    }

    func details(for id: String) async throws -> FoodSearchResult {
        guard !apiKey.isEmpty else {
            throw FoodDataSourceError.missingAPIKey
        }

        var components = URLComponents(url: baseURL.appendingPathComponent("food/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]

        let raw = try await fetch(FDCFoodDetail.self, from: components.url!)
        return raw.toSearchResult()
    }

    func lookup(barcode: String) async throws -> FoodSearchResult? {
        let results = try await performSearch(query: barcode, pageSize: 5)
        return results.first
    }

    private func performSearch(query: String, pageSize: Int) async throws -> [FoodSearchResult] {
        guard !apiKey.isEmpty else {
            throw FoodDataSourceError.missingAPIKey
        }

        var components = URLComponents(url: baseURL.appendingPathComponent("foods/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "dataType", value: "Branded,Foundation,SR Legacy"),
        ]

        let response = try await fetch(FDCSearchResponse.self, from: components.url!)
        return response.foods.map { $0.toSearchResult() }
    }

    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw FoodDataSourceError.invalidResponse
            }
            if http.statusCode == 404 { throw FoodDataSourceError.notFound }
            guard (200..<300).contains(http.statusCode) else {
                throw FoodDataSourceError.networkFailure("HTTP \(http.statusCode)")
            }
            return try JSONDecoder().decode(type, from: data)
        } catch is DecodingError {
            throw FoodDataSourceError.invalidResponse
        } catch let error as FoodDataSourceError {
            throw error
        } catch {
            throw FoodDataSourceError.networkFailure(error.localizedDescription)
        }
    }
}

// MARK: - FDC DTOs

private struct FDCSearchResponse: Decodable {
    let foods: [FDCFood]
}

private struct FDCFood: Decodable {
    let fdcId: Int
    let description: String
    let brandName: String?
    let brandOwner: String?
    let servingSize: Double?
    let servingSizeUnit: String?
    let householdServingFullText: String?
    let foodNutrients: [FDCNutrient]

    func toSearchResult() -> FoodSearchResult {
        let id = String(fdcId)
        let calories = FDCNutrient.firstValue(in: foodNutrients, ids: [1008, 2047, 2048, 208])
        let protein = FDCNutrient.firstValue(in: foodNutrients, ids: [1003, 203])
        let carbs = FDCNutrient.firstValue(in: foodNutrients, ids: [1005, 205])
        let fat = FDCNutrient.firstValue(in: foodNutrients, ids: [1004, 204])

        let saturated = FDCNutrient.firstOptionalValue(in: foodNutrients, ids: [1258, 606])
        let trans = FDCNutrient.firstOptionalValue(in: foodNutrients, ids: [1257, 605])
        let mono = FDCNutrient.firstOptionalValue(in: foodNutrients, ids: [1292, 645])
        let poly = FDCNutrient.firstOptionalValue(in: foodNutrients, ids: [1293, 646])
        let cholesterol = FDCNutrient.firstOptionalValue(in: foodNutrients, ids: [1253, 601])
        let sodium = FDCNutrient.firstOptionalValue(in: foodNutrients, ids: [1093, 307])
        let fiber = FDCNutrient.firstOptionalValue(in: foodNutrients, ids: [1079, 291])
        let sugars = FDCNutrient.firstOptionalValue(in: foodNutrients, ids: [2000, 269])
        let addedSugars = FDCNutrient.firstOptionalValue(in: foodNutrients, ids: [1235])

        let normalizedUnit = servingSizeUnit?.lowercased()
        var servingGrams: Double? = {
            guard let normalizedUnit, let servingSize else { return nil }
            switch normalizedUnit {
            case "g", "gm": return servingSize
            default: return nil
            }
        }()
        let servingMilliliters: Double? = {
            guard let normalizedUnit, let servingSize else { return nil }
            switch normalizedUnit {
            case "ml", "mlt": return servingSize
            default: return nil
            }
        }()
        // Foundation / SR Legacy foods (generic ingredients like "Eggs, raw") expose nutrients
        // per 100 g and omit a native serving size. Default to 100 g so the picker shows mass
        // units and the arithmetic stays 1:1 — user can retype any amount they actually ate.
        if servingGrams == nil && servingMilliliters == nil {
            servingGrams = 100
        }

        let servingDescription: String
        if let household = householdServingFullText, !household.isEmpty {
            servingDescription = household
        } else if let size = servingSize, let unit = servingSizeUnit {
            servingDescription = "\(size.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
        } else if let g = servingGrams {
            servingDescription = "\(g.formatted(.number.precision(.fractionLength(0...1)))) g"
        } else {
            servingDescription = "1 serving"
        }

        return FoodSearchResult(
            id: id,
            name: description.capitalized,
            brand: brandName ?? brandOwner,
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
            source: .usdaFDC
        )
    }
}

private struct FDCFoodDetail: Decodable {
    let fdcId: Int
    let description: String
    let brandName: String?
    let brandOwner: String?
    let servingSize: Double?
    let servingSizeUnit: String?
    let householdServingFullText: String?
    let foodNutrients: [FDCDetailNutrient]

    func toSearchResult() -> FoodSearchResult {
        let nutrients = foodNutrients.map { FDCNutrient(nutrientId: $0.nutrient.id, value: $0.amount) }
        let shim = FDCFood(
            fdcId: fdcId,
            description: description,
            brandName: brandName,
            brandOwner: brandOwner,
            servingSize: servingSize,
            servingSizeUnit: servingSizeUnit,
            householdServingFullText: householdServingFullText,
            foodNutrients: nutrients
        )
        return shim.toSearchResult()
    }
}

private struct FDCDetailNutrient: Decodable {
    let nutrient: Inner
    let amount: Double?
    struct Inner: Decodable { let id: Int }
}

private struct FDCNutrient: Decodable {
    let nutrientId: Int
    let value: Double?

    /// For macros we fall back to `0` — every food in USDA has calories/protein/carbs/fat, so a
    /// missing value effectively means zero (e.g. zero fat in an apple).
    static func firstValue(in nutrients: [FDCNutrient], ids: [Int]) -> Double {
        firstOptionalValue(in: nutrients, ids: ids) ?? 0
    }

    /// For non-macro nutrients we preserve nil so the UI can distinguish "source didn't report it"
    /// from "explicitly zero" — Foundation foods rarely report trans fat or added sugars at all.
    static func firstOptionalValue(in nutrients: [FDCNutrient], ids: [Int]) -> Double? {
        for id in ids {
            if let match = nutrients.first(where: { $0.nutrientId == id }) {
                return match.value
            }
        }
        return nil
    }
}
