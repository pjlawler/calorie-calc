import Foundation

/// A picker option in the food portion sheet. Encodes how to scale the food's per-serving
/// nutrients when the user picks it: `servingsPerUnit` is "1 of this option" expressed in
/// native servings, so amount × servingsPerUnit × numServings = native-serving multiplier.
nonisolated struct ServingOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let servingsPerUnit: Double
}

/// Render a native serving description multiplied by `multiplier` — e.g. "1 bar" × 2 → "2 bars",
/// "100 g" × 1.5 → "150 g", "0.67 cup" × 2 → "1.34 cups". Strips parenthetical annotations like
/// "(130g)" before pluralizing. Falls back to "<multiplier> × <label>" when the leading number
/// can't be parsed.
nonisolated func renderNativeServing(label: String, multiplier: Double) -> String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        let isOne = abs(multiplier - 1) < 0.0001
        return formatServingNumber(multiplier) + (isOne ? " serving" : " servings")
    }
    if let split = splitLeadingNumber(trimmed) {
        let total = split.value * multiplier
        let cleanRest = stripParenthetical(split.rest)
        if cleanRest.isEmpty {
            return formatServingNumber(total)
        }
        return formatServingNumber(total) + " " + pluralizeServingUnit(cleanRest, count: total)
    }
    if abs(multiplier - 1) < 0.0001 {
        return trimmed
    }
    let cleanWhole = stripParenthetical(trimmed)
    let unitText = cleanWhole.isEmpty ? trimmed : cleanWhole
    return formatServingNumber(multiplier) + " " + pluralizeServingUnit(unitText, count: multiplier)
}

/// Render the consumed portion of a `FoodEntry`-shaped serving. When the stored description
/// has no leading number (legacy USDA-style shapes like "serving (100g)"), prefer the total
/// mass or volume — that's what was actually consumed and avoids ugly pluralization fallouts.
nonisolated func renderConsumedServing(
    description: String,
    quantity: Double,
    grams: Double?,
    milliliters: Double?
) -> String {
    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasLeadingNumber = trimmed.first.map { $0.isNumber } ?? false
    if !hasLeadingNumber {
        if let g = grams, g > 0 {
            return formatServingNumber(g * quantity) + " g"
        }
        if let ml = milliliters, ml > 0 {
            return formatServingNumber(ml * quantity) + " ml"
        }
    }
    return renderNativeServing(label: description, multiplier: quantity)
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

nonisolated private func splitLeadingNumber(_ s: String) -> (value: Double, rest: String)? {
    var prefix = ""
    var idx = s.startIndex
    while idx < s.endIndex {
        let c = s[idx]
        if c.isNumber || c == "." || c == "," {
            prefix.append(c)
            idx = s.index(after: idx)
        } else { break }
    }
    guard !prefix.isEmpty,
          let value = Double(prefix.replacingOccurrences(of: ",", with: "."))
    else { return nil }
    let rest = String(s[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return (value, rest)
}

nonisolated private func pluralizeServingUnit(_ phrase: String, count: Double) -> String {
    if abs(count - 1) < 0.0001 { return phrase }
    let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return phrase }
    let lower = trimmed.lowercased()
    // Measurement-style units don't pluralize: "200 g" not "200 gs".
    let nonPlural: Set<String> = [
        "g", "kg", "mg", "oz", "lb", "ml", "l",
        "fl oz", "tbsp", "tsp", "kcal", "cal"
    ]
    if nonPlural.contains(lower) { return phrase }
    if lower.hasSuffix("s") { return phrase }
    var words = phrase.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard !words.isEmpty else { return phrase }
    words[words.count - 1] = words.last! + "s"
    return words.joined(separator: " ")
}

nonisolated private func formatServingNumber(_ v: Double) -> String {
    v.truncatingRemainder(dividingBy: 1) == 0
        ? String(Int(v))
        : v.formatted(.number.precision(.fractionLength(0...2)))
}

extension FoodSearchResult {
    /// Per-food picker options. Always starts with the food's native serving (the default
    /// selection), then adds per-unit options scoped to whichever native dimension is known —
    /// mass units when grams known, volume units when ml known. Both are added when both are
    /// known (cross-family) so a 0.67 cup / 87 g serving exposes cup AND gram units in one
    /// picker.
    var servingOptions: [ServingOption] {
        var options: [ServingOption] = []

        let nativeRaw = servingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeLabel = nativeRaw.isEmpty ? "1 serving" : nativeRaw
        options.append(ServingOption(id: "native", label: nativeLabel, servingsPerUnit: 1.0))

        if let g = servingSizeGrams, g > 0 {
            options.append(ServingOption(id: "g",  label: "g",  servingsPerUnit: 1.0     / g))
            options.append(ServingOption(id: "kg", label: "kg", servingsPerUnit: 1_000   / g))
            options.append(ServingOption(id: "oz", label: "oz", servingsPerUnit: 28.3495 / g))
            options.append(ServingOption(id: "lb", label: "lb", servingsPerUnit: 453.592 / g))
        }
        if let ml = servingSizeMilliliters, ml > 0 {
            options.append(ServingOption(id: "ml",    label: "ml",    servingsPerUnit: 1.0     / ml))
            options.append(ServingOption(id: "L",     label: "L",     servingsPerUnit: 1_000   / ml))
            options.append(ServingOption(id: "fl_oz", label: "fl oz", servingsPerUnit: 29.5735 / ml))
            options.append(ServingOption(id: "cup",   label: "cup",   servingsPerUnit: 236.588 / ml))
            options.append(ServingOption(id: "tbsp",  label: "tbsp",  servingsPerUnit: 14.7868 / ml))
            options.append(ServingOption(id: "tsp",   label: "tsp",   servingsPerUnit: 4.92892 / ml))
        }

        return options
    }
}
