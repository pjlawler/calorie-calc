import Foundation
import SwiftData

/// One-shot importer for the CSV backup format produced by `exportDatabaseCSV`. Wipes the
/// existing SwiftData store and rebuilds it from the CSV.
///
/// Two CSV vintages are supported:
/// - **Legacy** (no `native_unit` column): didn't carry `servingDescription` either, so we
///   recover the unit by name+brand inference via `LegacyInference`. Per-serving math goes in
///   *as-is* (the CSV's `calories` column is already per-serving — multiplying by quantity at
///   render time gives the original total).
/// - **Lossless** (has `native_unit`): every important field is on the row, so we use it
///   verbatim and only fall back to inference if a column is blank.
@MainActor
enum CSVBackupImporter {

    struct ImportSummary {
        var profiles = 0
        var goalPeriods = 0
        var dayLogs = 0
        var foodEntries = 0
        var cachedFoods = 0
        var manualWorkouts = 0
        var weightEntries = 0
        var skipped: [String] = []
    }

    static func importBackup(from url: URL, into context: ModelContext) throws -> ImportSummary {
        let needsScopedAccess = url.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { url.stopAccessingSecurityScopedResource() } }

        let raw = try String(contentsOf: url, encoding: .utf8)
        let rows = CSVParser.parse(raw)
        guard let header = rows.first else { return ImportSummary() }

        let columns = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        var summary = ImportSummary()

        try wipe(context: context)

        var dayLogsById: [UUID: DayLog] = [:]
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterPlain = ISO8601DateFormatter()
        isoFormatterPlain.formatOptions = [.withInternetDateTime]

        func parseDate(_ s: String) -> Date? {
            if s.isEmpty { return nil }
            return isoFormatter.date(from: s) ?? isoFormatterPlain.date(from: s)
        }

        func column(_ row: [String], _ key: String) -> String {
            guard let idx = columns[key], idx < row.count else { return "" }
            return row[idx]
        }

        for row in rows.dropFirst() {
            guard !row.isEmpty else { continue }
            let type = column(row, "record_type")
            switch type {
            case "user_profile":
                let profile = UserProfile(
                    id: UUID(uuidString: column(row, "id")) ?? UUID(),
                    dailyNetCalorieGoal: Int(column(row, "daily_net_goal")) ?? 1_600,
                    dailyGrossCalorieGoal: Int(column(row, "daily_gross_goal")) ?? 1_800,
                    dailyWorkoutCalorieGoal: Int(column(row, "daily_workout_goal")) ?? 500,
                    bankSplit: BankSplit(rawValue: column(row, "bank_split")) ?? .fiveTwo,
                    weekStart: Weekday(rawValue: Int(column(row, "week_start")) ?? 2) ?? .monday
                )
                context.insert(profile)
                summary.profiles += 1

            case "goal_period":
                guard let start = parseDate(column(row, "start_date")) else {
                    summary.skipped.append("goal_period missing start_date")
                    continue
                }
                let period = GoalPeriod(
                    id: UUID(uuidString: column(row, "id")) ?? UUID(),
                    startDate: start,
                    endDate: parseDate(column(row, "end_date")),
                    dailyNetCalorieGoal: Int(column(row, "daily_net_goal")) ?? 1_600,
                    dailyGrossCalorieGoal: Int(column(row, "daily_gross_goal")) ?? 1_800,
                    dailyWorkoutCalorieGoal: Int(column(row, "daily_workout_goal")) ?? 500,
                    bankSplit: BankSplit(rawValue: column(row, "bank_split")) ?? .fiveTwo,
                    weekStart: Weekday(rawValue: Int(column(row, "week_start")) ?? 2) ?? .monday
                )
                context.insert(period)
                summary.goalPeriods += 1

            case "day_log":
                guard let date = parseDate(column(row, "date")) else {
                    summary.skipped.append("day_log missing date")
                    continue
                }
                let id = UUID(uuidString: column(row, "id")) ?? UUID()
                let log = DayLog(id: id, date: date)
                context.insert(log)
                dayLogsById[id] = log
                summary.dayLogs += 1

            case "food_entry":
                let id = UUID(uuidString: column(row, "id")) ?? UUID()
                let name = column(row, "name")
                let brand = column(row, "brand").nilIfEmpty
                let qty = Double(column(row, "quantity")) ?? 1
                let cals = Double(column(row, "calories")) ?? 0
                let protein = Double(column(row, "protein")) ?? 0
                let carbs = Double(column(row, "carbs")) ?? 0
                let fat = Double(column(row, "fat")) ?? 0

                // Resolve native unit/grams: prefer explicit columns from a lossless export;
                // fall back to name-based inference for legacy CSVs.
                let nativeFromColumn = column(row, "native_unit")
                let nativeUnit: String
                let nativeUnitGrams: Double?
                let nativeUnitMl: Double?
                let selectedUnit: String
                if !nativeFromColumn.isEmpty {
                    nativeUnit = nativeFromColumn
                    nativeUnitGrams = Double(column(row, "native_unit_grams"))
                    nativeUnitMl = Double(column(row, "native_unit_ml"))
                    let sel = column(row, "selected_unit")
                    selectedUnit = sel.isEmpty ? nativeUnit : sel
                } else {
                    // Legacy CSV: no serving info. Import as "ea" — the user's existing on-device
                    // store goes through `LegacyDataMigrator` for proper conversion; CSVs are a
                    // last-resort path with reduced fidelity.
                    nativeUnit = "ea"
                    nativeUnitGrams = nil
                    nativeUnitMl = nil
                    selectedUnit = "ea"
                }

                let entry = FoodEntry(
                    id: id,
                    name: name,
                    brand: brand,
                    nativeUnit: nativeUnit,
                    nativeUnitGrams: nativeUnitGrams,
                    nativeUnitMilliliters: nativeUnitMl,
                    selectedUnit: selectedUnit,
                    quantity: qty,
                    // Legacy CSV stored `caloriesPerServing` directly — already per-native-unit
                    // semantically. No division needed: total = caloriesPerServing × quantity.
                    caloriesPerServing: cals,
                    proteinPerServing: protein,
                    carbsPerServing: carbs,
                    fatPerServing: fat,
                    mealType: MealType(rawValue: column(row, "meal_type")) ?? .snack,
                    source: FoodSource(rawValue: column(row, "source")) ?? .manual,
                    externalId: nil,
                    notes: column(row, "notes").nilIfEmpty,
                    timestamp: parseDate(column(row, "timestamp")) ?? .now,
                    dayLog: dayLogsById[UUID(uuidString: column(row, "day_log_id")) ?? UUID()]
                )
                context.insert(entry)
                summary.foodEntries += 1

            case "cached_food":
                let id = UUID(uuidString: column(row, "id")) ?? UUID()
                let name = column(row, "name")
                let brand = column(row, "brand").nilIfEmpty

                let nativeFromColumn = column(row, "native_unit")
                let nativeUnit: String
                let nativeUnitGrams: Double?
                let nativeUnitMl: Double?
                let lastSelectedUnit: String?
                if !nativeFromColumn.isEmpty {
                    nativeUnit = nativeFromColumn
                    nativeUnitGrams = Double(column(row, "native_unit_grams"))
                    nativeUnitMl = Double(column(row, "native_unit_ml"))
                    lastSelectedUnit = column(row, "selected_unit").nilIfEmpty
                } else {
                    nativeUnit = "ea"
                    nativeUnitGrams = nil
                    nativeUnitMl = nil
                    lastSelectedUnit = nil
                }

                let cached = CachedFood(
                    id: id,
                    externalId: nil,
                    name: name,
                    brand: brand,
                    nativeUnit: nativeUnit,
                    nativeUnitGrams: nativeUnitGrams,
                    nativeUnitMilliliters: nativeUnitMl,
                    lastSelectedUnit: lastSelectedUnit,
                    lastSelectedQuantity: lastSelectedUnit == nil ? nil : 1,
                    caloriesPerServing: Double(column(row, "calories")) ?? 0,
                    proteinPerServing: Double(column(row, "protein")) ?? 0,
                    carbsPerServing: Double(column(row, "carbs")) ?? 0,
                    fatPerServing: Double(column(row, "fat")) ?? 0,
                    source: FoodSource(rawValue: column(row, "source")) ?? .manual,
                    isFavorite: false,
                    lastUsed: parseDate(column(row, "timestamp")) ?? .now,
                    useCount: 1,
                    notes: column(row, "notes").nilIfEmpty
                )
                context.insert(cached)
                summary.cachedFoods += 1

            case "manual_workout":
                let id = UUID(uuidString: column(row, "id")) ?? UUID()
                let workout = ManualWorkout(
                    id: id,
                    name: column(row, "name"),
                    durationSeconds: Int(column(row, "duration_seconds")) ?? 0,
                    caloriesBurned: Double(column(row, "calories_burned")) ?? 0,
                    notes: column(row, "notes").nilIfEmpty,
                    timestamp: parseDate(column(row, "timestamp")) ?? .now,
                    dayLog: dayLogsById[UUID(uuidString: column(row, "day_log_id")) ?? UUID()]
                )
                context.insert(workout)
                summary.manualWorkouts += 1

            case "weight_entry":
                let id = UUID(uuidString: column(row, "id")) ?? UUID()
                let entry = WeightEntry(
                    id: id,
                    weight: Double(column(row, "weight")) ?? 0,
                    unit: WeightUnit(rawValue: column(row, "unit")) ?? .pounds,
                    timestamp: parseDate(column(row, "timestamp")) ?? .now,
                    notes: column(row, "notes").nilIfEmpty
                )
                context.insert(entry)
                summary.weightEntries += 1

            default:
                summary.skipped.append("unknown record_type: \(type)")
            }
        }

        try context.save()
        return summary
    }

    private static func wipe(context: ModelContext) throws {
        try context.delete(model: FoodEntry.self)
        try context.delete(model: CachedFood.self)
        try context.delete(model: ManualWorkout.self)
        try context.delete(model: WeightEntry.self)
        try context.delete(model: DayLog.self)
        try context.delete(model: GoalPeriod.self)
        try context.delete(model: UserProfile.self)
        try context.save()
    }
}

/// Minimal RFC-4180-ish CSV parser. Handles double-quoted fields, embedded commas, embedded
/// newlines, and `""` escapes. Doesn't validate field counts — caller indexes by column name.
enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        var i = text.startIndex

        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        currentField.append("\"")
                        i = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                    i = text.index(after: i)
                } else {
                    currentField.append(c)
                    i = text.index(after: i)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                    i = text.index(after: i)
                case ",":
                    currentRow.append(currentField)
                    currentField = ""
                    i = text.index(after: i)
                case "\r":
                    i = text.index(after: i)
                case "\n":
                    currentRow.append(currentField)
                    currentField = ""
                    rows.append(currentRow)
                    currentRow = []
                    i = text.index(after: i)
                default:
                    currentField.append(c)
                    i = text.index(after: i)
                }
            }
        }
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }
        return rows
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
