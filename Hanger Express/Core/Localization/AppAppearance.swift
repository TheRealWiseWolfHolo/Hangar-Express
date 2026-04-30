import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "app.appearance"

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    @ViewBuilder
    var label: some View {
        switch self {
        case .system:
            Text("Follow System")
        case .light:
            Text("Light")
        case .dark:
            Text("Dark")
        }
    }

    static func resolved(from rawValue: String) -> AppAppearance {
        AppAppearance(rawValue: rawValue) ?? .system
    }
}
