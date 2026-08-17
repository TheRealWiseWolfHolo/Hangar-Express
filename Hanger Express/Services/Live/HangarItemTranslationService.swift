import CryptoKit
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

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw HostedShipCatalogError.invalidItemTranslationFeed(
                        "The translation feed did not return an HTTP response."
                    )
                }
                if !(200 ..< 300).contains(httpResponse.statusCode) {
                    throw HostedShipCatalogError.httpStatus(httpResponse.statusCode)
                }

                let dictionary = try Self.decodeDictionary(
                    from: data,
                    expectedLocale: expectedLocale
                )
                try Self.verifyResponseMetadata(
                    data: data,
                    response: httpResponse,
                    dictionary: dictionary,
                    requiresMetadata: RemoteServiceConfiguration.live.translationBaseURL.map {
                        url.host == $0.host
                    } ?? false
                )
                return FetchedDictionary(
                    dictionary: dictionary,
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

    static func verifyResponseMetadata(
        data: Data,
        response: HTTPURLResponse,
        dictionary: HangarItemTranslationDictionary,
        requiresMetadata: Bool
    ) throws {
        let checksum = response.value(
            forHTTPHeaderField: "x-content-sha256"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = response.value(
            forHTTPHeaderField: "x-dictionary-version"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = response.value(
            forHTTPHeaderField: "x-dictionary-entry-count"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entityTag = response.value(
            forHTTPHeaderField: "etag"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        if requiresMetadata,
           checksum == nil || version == nil || count == nil || entityTag == nil {
            throw HostedShipCatalogError.invalidItemTranslationFeed(
                "The remote translation feed is missing integrity metadata."
            )
        }

        if let checksum {
            let actualChecksum = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard checksum.count == 64,
                  checksum == checksum.lowercased(),
                  checksum.allSatisfy(\.isHexDigit),
                  checksum == actualChecksum else {
                throw HostedShipCatalogError.invalidItemTranslationFeed(
                    "The translation feed checksum does not match its body."
                )
            }
        }
        if let version {
            guard Int(version) == dictionary.version else {
                throw HostedShipCatalogError.invalidItemTranslationFeed(
                    "The translation feed version header does not match its body."
                )
            }
        }
        if let count {
            guard Int(count) == dictionary.entries.count else {
                throw HostedShipCatalogError.invalidItemTranslationFeed(
                    "The translation feed entry-count header does not match its body."
                )
            }
        }
        if let entityTag {
            guard !entityTag.isEmpty, entityTag.count <= 256 else {
                throw HostedShipCatalogError.invalidItemTranslationFeed(
                    "The translation feed ETag is invalid."
                )
            }
        }
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

    func refreshDictionary(
        for language: HangarItemLanguage,
        using client: HostedHangarItemTranslationClient
    ) async throws -> HangarItemTranslationDictionary {
        let fetchedDictionary = try await client.fetchDictionary()
        cachedDictionaries[language] = fetchedDictionary.dictionary
        save(fetchedDictionary.data, for: language)
        return fetchedDictionary.dictionary
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
