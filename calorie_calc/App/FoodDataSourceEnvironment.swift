import Foundation

@Observable
@MainActor
final class FoodDataSourceEnvironment {
    let dataSource: FoodDataSource

    init(dataSource: FoodDataSource) {
        self.dataSource = dataSource
    }
}
