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

        // USDA returns nutrients in two shapes:
        //   - Branded: per *one* serving (e.g. "1 bar = 57g, 200 kcal/serving"). caloriesPerServing
        //     here is per native unit directly.
        //   - Foundation / SR Legacy: per 100 g (raw eggs, flour). No countable native — we treat
        //     these as loose mass. Per-native = per-gram = total / 100.
        let normalizedSizeUnit = servingSizeUnit?.lowercased()
        let servingMassGrams: Double? = {
            guard let normalizedSizeUnit, let servingSize else { return nil }
            switch normalizedSizeUnit {
            case "g", "gm": return servingSize
            default: return nil
            }
        }()
        let servingMassMl: Double? = {
            guard let normalizedSizeUnit, let servingSize else { return nil }
            switch normalizedSizeUnit {
            case "ml", "mlt": return servingSize
            default: return nil
            }
        }()

        // Try to extract a countable native unit ("bar"/"cup") from `householdServingFullText`.
        // Failing that, treat as loose mass/volume per the API's serving size.
        var nativeUnit: String = "ea"
        var nativeUnitGrams: Double? = nil
        var nativeUnitMilliliters: Double? = nil
        var caloriesPerNative = calories
        var proteinPerNative = protein
        var carbsPerNative = carbs
        var fatPerNative = fat
        var satPerNative = saturated
        var transPerNative = trans
        var monoPerNative = mono
        var polyPerNative = poly
        var cholPerNative = cholesterol
        var sodiumPerNative = sodium
        var fiberPerNative = fiber
        var sugarsPerNative = sugars
        var addedSugarsPerNative = addedSugars
        var initialSelectedUnit: String = "ea"
        var initialSelectedQuantity: Double = 1

        if let household = householdServingFullText, !household.isEmpty,
           let parsed = ServingMath.parseServingDescription(household),
           parsed.count > 0,
           !parsed.unit.isEmpty {
            let token = ServingMath.normalizeUnitToken(parsed.unit)
            if !token.isEmpty && !ServingMath.isMeasurementUnit(token) {
                // Countable native unit. Servings nutrients are already per *household serving*,
                // which equals `parsed.count` of native. Divide to get per-native.
                nativeUnit = token
                if let g = servingMassGrams { nativeUnitGrams = g / parsed.count }
                if let ml = servingMassMl { nativeUnitMilliliters = ml / parsed.count }
                caloriesPerNative = calories / parsed.count
                proteinPerNative = protein / parsed.count
                carbsPerNative = carbs / parsed.count
                fatPerNative = fat / parsed.count
                satPerNative = saturated.map { $0 / parsed.count }
                transPerNative = trans.map { $0 / parsed.count }
                monoPerNative = mono.map { $0 / parsed.count }
                polyPerNative = poly.map { $0 / parsed.count }
                cholPerNative = cholesterol.map { $0 / parsed.count }
                sodiumPerNative = sodium.map { $0 / parsed.count }
                fiberPerNative = fiber.map { $0 / parsed.count }
                sugarsPerNative = sugars.map { $0 / parsed.count }
                addedSugarsPerNative = addedSugars.map { $0 / parsed.count }
                initialSelectedUnit = token
                initialSelectedQuantity = 1
            }
        }

        if nativeUnit == "ea" {
            // No countable native parsed. Fall back to loose mass/volume.
            if let mass = servingMassGrams, mass > 0 {
                nativeUnit = "g"
                nativeUnitGrams = 1
                let factor = mass
                caloriesPerNative = calories / factor
                proteinPerNative = protein / factor
                carbsPerNative = carbs / factor
                fatPerNative = fat / factor
                satPerNative = saturated.map { $0 / factor }
                transPerNative = trans.map { $0 / factor }
                monoPerNative = mono.map { $0 / factor }
                polyPerNative = poly.map { $0 / factor }
                cholPerNative = cholesterol.map { $0 / factor }
                sodiumPerNative = sodium.map { $0 / factor }
                fiberPerNative = fiber.map { $0 / factor }
                sugarsPerNative = sugars.map { $0 / factor }
                addedSugarsPerNative = addedSugars.map { $0 / factor }
                initialSelectedUnit = "g"
                initialSelectedQuantity = mass
            } else if let vol = servingMassMl, vol > 0 {
                nativeUnit = "ml"
                nativeUnitMilliliters = 1
                let factor = vol
                caloriesPerNative = calories / factor
                proteinPerNative = protein / factor
                carbsPerNative = carbs / factor
                fatPerNative = fat / factor
                satPerNative = saturated.map { $0 / factor }
                transPerNative = trans.map { $0 / factor }
                monoPerNative = mono.map { $0 / factor }
                polyPerNative = poly.map { $0 / factor }
                cholPerNative = cholesterol.map { $0 / factor }
                sodiumPerNative = sodium.map { $0 / factor }
                fiberPerNative = fiber.map { $0 / factor }
                sugarsPerNative = sugars.map { $0 / factor }
                addedSugarsPerNative = addedSugars.map { $0 / factor }
                initialSelectedUnit = "ml"
                initialSelectedQuantity = vol
            } else {
                // Foundation foods with no serving info — assume per-100g convention.
                nativeUnit = "g"
                nativeUnitGrams = 1
                caloriesPerNative = calories / 100
                proteinPerNative = protein / 100
                carbsPerNative = carbs / 100
                fatPerNative = fat / 100
                satPerNative = saturated.map { $0 / 100 }
                transPerNative = trans.map { $0 / 100 }
                monoPerNative = mono.map { $0 / 100 }
                polyPerNative = poly.map { $0 / 100 }
                cholPerNative = cholesterol.map { $0 / 100 }
                sodiumPerNative = sodium.map { $0 / 100 }
                fiberPerNative = fiber.map { $0 / 100 }
                sugarsPerNative = sugars.map { $0 / 100 }
                addedSugarsPerNative = addedSugars.map { $0 / 100 }
                initialSelectedUnit = "g"
                initialSelectedQuantity = 100
            }
        }

        return FoodSearchResult(
            id: id,
            name: description.capitalized,
            brand: brandName ?? brandOwner,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            nativeUnitMilliliters: nativeUnitMilliliters,
            initialSelectedUnit: initialSelectedUnit,
            initialSelectedQuantity: initialSelectedQuantity,
            caloriesPerServing: caloriesPerNative,
            proteinPerServing: proteinPerNative,
            carbsPerServing: carbsPerNative,
            fatPerServing: fatPerNative,
            saturatedFatPerServing: satPerNative,
            transFatPerServing: transPerNative,
            monounsaturatedFatPerServing: monoPerNative,
            polyunsaturatedFatPerServing: polyPerNative,
            cholesterolPerServing: cholPerNative,
            sodiumPerServing: sodiumPerNative,
            fiberPerServing: fiberPerNative,
            sugarsPerServing: sugarsPerNative,
            addedSugarsPerServing: addedSugarsPerNative,
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
