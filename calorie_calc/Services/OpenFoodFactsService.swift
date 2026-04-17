import Foundation

final class OpenFoodFactsService: FoodDataSource, Sendable {

    private let session: URLSession
    private let baseURL = URL(string: "https://world.openfoodfacts.org/api/v2")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String) async throws -> [FoodSearchResult] {
        // OFF has a text-search endpoint but results are globally-scoped and noisy.
        // We only use OFF as a barcode fallback — return empty so the chain moves on.
        []
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
            let (data, response) = try await session.data(from: url)
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

private struct OFFProduct: Decodable {
    let productName: String?
    let brands: String?
    let servingSize: String?
    let servingQuantity: FlexibleNumber?
    let nutriments: OFFNutriments?

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case brands
        case servingSize = "serving_size"
        case servingQuantity = "serving_quantity"
        case nutriments
    }

    func toSearchResult(barcode: String) -> FoodSearchResult {
        let name = (productName?.isEmpty == false ? productName : nil) ?? "Scanned product"
        let servingDescription = (servingSize?.isEmpty == false ? servingSize : nil) ?? "1 serving"
        let servingGrams = servingQuantity?.doubleValue

        let calories = nutriments?.perServing(servingKcal: \.energyKcalServing, per100g: \.energyKcal100g, servingGrams: servingGrams) ?? 0
        let protein = nutriments?.perServing(servingKcal: \.proteinsServing, per100g: \.proteins100g, servingGrams: servingGrams) ?? 0
        let carbs = nutriments?.perServing(servingKcal: \.carbsServing, per100g: \.carbs100g, servingGrams: servingGrams) ?? 0
        let fat = nutriments?.perServing(servingKcal: \.fatServing, per100g: \.fat100g, servingGrams: servingGrams) ?? 0

        return FoodSearchResult(
            id: "off:\(barcode)",
            name: name,
            brand: brands,
            servingDescription: servingDescription,
            servingSizeGrams: servingGrams,
            caloriesPerServing: calories,
            proteinPerServing: protein,
            carbsPerServing: carbs,
            fatPerServing: fat,
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

    enum CodingKeys: String, CodingKey {
        case energyKcalServing = "energy-kcal_serving"
        case energyKcal100g = "energy-kcal_100g"
        case proteinsServing = "proteins_serving"
        case proteins100g = "proteins_100g"
        case carbsServing = "carbohydrates_serving"
        case carbs100g = "carbohydrates_100g"
        case fatServing = "fat_serving"
        case fat100g = "fat_100g"
    }

    func perServing(
        servingKcal: KeyPath<OFFNutriments, Double?>,
        per100g: KeyPath<OFFNutriments, Double?>,
        servingGrams: Double?
    ) -> Double {
        if let direct = self[keyPath: servingKcal] { return direct }
        if let per100 = self[keyPath: per100g], let grams = servingGrams, grams > 0 {
            return per100 * (grams / 100)
        }
        return self[keyPath: per100g] ?? 0
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
