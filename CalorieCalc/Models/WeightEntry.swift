import Foundation
import SwiftData

@Model
final class WeightEntry {
    var id: UUID = UUID()

    var weight: Double = 0
    var unit: WeightUnit = WeightUnit.pounds
    var timestamp: Date = Date()
    var notes: String?

    init(
        id: UUID = UUID(),
        weight: Double,
        unit: WeightUnit,
        timestamp: Date = .now,
        notes: String? = nil
    ) {
        self.id = id
        self.weight = weight
        self.unit = unit
        self.timestamp = timestamp
        self.notes = notes
    }

    func weight(in other: WeightUnit) -> Double {
        unit.convert(weight, to: other)
    }
}
