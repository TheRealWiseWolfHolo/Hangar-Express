import Foundation

enum AppLocalizer {
    nonisolated private static let defaultBundle = Bundle.main

    nonisolated static var currentLanguage: AppLanguage {
        AppLanguage.resolved(
            from: UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? AppLanguage.system.rawValue
        )
    }

    nonisolated static var currentLocale: Locale {
        currentLanguage.locale
    }

    nonisolated static func string(_ key: String) -> String {
        let localizedValue = resolvedBundle.localizedString(forKey: key, value: nil, table: nil)
        if localizedValue != key {
            return localizedValue
        }

        return defaultBundle.localizedString(forKey: key, value: key, table: nil)
    }

    nonisolated static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: currentLocale, arguments: arguments)
    }

    nonisolated static func displayDate(_ date: Date) -> String {
        if usesChineseDateFormat {
            return fixedDateFormatter(format: "yyyy/MM/dd").string(from: date)
        }

        return fixedDateFormatter(format: "MM/dd/yyyy").string(from: date)
    }

    nonisolated static func displayDateTime(_ date: Date) -> String {
        if usesChineseDateFormat {
            return fixedDateFormatter(format: "yyyy/MM/dd HH:mm").string(from: date)
        }

        let time = date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(currentLocale)
        )
        return "\(displayDate(date)) \(time)"
    }

    nonisolated static func displayDateTimeWithSeconds(_ date: Date) -> String {
        if usesChineseDateFormat {
            return fixedDateFormatter(format: "yyyy/MM/dd HH:mm:ss").string(from: date)
        }

        let time = date.formatted(
            Date.FormatStyle(date: .omitted, time: .standard)
                .locale(currentLocale)
        )
        return "\(displayDate(date)) \(time)"
    }

    nonisolated private static var resolvedBundle: Bundle {
        guard let localizationIdentifier = currentLanguage.bundleLocalizationIdentifier,
              let path = defaultBundle.path(forResource: localizationIdentifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return defaultBundle
        }

        return bundle
    }

    nonisolated private static var usesChineseDateFormat: Bool {
        currentLocale.language.languageCode?.identifier == "zh"
    }

    nonisolated private static func fixedDateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}
