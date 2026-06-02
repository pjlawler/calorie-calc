import Foundation

/// Tries each underlying source in order and returns the first non-empty / successful result.
/// Text search and barcode lookups can use different orderings — USDA first for search (better
/// generic-food coverage), OFF first for barcodes (dedicated barcode endpoint).
/// Search results are post-filtered so every query token appears in the result's name or brand,
/// which cuts the long tail of matches where the query only lives in ingredients / categories.
final class ChainedFoodDataSource: FoodDataSource, Sendable {

    private let searchSources: [any FoodDataSource]
    private let barcodeSources: [any FoodDataSource]

    init(searchSources: [any FoodDataSource], barcodeSources: [any FoodDataSource]) {
        self.searchSources = searchSources
        self.barcodeSources = barcodeSources
    }

    func search(query: String) async throws -> [FoodSearchResult] {
        let tokens = Self.tokenize(query)
        guard !tokens.isEmpty else { return [] }

        var lastError: Error?
        var anySucceeded = false
        for source in searchSources {
            do {
                let raw = try await source.search(query: query)
                anySucceeded = true
                let filtered = raw.filter { Self.matches($0, tokens: tokens) }
                if !filtered.isEmpty { return filtered }
            } catch {
                lastError = error
            }
        }
        // If at least one source answered (even with zero matches after filtering), this is a
        // genuine "no results" — surface the empty state, not a flaky source's error. Only throw
        // when every source failed (a real outage / connectivity problem).
        if anySucceeded { return [] }
        if let lastError { throw lastError }
        return []
    }

    func details(for id: String) async throws -> FoodSearchResult {
        var lastError: Error?
        for source in searchSources {
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
        for source in barcodeSources {
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

    private static func tokenize(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func matches(_ result: FoodSearchResult, tokens: [String]) -> Bool {
        let haystack = "\(result.name) \(result.brand ?? "")".lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}
