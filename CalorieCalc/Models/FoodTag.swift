import Foundation
import SwiftData
import SwiftUI

/// User-defined label that can be attached to one or many `CachedFood` records.
/// Lives in the synced (CloudKit) schema so tag definitions and the food→tag
/// edges roam across devices alongside the rest of the user's catalogue.
///
/// No `@Attribute(.unique)` on `name` — CloudKit doesn't support unique
/// constraints on synced entities. Case-insensitive de-duplication happens at
/// the call sites that create new tags from picker input.
@Model
final class FoodTag {
    var id: UUID = UUID()
    var name: String = ""
    var colorRaw: String = FoodTagColor.blue.rawValue
    var createdAt: Date = Date()

    /// Inverse of `CachedFood.tags`. CloudKit + SwiftData require to-many
    /// relationships to be optional — non-optional `[CachedFood] = []` crashes the
    /// container at launch with "to-many relationships must be optional". Default
    /// `[]` keeps the value populated; `foodsList` below gives read-only consumers
    /// a non-optional view.
    var foods: [CachedFood]? = []

    /// Non-optional read accessor.
    var foodsList: [CachedFood] { foods ?? [] }

    var color: FoodTagColor {
        get { FoodTagColor(rawValue: colorRaw) ?? .blue }
        set { colorRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        color: FoodTagColor = .blue,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorRaw = color.rawValue
        self.createdAt = createdAt
    }
}

/// Limited palette so the picker renders as a fixed swatch grid. Stored as the
/// raw string on `FoodTag.colorRaw`; the SwiftUI `Color` is derived via `swiftUIColor`.
nonisolated enum FoodTagColor: String, Codable, CaseIterable, Hashable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown

    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        }
    }
}
