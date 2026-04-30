import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    nonisolated static let storageKey = "app.language"

    var id: Self { self }

    nonisolated var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        }
    }

    nonisolated var bundleLocalizationIdentifier: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    var shortLabel: String {
        switch self {
        case .system:
            return "Auto"
        case .english:
            return "EN"
        case .simplifiedChinese:
            return "中文"
        }
    }

    @ViewBuilder
    var label: some View {
        switch self {
        case .system:
            Text("Follow System")
        case .english:
            Text("English")
        case .simplifiedChinese:
            Text("简体中文")
        }
    }

    nonisolated static func resolved(from rawValue: String) -> AppLanguage {
        AppLanguage(rawValue: rawValue) ?? .system
    }
}
