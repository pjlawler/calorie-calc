import Foundation

/// One option in the food portion sheet's unit picker. The label is the unit token shown to the
/// user ("bar", "g", "oz"). Native options additionally annotate the gram weight of one native
/// unit ("bar (57g)") so the user knows what they're dealing with at a glance.
nonisolated struct ServingOption: Identifiable, Hashable, Sendable {
    let id: String
    let unit: String
    let label: String
}

nonisolated enum ServingMath {

    /// Mass conversions. Cup/tbsp/tsp belong to the *volume* table — they aren't here because we
    /// don't have density data to convert mass↔volume.
    static let gramsPerMassUnit: [String: Double] = [
        "g": 1,
        "kg": 1_000,
        "mg": 0.001,
        "oz": 28.3495,
        "lb": 453.592,
    ]

    static let millilitersPerVolumeUnit: [String: Double] = [
        "ml": 1,
        "l": 1_000,
        "fl oz": 29.5735,
        "cup": 236.588,
        "tbsp": 14.7868,
        "tsp": 4.92892,
    ]

    /// Recognized loose mass-unit tokens. When the API's "native" unit parses as one of these we
    /// don't treat it as a countable — the food is loose mass, native unit = "g".
    static let massUnitTokens: Set<String> = ["g", "gm", "gram", "grams", "kg", "kilogram", "kilograms",
                                              "mg", "milligram", "milligrams",
                                              "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds"]
    static let volumeUnitTokens: Set<String> = ["ml", "milliliter", "milliliters", "millilitre", "millilitres",
                                                "l", "liter", "liters", "litre", "litres",
                                                "fl oz", "floz", "fluid ounce", "fluid ounces",
                                                "tbsp", "tablespoon", "tablespoons",
                                                "tsp", "teaspoon", "teaspoons"]

    /// Parses a free-text serving description like "1 bar", "1/4 cup", "57 g", "240 ml" into
    /// `(count, unit)`. Strips parenthetical annotations ("1 bar (57g)" → "1 bar"). Supports
    /// integers, decimals, comma-decimals, and simple fractions like "1/4" or "1 1/2".
    static func parseServingDescription(_ description: String) -> (count: Double, unit: String)? {
        let cleaned = stripParenthetical(description).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // Try fraction first ("1 1/2 cup" / "1/2 cup").
        let mixedFraction = #"^(\d+)\s+(\d+)/(\d+)\s*(.*)$"#
        let simpleFraction = #"^(\d+)/(\d+)\s*(.*)$"#
        let decimal = #"^(\d+(?:[\.,]\d+)?)\s*(.*)$"#

        if let m = cleaned.firstMatch(of: try! Regex(mixedFraction)) {
            let whole = Double(m.output[1].substring ?? "") ?? 0
            let num = Double(m.output[2].substring ?? "") ?? 0
            let den = Double(m.output[3].substring ?? "") ?? 1
            let rest = String(m.output[4].substring ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (whole + num / den, rest)
        }
        if let m = cleaned.firstMatch(of: try! Regex(simpleFraction)) {
            let num = Double(m.output[1].substring ?? "") ?? 0
            let den = Double(m.output[2].substring ?? "") ?? 1
            let rest = String(m.output[3].substring ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (num / den, rest)
        }
        if let m = cleaned.firstMatch(of: try! Regex(decimal)) {
            let value = Double((m.output[1].substring ?? "").replacingOccurrences(of: ",", with: ".")) ?? 0
            let rest = String(m.output[2].substring ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (value, rest)
        }
        return nil
    }

    /// Normalizes parsed unit text into a stable token. "Bars" → "bar", "GRAMS" → "g", "fl. oz."
    /// → "fl oz". Returns the lowercased canonical form, suitable as a picker `unit` label.
    static func normalizeUnitToken(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return "" }
        // Strip trailing punctuation and common suffixes.
        let stripped = trimmed.replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        // Direct alias normalization for measurement units.
        let aliases: [String: String] = [
            "gm": "g", "gram": "g", "grams": "g",
            "kilogram": "kg", "kilograms": "kg",
            "milligram": "mg", "milligrams": "mg",
            "ounce": "oz", "ounces": "oz",
            "pound": "lb", "pounds": "lb", "lbs": "lb",
            "milliliter": "ml", "milliliters": "ml", "millilitre": "ml", "millilitres": "ml",
            "liter": "l", "liters": "l", "litre": "l", "litres": "l",
            "floz": "fl oz", "fluid ounce": "fl oz", "fluid ounces": "fl oz",
            "tablespoon": "tbsp", "tablespoons": "tbsp",
            "teaspoon": "tsp", "teaspoons": "tsp",
            "cups": "cup",
        ]
        if let canon = aliases[stripped] { return canon }

        // Singularize trailing 's' for countable nouns (bar/bars, slice/slices) — but leave units
        // already canonical alone.
        if stripped.hasSuffix("s") && stripped.count > 2 && !["fl oz"].contains(stripped) {
            let singular = String(stripped.dropLast())
            if !massUnitTokens.contains(stripped) && !volumeUnitTokens.contains(stripped) {
                return singular
            }
        }
        return stripped
    }

    /// True when the token represents a recognized mass unit (g/oz/lb…).
    static func isMassUnit(_ token: String) -> Bool {
        gramsPerMassUnit[token] != nil
    }

    /// True when the token represents a recognized volume unit (ml/cup/tbsp…).
    static func isVolumeUnit(_ token: String) -> Bool {
        millilitersPerVolumeUnit[token] != nil
    }

    /// True when the token is a measurement unit (mass or volume) — so it should NOT be treated
    /// as a countable native ("g" is a unit of mass, not a thing you can count individually).
    static func isMeasurementUnit(_ token: String) -> Bool {
        massUnitTokens.contains(token) || volumeUnitTokens.contains(token) || isMassUnit(token) || isVolumeUnit(token)
    }

    /// Grams represented by `quantity` of `selectedUnit`. nil if `selectedUnit` is the food's
    /// native countable and we'd have to go through `nativeUnitGrams` (caller handles that).
    static func grams(forSelectedUnit unit: String, quantity: Double) -> Double? {
        guard let perUnit = gramsPerMassUnit[unit] else { return nil }
        return quantity * perUnit
    }

    /// Extracts a gram weight from a parenthetical in a serving description.
    /// "1 cup (85g)" → 85, "2 cookies (32 g)" → 32, "1 bar (57g)" → 57. Returns
    /// nil when no `(NNN g)` clause exists. Used to disambiguate APIs that report a
    /// `serving_quantity` number without telling us whether it's grams or ml.
    static func extractGramsFromParenthetical(_ description: String) -> Double? {
        extractValueFromParenthetical(description, unitPattern: #"g(?:r(?:ams?)?)?\b"#)
    }

    /// Extracts a milliliter weight from a parenthetical. "1 fl oz (30ml)" → 30,
    /// "8 fl oz (240 ml)" → 240. Same role as `extractGramsFromParenthetical`.
    static func extractMillilitersFromParenthetical(_ description: String) -> Double? {
        extractValueFromParenthetical(description, unitPattern: #"ml\b|milliliters?\b|millilitres?\b"#)
    }

    private static func extractValueFromParenthetical(_ description: String, unitPattern: String) -> Double? {
        let pattern = "\\(\\s*(\\d+(?:[\\.,]\\d+)?)\\s*(?i:\(unitPattern))\\s*\\)"
        guard let regex = try? Regex(pattern),
              let match = description.firstMatch(of: regex),
              let raw = match.output[1].substring else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    static func milliliters(forSelectedUnit unit: String, quantity: Double) -> Double? {
        guard let perUnit = millilitersPerVolumeUnit[unit] else { return nil }
        return quantity * perUnit
    }

    /// Renders a count-and-unit pair the way the user wants to see it: never pluralized.
    /// "1 bar", "2 bar", "0.5 bar", "114 g", "1 ea". Strips trailing zeros.
    nonisolated static func displayConsumed(quantity: Double, unit: String) -> String {
        formatNumber(quantity) + " " + unit
    }

    /// Number of native units consumed given the entry's selectedUnit and quantity.
    /// `selectedUnit == nativeUnit`: 1:1, the user typed native units directly.
    /// `selectedUnit` is mass and `nativeUnitGrams` known: convert via grams.
    /// `selectedUnit` is volume and `nativeUnitMilliliters` known: convert via ml.
    /// Otherwise: fall back to `quantity` (best-effort; shouldn't happen for valid foods).
    nonisolated static func nativeUnitsConsumed(
        selectedUnit: String,
        quantity: Double,
        nativeUnit: String,
        nativeUnitGrams: Double?,
        nativeUnitMilliliters: Double?
    ) -> Double {
        if selectedUnit == nativeUnit { return quantity }
        if let gPerNative = nativeUnitGrams, gPerNative > 0,
           let g = grams(forSelectedUnit: selectedUnit, quantity: quantity) {
            return g / gPerNative
        }
        if let mlPerNative = nativeUnitMilliliters, mlPerNative > 0,
           let ml = milliliters(forSelectedUnit: selectedUnit, quantity: quantity) {
            return ml / mlPerNative
        }
        return quantity
    }

    /// Picker option list for a food. Always includes the native unit (when present and not a
    /// bare measurement). Adds mass siblings (g/oz/lb) when grams are known and volume siblings
    /// (ml/L/fl oz/cup/tbsp/tsp) when ml is known. For a loose mass food (native="g"), the
    /// picker is just the mass family — same for loose volume.
    nonisolated static func options(
        nativeUnit: String,
        nativeUnitGrams: Double?,
        nativeUnitMilliliters: Double?
    ) -> [ServingOption] {
        var options: [ServingOption] = []
        var seenUnits = Set<String>()

        let nativeIsMeasurement = isMeasurementUnit(nativeUnit)

        if !nativeUnit.isEmpty && !nativeIsMeasurement {
            let label = nativeUnitGrams.map { "\(nativeUnit) (\(formatNumber($0))g)" } ?? nativeUnit
            options.append(ServingOption(id: nativeUnit, unit: nativeUnit, label: label))
            seenUnits.insert(nativeUnit)
        }

        let hasGrams = (nativeUnitGrams ?? 0) > 0 || isMassUnit(nativeUnit)
        let hasMl = (nativeUnitMilliliters ?? 0) > 0 || isVolumeUnit(nativeUnit)

        if hasGrams {
            for unit in ["g", "oz", "lb", "kg"] {
                if !seenUnits.contains(unit) {
                    options.append(ServingOption(id: unit, unit: unit, label: unit))
                    seenUnits.insert(unit)
                }
            }
        }
        if hasMl {
            for unit in ["ml", "fl oz", "cup", "tbsp", "tsp", "l"] {
                if !seenUnits.contains(unit) {
                    options.append(ServingOption(id: unit, unit: unit, label: unit))
                    seenUnits.insert(unit)
                }
            }
        }

        // Last-resort fallback: a food with no native, no mass, no volume info — show "ea".
        if options.isEmpty {
            options.append(ServingOption(id: "ea", unit: "ea", label: "ea"))
        }
        return options
    }
}

nonisolated private func stripParenthetical(_ s: String) -> String {
    var result = ""
    var depth = 0
    for c in s {
        if c == "(" { depth += 1; continue }
        if c == ")" { depth = max(0, depth - 1); continue }
        if depth == 0 { result.append(c) }
    }
    return result
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

nonisolated func formatNumber(_ v: Double) -> String {
    if v.isNaN || v.isInfinite { return "0" }
    if v.truncatingRemainder(dividingBy: 1) == 0 {
        return String(Int(v))
    }
    return v.formatted(.number.precision(.fractionLength(0...2)))
}
