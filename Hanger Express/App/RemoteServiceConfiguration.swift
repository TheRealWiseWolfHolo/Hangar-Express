import Foundation

nonisolated struct RemoteServiceConfiguration: Equatable, Sendable {
    let primaryBaseURL: URL?
    let fallbackBaseURL: URL?
    let translationBaseURL: URL?
    let ipRegionURL: URL?

    static let live = RemoteServiceConfiguration(
        primaryBaseURL: configuredURL(forInfoDictionaryKey: "RemotePrimaryBaseURL"),
        fallbackBaseURL: configuredURL(forInfoDictionaryKey: "RemoteFallbackBaseURL"),
        translationBaseURL: configuredURL(forInfoDictionaryKey: "RemoteTranslationBaseURL"),
        ipRegionURL: configuredURL(forInfoDictionaryKey: "RemoteIPRegionURL")
    )

    private static func configuredURL(forInfoDictionaryKey key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }
}
