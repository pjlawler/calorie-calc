import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum AppAppearance: String, CaseIterable, Hashable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static let storageKey = "app.appearance"

    #if canImport(UIKit)
    var uiInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Pushes the chosen style to every connected window AND every presented view controller in
    /// their stacks. Setting `overrideUserInterfaceStyle` only on the window sometimes fails to
    /// cascade to already-presented sheets (they keep their original trait collection), so we
    /// walk the `presentedViewController` chain to force each one to refresh.
    @MainActor
    static func apply(_ appearance: AppAppearance) {
        let style = appearance.uiInterfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
                var vc = window.rootViewController
                while let current = vc {
                    current.overrideUserInterfaceStyle = style
                    vc = current.presentedViewController
                }
            }
        }
    }
    #else
    /// macOS native uses SwiftUI's `.preferredColorScheme` end-to-end, so no UIKit override is
    /// needed. SwiftUI re-renders sheets correctly without the workaround required on iOS.
    @MainActor
    static func apply(_ appearance: AppAppearance) {}
    #endif
}
