import Foundation

@Observable
@MainActor
final class FoodSearchViewModel {

    var query: String = ""
    var results: [FoodSearchResult] = []
    var isSearching: Bool = false
    var errorMessage: String?

    private let dataSource: FoodDataSource
    private var searchTask: Task<Void, Never>?

    init(dataSource: FoodDataSource) {
        self.dataSource = dataSource
    }

    func queryChanged(_ newValue: String) {
        searchTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            errorMessage = nil
            return
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            await self.performSearch(trimmed)
        }
    }

    private func performSearch(_ query: String) async {
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await dataSource.search(query: query)
            if !Task.isCancelled {
                results = found
                errorMessage = nil
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                results = []
            }
        }
    }

    func lookup(barcode: String) async -> FoodSearchResult? {
        do {
            return try await dataSource.lookup(barcode: barcode)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }
}
