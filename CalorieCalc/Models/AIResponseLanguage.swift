import Foundation

/// User preference for what language AI features reply in. Defaults to the device language
/// (the long-standing food-AI behavior); the user can force English instead. Persisted via
/// `@AppStorage(AIResponseLanguage.storageKey)` in Settings and read by the AI services when
/// they build prompts.
nonisolated enum AIResponseLanguage: String, CaseIterable, Identifiable {
    case deviceLanguage
    case english

    static let storageKey = "ai.responseLanguage"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deviceLanguage: "Device language"
        case .english: "English"
        }
    }

    /// Current preference (where the Settings `@AppStorage` picker writes it).
    static var current: AIResponseLanguage {
        AIResponseLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .deviceLanguage
    }

    /// The device's primary language code (e.g. "es"), defaulting to "en".
    private static var deviceLanguageCode: String {
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        return Locale(identifier: preferred).language.languageCode?.identifier ?? "en"
    }

    /// `true` when the device language is English, so the device/English choice is moot and the
    /// Settings picker can be hidden.
    static var deviceIsEnglish: Bool { deviceLanguageCode == "en" }

    /// The device's primary language as an English name (e.g. "Spanish"), or "English" if it
    /// can't be resolved.
    static var deviceLanguageName: String {
        Locale(identifier: "en").localizedString(forLanguageCode: deviceLanguageCode) ?? "English"
    }

    /// English name of the language the AI should respond in, honoring the user's setting.
    /// Returns "English" when forced or when the device language is already English.
    static func resolvedLanguageName() -> String {
        switch current {
        case .english: return "English"
        case .deviceLanguage: return deviceLanguageName
        }
    }
}
