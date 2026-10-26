import Foundation
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct InventoryCPUWorkerTests {
    let resources = TestResources()

    @Test func workerUsesBackgroundExecutorAndMatchesSynchronousReference() async throws {
        let remote = try (1...100).map { try CPUWorkerFixtures.pledge(id: $0) }
        let reference = try HangarInventoryNormalizationEngine().hangar(remote, catalog: nil)
        let worker = HangarInventoryNormalizer()
        let mainThread = await worker.isMainThread()
        #expect(!mainThread)
        let result = try await worker.hangar(remote, catalog: nil)
        #expect(result.packages == reference.packages)
        #expect(result.fleet == reference.fleet)
        #expect(result.packages.count == 100)
    }

    @Test func cancelledNormalizationDoesNotReturnPartialInventory() async throws {
        let remote = try (1...100).map { try CPUWorkerFixtures.pledge(id: $0) }
        let worker = HangarInventoryNormalizer()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.hangar(remote, catalog: nil)
        }
        do { _ = try await task.value; Issue.record("Cancelled normalization returned inventory") }
        catch { #expect(error is CancellationError) }
    }

    @Test func directHTTPParserMatchesReferenceWithoutRunningOnTheMainThread() async throws {
        let html = CPUWorkerFixtures.html(rows: 10)
        let url = URL(string: "https://robertsspaceindustries.com/en/account/pledges?page=1&pagesize=50")!
        let reference = try RSIAccountHTMLParser.parsePledgePage(html: html, pageURL: url, requestedURL: url, statusCode: 200, cookieCount: 0)
        let session = resources.session { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html.utf8))
        }
        let client = RSIAccountHTTPPageClient(cookies: [], session: session)
        let parsed = try await client.fetchPledgePage(page: 1, pageSize: 50)
        // The actor path also asserts its executor immediately before parsing.
        #expect(parsed.pageSignature == reference.pageSignature)
        #expect(parsed.items.count == 10)
    }

    @Test func translationCacheReadinessLoadsInBackgroundAndClearFencesOldDiskResult() async throws {
        let arrived = TestGate(), release = TestGate()
        defer { Task { await release.open() } }
        let key = CacheKey(source: "Unlisted Ship", targetLocale: "zh-Hans", dictionaryVersion: 1)
        let service = OnDeviceHangarItemTranslationService(directoryURL: resources.temporaryDirectory(), loadOperation: { _ in
            #expect(!CPUWorkerFixtures.isMainThread())
            await arrived.open(); try? await release.wait()
            return PersistedTranslationCacheState(translations: [key: "未列出的飞船"], preprocessedLocales: ["zh-Hans"], preprocessedTranslationKeys: [key])
        })
        #expect(!service.isCacheReady)
        try await arrived.wait()
        await service.clear()
        await release.open()
        await service.prepareCache()
        #expect(service.isCacheReady)
        #expect(!service.hasAvailableCache(for: .simplifiedChinese))
    }

    @Test func readyTranslationCacheIsVisibleWithoutRestart() async throws {
        let key = CacheKey(source: "Unlisted Ship", targetLocale: "zh-Hans", dictionaryVersion: 1)
        let service = OnDeviceHangarItemTranslationService(directoryURL: resources.temporaryDirectory(), loadOperation: { _ in
            PersistedTranslationCacheState(translations: [key: "未列出的飞船"], preprocessedLocales: ["zh-Hans"], preprocessedTranslationKeys: [key])
        })
        let dictionary = try HangarItemTranslationDictionary(locale: "zh-Hans", version: 1, generatedAt: nil, entries: [.init(source: "Other", translation: "其他", kind: "item", aliases: [])])
        let translator = HangarItemTranslator(language: .simplifiedChinese, dictionary: dictionary)
        await service.prepareCache()
        #expect(service.isCacheReady)
        #expect(service.displayText(for: key.source, using: translator) == "未列出的飞船")
        #expect(service.cacheGeneration > 0)
    }
}

nonisolated enum CPUWorkerFixtures {
    static func isMainThread() -> Bool { Thread.isMainThread }
    static func pledge(id: Int) throws -> RemotePledge {
        try JSONDecoder().decode(RemotePledge.self, from: Data("""
        {"id":\(id),"title":"Standalone Ship \(id)","statusText":"Attributed","dateText":"Oct 25, 2026",
         "valueText":"$100.00","containsText":"Aegis Avenger Titan","alsoContains":["Lifetime Insurance"],
         "canGift":true,"canReclaim":true,"canUpgrade":true,
         "items":[{"title":"Aegis Avenger Titan","kind":"Ship","detail":"Light Freight"}]}
        """.utf8))
    }
    static func html(rows: Int) -> String {
        "<html><head><title>Your Hangar</title></head><body><div class='list-items'>" + (1...rows).map { id in
            """
            <div class='row'><input class='js-pledge-id' value='\(id)'><input class='js-pledge-name' value='Ship &amp; Pilot \(id)'>
            <input class='js-pledge-value' value='$100.00'><div class='date'>Oct 25, 2026</div>
            <div class='items-col'><span class='title'>Aegis Avenger Titan</span></div><span class='title'>Lifetime Insurance</span></div>
            """
        }.joined() + "</div></body></html>"
    }
}
