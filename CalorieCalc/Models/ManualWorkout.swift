import Foundation
import SwiftData

@Model
final class ManualWorkout {
    var id: UUID = UUID()

    var name: String = ""
    var durationSeconds: Int = 0
    var caloriesBurned: Double = 0
    var notes: String?
    var timestamp: Date = Date()

    var dayLog: DayLog?

    init(
        id: UUID = UUID(),
        name: String,
        durationSeconds: Int,
        caloriesBurned: Double,
        notes: String? = nil,
        timestamp: Date = .now,
        dayLog: DayLog? = nil
    ) {
        self.id = id
        self.name = name
        self.durationSeconds = durationSeconds
        self.caloriesBurned = caloriesBurned
        self.notes = notes
        self.timestamp = timestamp
        self.dayLog = dayLog
    }

    var durationMinutes: Int { durationSeconds / 60 }
}
