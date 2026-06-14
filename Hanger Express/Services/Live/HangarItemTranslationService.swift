import Foundation

nonisolated struct HostedHangarItemTranslationClient: Sendable {
    struct FetchedDictionary: Sendable {
        let dictionary: HangarItemTranslationDictionary
        let data: Data
    }

    let language: HangarItemLanguage
    let urls: [URL]
    let urlSession: URLSession

    init(
        language: HangarItemLanguage,
        urls: [URL]? = nil,
        urlSession: URLSession = .shared
    ) {
        self.language = language
        self.urls = urls ?? HostedShipFeedEndpoints.itemTranslationURLs(for: language)
        self.urlSession = urlSession
    }

    func fetchDictionary() async throws -> FetchedDictionary {
        guard let expectedLocale = language.translationLocaleIdentifier else {
            throw HostedShipCatalogError.invalidItemTranslationFeed("Original item language does not have a remote feed.")
        }

        var lastError: Error?

        for url in urls {
            do {
                let (data, response) = try await urlSession.data(for: Self.makeRequest(for: url))

                if let httpResponse = response as? HTTPURLResponse,
                   !(200 ..< 300).contains(httpResponse.statusCode) {
                    throw HostedShipCatalogError.httpStatus(httpResponse.statusCode)
                }

                return FetchedDictionary(
                    dictionary: try Self.decodeDictionary(from: data, expectedLocale: expectedLocale),
                    data: data
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? HostedShipCatalogError.httpStatus(-1)
    }

    static func decodeDictionary(
        from data: Data,
        expectedLocale: String? = nil
    ) throws -> HangarItemTranslationDictionary {
        let payload = try JSONDecoder().decode(RemoteHangarItemTranslationPayload.self, from: data)

        if let count = payload.count, count != payload.entries.count {
            throw HostedShipCatalogError.invalidItemTranslationFeed(
                "Count \(count) does not match \(payload.entries.count) entries."
            )
        }

        return try HangarItemTranslationDictionary(
            locale: payload.locale,
            version: payload.version,
            generatedAt: payload.generatedAt,
            entries: payload.entries.map {
                HangarItemTranslationDictionary.Entry(
                    source: $0.source,
                    translation: $0.translation,
                    kind: $0.kind,
                    aliases: $0.aliases ?? []
                )
            },
            expectedLocale: expectedLocale
        )
    }

    private static func makeRequest(for url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    }
}

actor HostedHangarItemTranslationStore {
    static let shared = HostedHangarItemTranslationStore()

    private var cachedDictionaries: [HangarItemLanguage: HangarItemTranslationDictionary] = [:]
    private let fileManager: FileManager
    private let directoryURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
    }

    func dictionary(
        for language: HangarItemLanguage,
        using client: HostedHangarItemTranslationClient,
        preferCachedData: Bool = false
    ) async -> HangarItemTranslationDictionary? {
        guard language.translationLocaleIdentifier != nil else {
            cachedDictionaries[language] = nil
            return nil
        }

        if let cachedDictionary = cachedDictionaries[language] {
            return cachedDictionary
        }

        if preferCachedData,
           let cachedDictionary = loadDictionaryFromDisk(for: language) {
            cachedDictionaries[language] = cachedDictionary
            return cachedDictionary
        }

        do {
            let fetchedDictionary = try await client.fetchDictionary()
            cachedDictionaries[language] = fetchedDictionary.dictionary
            save(fetchedDictionary.data, for: language)
            return fetchedDictionary.dictionary
        } catch {
            guard let cachedDictionary = loadDictionaryFromDisk(for: language) else {
                return nil
            }

            cachedDictionaries[language] = cachedDictionary
            return cachedDictionary
        }
    }

    func clear() {
        cachedDictionaries.removeAll()
        try? fileManager.removeItem(at: directoryURL)
    }

    private func save(_ data: Data, for language: HangarItemLanguage) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: language), options: [.atomic])
        } catch {
#if DEBUG
            print("HostedHangarItemTranslationStore failed to save \(language.rawValue): \(error)")
#endif
        }
    }

    private func loadDictionaryFromDisk(for language: HangarItemLanguage) -> HangarItemTranslationDictionary? {
        guard let expectedLocale = language.translationLocaleIdentifier,
              let data = try? Data(contentsOf: fileURL(for: language)) else {
            return nil
        }

        do {
            return try HostedHangarItemTranslationClient.decodeDictionary(
                from: data,
                expectedLocale: expectedLocale
            )
        } catch {
            try? fileManager.removeItem(at: fileURL(for: language))
            return nil
        }
    }

    private func fileURL(for language: HangarItemLanguage) -> URL {
        directoryURL.appendingPathComponent("\(language.rawValue).json", isDirectory: false)
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return appSupportURL
            .appendingPathComponent("HangerExpress", isDirectory: true)
            .appendingPathComponent("ItemTranslations", isDirectory: true)
    }
}

private nonisolated struct RemoteHangarItemTranslationPayload: Decodable {
    let locale: String
    let version: Int
    let generatedAt: String?
    let count: Int?
    let entries: [RemoteHangarItemTranslationEntry]
}

private nonisolated struct RemoteHangarItemTranslationEntry: Decodable {
    let source: String
    let translation: String
    let kind: String
    let aliases: [String]?
}
