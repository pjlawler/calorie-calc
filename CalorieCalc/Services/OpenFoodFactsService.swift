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
            // OFF cheerfully returns status=1 for records that only contain a generic name
            // and per-100g nutrients — no brand, no serving_size, no serving_quantity. These
            // are essentially useless to the user, and USDA frequently has the same barcode
            // with full brand + household serving data. Returning nil here lets the chained
            // data source fall through to USDA instead of locking in OFF's stub record.
            let hasServingInfo = (product.servingSize?.trimmingCharacters(in: .whitespaces).isEmpty == false)
                || ((product.servingQuantity?.doubleValue ?? 0) > 0)
            let hasBrand = (product.brands?.trimmingCharacters(in: .whitespaces).isEmpty == false)
            if !hasServingInfo && !hasBrand {
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
        let parsedServing = servingSize.flatMap(ServingMath.parseServingDescription)
        let parsedToken = parsedServing.map { ServingMath.normalizeUnitToken($0.unit) }

        // OFF stores `serving_quantity` as a plain number that's grams for solids and ml for
        // liquids. There's no flag, so we triangulate:
        //   1. A `(NNg)` or `(NNml)` parenthetical in `serving_size` is authoritative.
        //   2. Otherwise: if the parsed primary unit is a strict liquid unit (ml/l/fl oz), quantity
        //      is ml. If it's any other unit (cup/tbsp/tsp/bar/g), quantity is grams. The previous
        //      "any volume word means volume" heuristic mis-classified "1 cup (40g)" as 40 ml.
        let parenGrams = servingSize.flatMap(ServingMath.extractGramsFromParenthetical)
        let parenMl = servingSize.flatMap(ServingMath.extractMillilitersFromParenthetical)
        let pureLiquid = parsedToken.map { ["ml", "l", "fl oz"].contains($0) } ?? false

        var servingMassGrams: Double? = parenGrams ?? (pureLiquid ? nil : quantity)
        var servingMassMl: Double? = parenMl ?? {
            if pureLiquid { return quantity }
            // Compute volume from the parsed unit even when OFF omits it explicitly — "1 cup"
            // (without parenthetical) → 236.588 ml so the picker can offer the volume family.
            if let parsed = parsedServing, let token = parsedToken,
               ServingMath.isVolumeUnit(token),
               let mlPerUnit = ServingMath.millilitersPerVolumeUnit[token] {
                return parsed.count * mlPerUnit
            }
            return nil
        }()

        // Last-resort fallback when the product has no serving info at all — OFF returns plenty
        // of these. 100 g is the conventional "per nutrition label" basis.
        if servingMassGrams == nil && servingMassMl == nil {
            if pureLiquid { servingMassMl = 100 } else { servingMassGrams = 100 }
        }

        let perServingBasis = servingMassGrams ?? servingMassMl
        // OFF's `_serving` fields are per *one* OFF serving (`servingMassGrams`/`servingMassMl`).
        let caloriesPerServing = nutriments?.perServing(servingKey: \.energyKcalServing, per100gKey: \.energyKcal100g, servingBasis: perServingBasis) ?? 0
        let proteinPerServing = nutriments?.perServing(servingKey: \.proteinsServing, per100gKey: \.proteins100g, servingBasis: perServingBasis) ?? 0
        let carbsPerServing = nutriments?.perServing(servingKey: \.carbsServing, per100gKey: \.carbs100g, servingBasis: perServingBasis) ?? 0
        let fatPerServing = nutriments?.perServing(servingKey: \.fatServing, per100gKey: \.fat100g, servingBasis: perServingBasis) ?? 0
        let satPerServing = nutriments?.optionalPerServing(servingKey: \.saturatedFatServing, per100gKey: \.saturatedFat100g, servingBasis: perServingBasis)
        let transPerServing = nutriments?.optionalPerServing(servingKey: \.transFatServing, per100gKey: \.transFat100g, servingBasis: perServingBasis)
        let monoPerServing = nutriments?.optionalPerServing(servingKey: \.monoFatServing, per100gKey: \.monoFat100g, servingBasis: perServingBasis)
        let polyPerServing = nutriments?.optionalPerServing(servingKey: \.polyFatServing, per100gKey: \.polyFat100g, servingBasis: perServingBasis)
        // OFF stores cholesterol/sodium in grams per serving; rest of the app uses mg.
        let cholPerServing = nutriments?.optionalPerServing(servingKey: \.cholesterolServing, per100gKey: \.cholesterol100g, servingBasis: perServingBasis).map { $0 * 1_000 }
        let sodiumPerServing = nutriments?.optionalPerServing(servingKey: \.sodiumServing, per100gKey: \.sodium100g, servingBasis: perServingBasis).map { $0 * 1_000 }
        let fiberPerServing = nutriments?.optionalPerServing(servingKey: \.fiberServing, per100gKey: \.fiber100g, servingBasis: perServingBasis)
        let sugarsPerServing = nutriments?.optionalPerServing(servingKey: \.sugarsServing, per100gKey: \.sugars100g, servingBasis: perServingBasis)
        let addedSugarsPerServing = nutriments?.optionalPerServing(servingKey: \.addedSugarsServing, per100gKey: \.addedSugars100g, servingBasis: perServingBasis)

        // Try to extract a countable native unit from the free-text serving description.
        var nativeUnit: String = "ea"
        var nativeUnitGrams: Double? = nil
        var nativeUnitMilliliters: Double? = nil
        var caloriesPerNative = caloriesPerServing
        var proteinPerNative = proteinPerServing
        var carbsPerNative = carbsPerServing
        var fatPerNative = fatPerServing
        var satPerNative = satPerServing
        var transPerNative = transPerServing
        var monoPerNative = monoPerServing
        var polyPerNative = polyPerServing
        var cholPerNative = cholPerServing
        var sodiumPerNative = sodiumPerServing
        var fiberPerNative = fiberPerServing
        var sugarsPerNative = sugarsPerServing
        var addedSugarsPerNative = addedSugarsPerServing
        var initialSelectedUnit: String = "ea"
        var initialSelectedQuantity: Double = 1

        if let parsed = parsedServing,
           parsed.count > 0,
           let token = parsedToken,
           !token.isEmpty {
            // Mass-unit households ("57 g") collapse to loose-mass native; volume + countable
            // households use the parsed unit as native. See USDA for the same shape — both
            // services normalize household servings the same way so the portion sheet behaves
            // identically regardless of which API answered the barcode.
            if ServingMath.isMassUnit(token) {
                let totalGrams = (ServingMath.gramsPerMassUnit[token] ?? 1) * parsed.count
                let basis = (servingMassGrams ?? totalGrams)
                nativeUnit = "g"
                nativeUnitGrams = 1
                caloriesPerNative = caloriesPerServing / basis
                proteinPerNative = proteinPerServing / basis
                carbsPerNative = carbsPerServing / basis
                fatPerNative = fatPerServing / basis
                satPerNative = satPerServing.map { $0 / basis }
                transPerNative = transPerServing.map { $0 / basis }
                monoPerNative = monoPerServing.map { $0 / basis }
                polyPerNative = polyPerServing.map { $0 / basis }
                cholPerNative = cholPerServing.map { $0 / basis }
                sodiumPerNative = sodiumPerServing.map { $0 / basis }
                fiberPerNative = fiberPerServing.map { $0 / basis }
                sugarsPerNative = sugarsPerServing.map { $0 / basis }
                addedSugarsPerNative = addedSugarsPerServing.map { $0 / basis }
                initialSelectedUnit = token
                initialSelectedQuantity = parsed.count
            } else {
                nativeUnit = token
                if let g = servingMassGrams { nativeUnitGrams = g / parsed.count }
                if ServingMath.isVolumeUnit(token) {
                    nativeUnitMilliliters = ServingMath.millilitersPerVolumeUnit[token]
                } else if let ml = servingMassMl {
                    nativeUnitMilliliters = ml / parsed.count
                }
                caloriesPerNative = caloriesPerServing / parsed.count
                proteinPerNative = proteinPerServing / parsed.count
                carbsPerNative = carbsPerServing / parsed.count
                fatPerNative = fatPerServing / parsed.count
                satPerNative = satPerServing.map { $0 / parsed.count }
                transPerNative = transPerServing.map { $0 / parsed.count }
                monoPerNative = monoPerServing.map { $0 / parsed.count }
                polyPerNative = polyPerServing.map { $0 / parsed.count }
                cholPerNative = cholPerServing.map { $0 / parsed.count }
                sodiumPerNative = sodiumPerServing.map { $0 / parsed.count }
                fiberPerNative = fiberPerServing.map { $0 / parsed.count }
                sugarsPerNative = sugarsPerServing.map { $0 / parsed.count }
                addedSugarsPerNative = addedSugarsPerServing.map { $0 / parsed.count }
                initialSelectedUnit = token
                initialSelectedQuantity = 1
            }
        }

        if nativeUnit == "ea" {
            if let mass = servingMassGrams, mass > 0 {
                nativeUnit = "g"
                nativeUnitGrams = 1
                let factor = mass
                caloriesPerNative = caloriesPerServing / factor
                proteinPerNative = proteinPerServing / factor
                carbsPerNative = carbsPerServing / factor
                fatPerNative = fatPerServing / factor
                satPerNative = satPerServing.map { $0 / factor }
                transPerNative = transPerServing.map { $0 / factor }
                monoPerNative = monoPerServing.map { $0 / factor }
                polyPerNative = polyPerServing.map { $0 / factor }
                cholPerNative = cholPerServing.map { $0 / factor }
                sodiumPerNative = sodiumPerServing.map { $0 / factor }
                fiberPerNative = fiberPerServing.map { $0 / factor }
                sugarsPerNative = sugarsPerServing.map { $0 / factor }
                addedSugarsPerNative = addedSugarsPerServing.map { $0 / factor }
                initialSelectedUnit = "g"
                initialSelectedQuantity = mass
            } else if let vol = servingMassMl, vol > 0 {
                nativeUnit = "ml"
                nativeUnitMilliliters = 1
                let factor = vol
                caloriesPerNative = caloriesPerServing / factor
                proteinPerNative = proteinPerServing / factor
                carbsPerNative = carbsPerServing / factor
                fatPerNative = fatPerServing / factor
                satPerNative = satPerServing.map { $0 / factor }
                transPerNative = transPerServing.map { $0 / factor }
                monoPerNative = monoPerServing.map { $0 / factor }
                polyPerNative = polyPerServing.map { $0 / factor }
                cholPerNative = cholPerServing.map { $0 / factor }
                sodiumPerNative = sodiumPerServing.map { $0 / factor }
                fiberPerNative = fiberPerServing.map { $0 / factor }
                sugarsPerNative = sugarsPerServing.map { $0 / factor }
                addedSugarsPerNative = addedSugarsPerServing.map { $0 / factor }
                initialSelectedUnit = "ml"
                initialSelectedQuantity = vol
            }
        }

        return FoodSearchResult(
            id: "off:\(barcode)",
            name: name,
            brand: brands,
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
            source: .barcode
        )
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
