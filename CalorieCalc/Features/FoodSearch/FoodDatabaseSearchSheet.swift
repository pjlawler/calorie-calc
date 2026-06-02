import SwiftUI

/// Minimal food-database search: just a search bar and the list of matches from the food
/// database (USDA + OpenFoodFacts). No recents, My Foods, tags, or sort — picking a result
/// hands it back so the caller can open the add-food portion sheet.
struct FoodDatabaseSearchSheet: View {
    let onPick: (FoodSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(FoodDataSourceEnvironment.self) private var dataSourceEnv

    @State private var viewModel: FoodSearchViewModel?
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            ResultsList(
                viewModel: viewModel,
                query: query,
                onPick: { result in
                    onPick(result)
                    dismiss()
                },
                onSearchCancelledWhileEmpty: { dismiss() }
            )
            .navigationTitle("Search Food Database")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .onChange(of: query) { oldValue, newValue in
                // Tapping the search bar's clear-X wipes the whole string in one step; manual
                // backspacing removes the last character one at a time. So only the multi-char
                // → empty jump (the clear-X) closes the sheet — backspacing to empty just clears
                // the search and stays put. The empty-field Cancel is handled by ResultsList.
                if newValue.isEmpty && oldValue.count >= 2 {
                    dismiss()
                    return
                }
                viewModel?.queryChanged(newValue)
            }
            .toolbar {
                // Leading edge so it stays clear of the search field's trailing chrome.
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = FoodSearchViewModel(dataSource: dataSourceEnv.dataSource)
                }
            }
        }
    }
}

/// The results list, split out so it can read `\.isSearching` (only available inside a
/// searchable container). When the user cancels the search with an empty field — the system
/// Cancel button to the right of an empty search bar — the whole sheet closes.
private struct ResultsList: View {
    let viewModel: FoodSearchViewModel?
    let query: String
    let onPick: (FoodSearchResult) -> Void
    let onSearchCancelledWhileEmpty: () -> Void

    @Environment(\.isSearching) private var isSearching

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if let vm = viewModel {
                if let error = vm.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                ForEach(vm.results) { result in
                    Button {
                        onPick(result)
                    } label: {
                        FoodResultRow(result: result)
                    }
                    .buttonStyle(.plain)
                }
                if vm.isSearching && vm.results.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                } else if vm.results.isEmpty && vm.errorMessage == nil && trimmedQuery.count >= 2 {
                    Text("No foods found for \"\(trimmedQuery)\".")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: isSearching) { _, searching in
            // Cancelling the search (the trailing Cancel button) while the field is empty
            // closes the sheet, matching the clear-X-with-text behavior.
            if !searching && trimmedQuery.isEmpty {
                onSearchCancelledWhileEmpty()
            }
        }
    }
}
