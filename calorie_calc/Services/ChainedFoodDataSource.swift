import Foundation

/// Tries each underlying source in order and returns the first non-empty / successful result.
/// Lets us stack providers — e.g. USDA for search, USDA then Open Food Facts for barcode lookups.
final class ChainedFoodDataSource: FoodDataSource, Sendable {

    private let sources: [any FoodDataSource]

    init(sources: [any FoodDataSource]) {
        self.sources = sources
    }

    func search(query: String) async throws -> [FoodSearchResult] {
        var lastError: Error?
        for source in sources {
            do {
                let results = try await source.search(query: query)
                if !results.isEmpty { return results }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return []
    }

    func details(for id: String) async throws -> FoodSearchResult {
        var lastError: Error?
        for source in sources {
            do {
                return try await source.details(for: id)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FoodDataSourceError.notFound
    }

    func lookup(barcode: String) async throws -> FoodSearchResult? {
        var lastError: Error?
        for source in sources {
            do {
                if let hit = try await source.lookup(barcode: barcode) {
                    return hit
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }
}
