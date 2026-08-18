import Foundation

enum AppLocalizer {
    nonisolated private static let defaultBundle = Bundle.main
    nonisolated private static let cache = LocalizationCache(defaultBundle: defaultBundle)

    nonisolated static var currentLanguage: AppLanguage {
        cache.currentLanguage
    }

    nonisolated static var currentLocale: Locale {
        cache.currentLocale
    }

    nonisolated static func updateCurrentLanguage(rawValue: String) {
        cache.updateLanguage(rawValue: rawValue)
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
        cache.bundle(for: currentLanguage)
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

private nonisolated final class LocalizationCache: @unchecked Sendable {
    private let lock = NSLock()
    private let defaultBundle: Bundle
    private let localizedBundles: [String: Bundle]
    private var language: AppLanguage?
    private var locale: Locale?

    init(defaultBundle: Bundle) {
        self.defaultBundle = defaultBundle
        localizedBundles = ["en", "zh-Hans"].reduce(into: [:]) { bundles, identifier in
            guard let path = defaultBundle.path(forResource: identifier, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return
            }
            bundles[identifier] = bundle
        }
    }

    var currentLanguage: AppLanguage {
        lock.withLock {
            if let language {
                return language
            }

            let resolved = AppLanguage.resolved(
                from: UserDefaults.standard.string(forKey: AppLanguage.storageKey)
                    ?? AppLanguage.system.rawValue
            )
            language = resolved
            locale = resolved.locale
            return resolved
        }
    }

    var currentLocale: Locale {
        lock.withLock {
            if let locale {
                return locale
            }

            let resolvedLanguage = language ?? AppLanguage.resolved(
                from: UserDefaults.standard.string(forKey: AppLanguage.storageKey)
                    ?? AppLanguage.system.rawValue
            )
            let resolvedLocale = resolvedLanguage.locale
            language = resolvedLanguage
            locale = resolvedLocale
            return resolvedLocale
        }
    }

    func updateLanguage(rawValue: String) {
        let resolved = AppLanguage.resolved(from: rawValue)
        lock.withLock {
            language = resolved
            locale = resolved.locale
        }
    }

    func bundle(for language: AppLanguage) -> Bundle {
        guard let identifier = language.bundleLocalizationIdentifier else {
            return defaultBundle
        }
        return localizedBundles[identifier] ?? defaultBundle
    }
}
