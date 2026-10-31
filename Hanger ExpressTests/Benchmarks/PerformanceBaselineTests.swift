import Darwin
import CryptoKit
import Foundation
import UIKit
import XCTest
@testable import Hanger_Express

@MainActor
final class PerformanceBaselineTests: XCTestCase {
    private var checksum = 0
    private var measurements: [[String: Any]] = []
    private let samples = 5

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HANGAR_RUN_BENCHMARKS"] == "1")
        executionTimeAllowance = 600
    }

    func testPresentationIndexComparison() async throws {
        let resources = TestResources()
        let service = OnDeviceHangarItemTranslationService(directoryURL: resources.temporaryDirectory())
        await service.prepareCache()
        let context = service.searchContext(using: .original)
        let builder = InventoryPresentationBuilder()
        let searches = InventorySearchBuilder()
        var records: [[String: Any]] = []
        for count in [1_000, 10_000] {
            let workload = BenchmarkInventory.makeBuybackHeavy(pledgeCount: count)
            let snapshot = workload.snapshot.updatingBuyback(buyback: Array(workload.snapshot.buyback.prefix(count)))
            let key = InventoryPresentationKey(accountID: workload.session.id, hangarRevision: 1, buybackRevision: 1, contentEpoch: UInt64(count))
            let before = footprint()
            let buildStart = DispatchTime.now().uptimeNanoseconds
            let presentation = try await builder.build(snapshot: snapshot, key: key)
            let searchKey = InventorySearchKey(presentation: key, language: "original", dictionaryLocale: nil,
                                               dictionaryVersion: nil, cacheGeneration: service.cacheGeneration, upgradedNames: false)
            let index = try await searches.index(presentation: presentation, context: context, key: searchKey)
            let buildMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart) / 1e6
            let indexedFootprint = footprint()
            var oldTimes: [Double] = [], indexedTimes: [Double] = []
            for query in ["lot 1", "lot 12", "lot 123", "lot 124", "lot 12"] {
                let oldStart = DispatchTime.now().uptimeNanoseconds
                let old = autoreleasepool {
                    snapshot.buyback.groupedForBuybackDisplay.filter {
                        service.buybackSearchableText(for: $0.representative, using: .original).contains(query)
                    }.map(\.id)
                }
                oldTimes.append(Double(DispatchTime.now().uptimeNanoseconds - oldStart) / 1e6)
                let compiledQuery = InventorySearchQuery(query)
                let newStart = DispatchTime.now().uptimeNanoseconds
                let result = presentation.buyback.filter { index.buyback[$0.id]?.contains(compiledQuery) == true }.map(\.id)
                indexedTimes.append(Double(DispatchTime.now().uptimeNanoseconds - newStart) / 1e6)
                XCTAssertEqual(result, old)
                checksum += result.count
            }
            records.append(["inventoryPledges":count,"buybacks":snapshot.buyback.count,"buildMs":buildMs,
                "legacyQueryMs":oldTimes,"indexedQueryMs":indexedTimes,"footprintBeforeBytes":before,
                "footprintWithIndexBytes":indexedFootprint,"allResultIDsMatch":true])
        }
        let report: [String:Any] = ["schemaVersion":1,"workloads":records,
            "limits":"One Release simulator diagnostic; five different warmed queries per workload. Legacy grouping/search paths use current stable IDs; new timings exclude the reported one-time index build. Footprints are process observations, not allocation attribution or physical-device ceilings."]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "presentation-comparison.json"; attachment.lifetime = .keepAlways; add(attachment)
        withExtendedLifetime(resources) {}
    }

    func testCPUIsolationWorkload() async throws {
        let resources = TestResources()
        let rows = 100
        let html = CPUWorkerFixtures.html(rows: rows)
        let url = URL(string: "https://robertsspaceindustries.com/en/account/pledges?page=1&pagesize=50")!
        let remote = try (1...1_000).map { try CPUWorkerFixtures.pledge(id: $0) }
        let worker = HangarInventoryNormalizer()
        let engine = HangarInventoryNormalizationEngine()
        let session = resources.session { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html.utf8))
        }
        let client = RSIAccountHTTPPageClient(cookies: [], session: session)
        if ProcessInfo.processInfo.environment["HANGAR_BENCHMARK_PROFILE_DELAY"] == "1" {
            try await Task.sleep(for: .seconds(45))
        }
        let referenceInterval = PerformanceTrace.begin("CPUReferenceMain")
        let referenceStart = DispatchTime.now().uptimeNanoseconds
        var iterations = 0
        repeat {
            iterations += 1
            let page = try RSIAccountHTMLParser.parsePledgePage(html: html, pageURL: url, requestedURL: url, statusCode: 200, cookieCount: 0)
            checksum += page.items.count
            checksum += try engine.hangar(remote, catalog: nil).fleet.count
        } while DispatchTime.now().uptimeNanoseconds - referenceStart < 5_000_000_000
        let referenceMs = Double(DispatchTime.now().uptimeNanoseconds - referenceStart) / 1e6
        PerformanceTrace.end("CPUReferenceMain", referenceInterval)
        let movedInterval = PerformanceTrace.begin("CPUWorker")
        let workerStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let page = try await client.fetchPledgePage(page: 1, pageSize: 50)
            checksum += page.items.count
            checksum += try await worker.hangar(remote, catalog: nil).fleet.count
        }
        PerformanceTrace.end("CPUWorker", movedInterval)
        let workerMs = Double(DispatchTime.now().uptimeNanoseconds - workerStart) / 1e6
        XCTAssertGreaterThan(iterations, 0)
        XCTAssertEqual(checksum, 2 * iterations * (100 + 1_000))
        print("CPU_COMPARISON iterations=\(iterations) referenceMs=\(referenceMs) workerMs=\(workerMs)")
        withExtendedLifetime(resources) {}
    }

    func testInventoryStages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = TestResources()
        defer { withExtendedLifetime(resources) {} }
        let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        var datasets: [[String: Any]] = []
        for count in BenchmarkInventory.sizes {
            let workload = autoreleasepool { BenchmarkInventory.make(pledgeCount: count) }
            let snapshot = workload.snapshot
            let other = autoreleasepool { BenchmarkInventory.make(pledgeCount: count, accountIndex: 1) }
            defer {
                withExtendedLifetime(workload) {}
                withExtendedLifetime(other) {}
            }
            let encoded = try encoder().encode(snapshot)
            let groups = snapshot.packages.groupedForInventoryDisplay
            let buybackGroups = snapshot.buyback.groupedForBuybackDisplay
            let ships = CCUUpgradeCatalogShip.makeShips(from: workload.catalog)
            let source = try XCTUnwrap(ships.first)
            let target = try XCTUnwrap(ships.last)
            let translationService = OnDeviceHangarItemTranslationService(directoryURL: root.appendingPathComponent("translation"))
            await translationService.prepareCache()
            let sources = Array(Set(snapshot.buyback.map(\.title))).sorted()
            let dictionary = try HangarItemTranslationDictionary(
                locale: "zh-Hans", version: 1, generatedAt: nil,
                entries: sources.enumerated().map { index, source in
                    .init(source: source, translation: "基准物品\(index)", kind: "package", aliases: [])
                }
            )
            let chinese = HangarItemTranslator(language: .simplifiedChinese, dictionary: dictionary)
            let footprintBefore = footprint()

            try record("json_encode", count: count) { try self.encoder().encode(snapshot).count }
            try record("json_decode", count: count) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(HangarSnapshot.self, from: encoded).packages.count
            }
            record("normalize_ship_keys", count: count) {
                snapshot.packages.flatMap(\.contents).reduce(0) { $0 + UpgradeTitleParser.normalizedShipKey($1.title).utf8.count }
            }
            record("fleet_projection", count: count) {
                FleetProjector.project(packages: snapshot.packages, shipCatalog: workload.catalog).count
            }
            record("group_hangar", count: count) { snapshot.packages.groupedForInventoryDisplay.count }
            record("group_fleet", count: count) { snapshot.fleet.groupedForFleetDisplay.count }
            record("group_buyback", count: count) { snapshot.buyback.groupedForBuybackDisplay.count }
            record("hangar_group_ids", count: count) { groups.reduce(0) { $0 + $1.id.utf8.count } }
            record("buyback_search_en_pipeline", count: count) {
                snapshot.buyback.groupedForBuybackDisplay.filter {
                    translationService.buybackSearchableText(for: $0.representative, using: .original).contains("ship 12")
                }.count
            }
            record("buyback_search_cn_pipeline", count: count) {
                snapshot.buyback.groupedForBuybackDisplay.filter {
                    translationService.buybackSearchableText(for: $0.representative, using: chinese).contains("基准")
                }.count
            }
            // A warm, prebuilt text scan is a kernel baseline, not a measurement
            // of the private Hangar/Fleet view caches or the rendered search UI.
            let haystacks = snapshot.fleet.map { translationService.fleetSearchableText(for: $0, using: .original) }
            record("fleet_warm_text_scan", count: count) { haystacks.filter { $0.contains("ship 12") }.count }
            record("ccu_route", count: count) {
                CCUUpgradePlanner.bestRoute(from: source, to: target, snapshot: snapshot, catalogShips: ships)?.steps.count ?? 0
            }
            record("partial_snapshot_account_copy", count: count) {
                snapshot.updatingAccount(
                    avatarURL: nil, primaryOrganization: nil, didRefreshPrimaryOrganization: false,
                    storeCreditUSD: 501, totalSpendUSD: 1_000, referralStats: .unavailable
                ).packages.count
            }
            record("two_account_group_switch", count: count) {
                snapshot.packages.groupedForInventoryDisplay.count + other.snapshot.packages.groupedForInventoryDisplay.count
            }
            let model = makeModel(workload: workload, defaults: resources.defaults)
            for scope in [AppModel.RefreshScope.full, .hangar, .account] {
                try await recordAsync("fixture_refresh_\(scope)", count: count) {
                    await model.refresh(scope: scope)
                    return model.snapshot?.packages.count ?? 0
                }
            }
            let store = FileSnapshotStore(directoryURL: root.appendingPathComponent("snapshot-\(count)"))
            try await recordAsync("snapshot_save", count: count) {
                try await store.save(snapshot, for: workload.session)
                return snapshot.packages.count
            }
            try await recordAsync("snapshot_load_warm", count: count) {
                try await store.load(for: workload.session)?.packages.count ?? 0
            }
            let files = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("snapshot-\(count)"), includingPropertiesForKeys: [.fileSizeKey]
            )
            let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            datasets.append([
                "pledges": count, "fleet": snapshot.fleet.count, "buybacks": snapshot.buyback.count,
                "hangarGroups": groups.count, "buybackGroups": buybackGroups.count,
                "jsonBytes": encoded.count, "snapshotDiskBytes": bytes,
                "physicalFootprintBeforeBytes": footprintBefore, "physicalFootprintAfterBytes": footprint(),
                "syntheticAccounts": 2, "catalogShips": ships.count, "networkRequests": 0
            ])
            let restored = try await store.load(for: workload.session)
            XCTAssertEqual(restored?.packages.count, count)
        }
        let report: [String: Any] = [
            "schemaVersion": 1, "fixtureVersion": BenchmarkInventory.version,
            "build": ProcessInfo.processInfo.environment["HANGAR_BENCHMARK_BUILD"] ?? "unspecified",
            "deviceModel": model(), "os": UIDevice.current.systemVersion,
            "isSimulator": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] != nil,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "thermalStateStart": thermalStart, "thermalStateEnd": ProcessInfo.processInfo.thermalState.rawValue,
            "sampleCount": samples, "warmupCount": 1, "checksum": checksum,
            "datasets": datasets, "measurements": measurements
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "performance-baseline.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSupplementalStages() async throws {
        let instrumented = ProcessInfo.processInfo.environment["HANGAR_BENCHMARK_PROFILE_DELAY"] == "1"
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        if instrumented { UIApplication.shared.isIdleTimerDisabled = true }
        defer { if instrumented { UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled } }
        // A separate diagnostic run gives Instruments time to attach before
        // fixture/image allocations. It is excluded from latency baselines.
        if instrumented { try await Task.sleep(for: .seconds(15)) }
        let resources = TestResources()
        defer { withExtendedLifetime(resources) {} }
        let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        let workload = BenchmarkInventory.makeBuybackHeavy(pledgeCount: 1_000)
        defer { withExtendedLifetime(workload) {} }
        let snapshot = workload.snapshot
        let groups = snapshot.buyback.groupedForBuybackDisplay
        XCTAssertEqual(groups.count, 2_000)
        let translation = OnDeviceHangarItemTranslationService(directoryURL: resources.temporaryDirectory())
        let dictionary = try HangarItemTranslationDictionary(
            locale: "zh-Hans", version: 1, generatedAt: nil,
            entries: snapshot.buyback.enumerated().map { index, item in
                .init(source: item.title, translation: "基准回购物品\(index)", kind: "package", aliases: [])
            }
        )
        let chinese = HangarItemTranslator(language: .simplifiedChinese, dictionary: dictionary)
        let footprintBefore = footprint()
        record("supplement_group_buyback_unique", count: 1_000) { snapshot.buyback.groupedForBuybackDisplay.count }
        record("supplement_buyback_search_en", count: 1_000) {
            snapshot.buyback.groupedForBuybackDisplay.filter {
                translation.buybackSearchableText(for: $0.representative, using: .original).contains("ship 12")
            }.count
        }
        record("supplement_buyback_search_cn", count: 1_000) {
            snapshot.buyback.groupedForBuybackDisplay.filter {
                translation.buybackSearchableText(for: $0.representative, using: chinese).contains("基准")
            }.count
        }

        let payload = autoreleasepool { benchmarkImageData() }
        XCTAssertFalse(payload.isEmpty)
        let requests = BenchmarkImageRequestCounter()
        let url = try XCTUnwrap(URL(string: "https://image-benchmark.example.invalid/first.jpg"))
        let targetURL = try XCTUnwrap(URL(string: "https://image-benchmark.example.invalid/second.jpg"))
        let session = resources.session { request in
            requests.increment()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "image/jpeg"])!, payload)
        }
        let offline = resources.session { _ in throw URLError(.notConnectedToInternet) }
        let imageDirectory = resources.temporaryDirectory()
        let store = URLCachedImageStore(cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
                                        session: session, storageDirectoryURL: imageDirectory)
        let pointSize = CGSize(width: 84, height: 84)
        let scale: CGFloat = 3
        var calls: [String: Int] = [:]
        var diskBytes: [String: Int] = [:]
        func measureImage(_ name: String, expectedCalls: Int,
                          prepare: @MainActor () async throws -> Void = {},
                          operation: @MainActor () async throws -> Int) async throws {
            let before = requests.value
            let traceName: StaticString
            switch name {
            case "image_mock_miss_first_draw": traceName = "ImageMockMiss"
            case "image_memory_hit_first_draw": traceName = "ImageMemoryHit"
            case "image_disk_restore_first_draw": traceName = "ImageDiskRestore"
            case "image_composite_mock_miss_first_draw": traceName = "ImageCompositeMiss"
            case "image_composite_memory_hit_first_draw": traceName = "ImageCompositeMemoryHit"
            default: traceName = "ImageCoalescedBatch"
            }
            try await recordPrepared(name, count: 1_000, prepare: prepare) {
                let interval = instrumented ? PerformanceTrace.begin(traceName) : nil
                defer { if let interval { PerformanceTrace.end(traceName, interval) } }
                return try await operation()
            }
            calls[name] = requests.value - before
            diskBytes[name] = try directoryBytes(imageDirectory)
            XCTAssertEqual(calls[name], expectedCalls, "Mock requests include one warmup and five samples")
        }
        try await measureImage("image_mock_miss_first_draw", expectedCalls: 6, prepare: { await store.clear() }) {
            let image = try await store.image(for: url, targetPointSize: pointSize, displayScale: scale, maxRetries: 1)
            return self.benchmarkDraw(image)
        }
        try await measureImage("image_memory_hit_first_draw", expectedCalls: 0) {
            let image = try await store.image(for: url, targetPointSize: pointSize, displayScale: scale, maxRetries: 1)
            return self.benchmarkDraw(image)
        }
        var restored: URLCachedImageStore?
        try await measureImage("image_disk_restore_first_draw", expectedCalls: 0, prepare: {
            restored = URLCachedImageStore(cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
                                           session: offline, storageDirectoryURL: imageDirectory)
        }) {
            let image = try await restored!.image(for: url, targetPointSize: pointSize, displayScale: scale, maxRetries: 1)
            return self.benchmarkDraw(image)
        }
        try await measureImage("image_composite_mock_miss_first_draw", expectedCalls: 12, prepare: { await store.clear() }) {
            let image = try await store.compositeImage(sourceURL: url, targetURL: targetURL,
                                                      targetPointSize: pointSize, displayScale: scale, maxRetries: 1)
            return self.benchmarkDraw(image)
        }
        try await measureImage("image_composite_memory_hit_first_draw", expectedCalls: 0) {
            let image = try await store.compositeImage(sourceURL: url, targetURL: targetURL,
                                                      targetPointSize: pointSize, displayScale: scale, maxRetries: 1)
            return self.benchmarkDraw(image)
        }
        try await measureImage("image_mock_16_coalesced", expectedCalls: 6, prepare: { await store.clear() }) {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        let image = try await store.image(for: url, targetPointSize: pointSize, displayScale: scale, maxRetries: 1)
                        return image.cgImage?.width ?? 0
                    }
                }
                var pixels = 0
                for try await width in group { pixels += width }
                return pixels
            }
        }
        let encoded = try encoder().encode(snapshot)
        let snapshotDirectory = resources.temporaryDirectory()
        let snapshotStore = FileSnapshotStore(directoryURL: snapshotDirectory)
        try await snapshotStore.save(snapshot, for: workload.session)
        let report: [String: Any] = [
            "schemaVersion": 1, "fixtureVersion": BenchmarkInventory.version,
            "workloadVariant": "buyback-heavy-unique-and-generated-images-v1",
            "instrumentedDiagnostic": instrumented,
            "build": ProcessInfo.processInfo.environment["HANGAR_BENCHMARK_BUILD"] ?? "unspecified",
            "deviceModel": model(), "os": UIDevice.current.systemVersion,
            "isSimulator": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] != nil,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "thermalStateStart": thermalStart, "thermalStateEnd": ProcessInfo.processInfo.thermalState.rawValue,
            "sampleCount": samples, "warmupCount": 1, "checksum": checksum,
            "imageFixture": ["width": 2_048, "height": 1_024, "jpegBytes": payload.count,
                             "targetPoints": 84, "displayScale": 3,
                             "jpegSHA256": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()],
            "mockRequestsByStage": calls, "imageDiskBytesAfterStage": diskBytes,
            "datasets": [["pledges": 1_000, "fleet": snapshot.fleet.count, "buybacks": snapshot.buyback.count,
                          "hangarGroups": snapshot.packages.groupedForInventoryDisplay.count,
                          "buybackGroups": groups.count, "jsonBytes": encoded.count,
                          "snapshotDiskBytes": try directoryBytes(snapshotDirectory),
                          "physicalFootprintBeforeBytes": footprintBefore, "physicalFootprintAfterBytes": footprint(),
                          "syntheticAccounts": 1, "networkRequests": 0]],
            "measurements": measurements
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "performance-supplement.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Separate from timing baselines: kernel high-water counters include the
    /// host/framework startup and cannot be reset or attributed to one stage.
    func testMemoryHighWater() async throws {
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled }
        let resources = TestResources()
        defer { withExtendedLifetime(resources) {} }
        let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        var checkpoints: [[String: Any]] = []
        func checkpoint(_ name: String) throws {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            // Older kernels may return a shorter revision. Never turn missing
            // peak counters into a successful zero-valued memory measurement.
            let peakEnd = try XCTUnwrap(MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak)) + MemoryLayout<Int64>.size
            guard status == KERN_SUCCESS, Int(count) * MemoryLayout<integer_t>.size >= peakEnd,
                  info.ledger_phys_footprint_peak > 0 else {
                throw NSError(domain: "MemoryBenchmark", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Kernel peak footprint counter unavailable"])
            }
            XCTAssertGreaterThanOrEqual(UInt64(info.ledger_phys_footprint_peak), info.phys_footprint)
            XCTAssertGreaterThanOrEqual(info.resident_size_peak, info.resident_size)
            checkpoints.append([
                "checkpoint": name, "physicalFootprintBytes": info.phys_footprint,
                "peakPhysicalFootprintBytes": info.ledger_phys_footprint_peak,
                "residentBytes": info.resident_size, "peakResidentBytes": info.resident_size_peak,
                "returnedTaskInfoWords": count
            ])
        }
        try checkpoint("host_start")
        // Keep both inventories and intermediate outputs alive, matching the
        // standard fixture's largest two-account workload. No live account data.
        func inventory() async throws {
            let first = BenchmarkInventory.make(pledgeCount: 10_000)
            let second = BenchmarkInventory.make(pledgeCount: 10_000, accountIndex: 1)
            let groups = first.snapshot.packages.groupedForInventoryDisplay
            let otherGroups = second.snapshot.packages.groupedForInventoryDisplay
            let projected = FleetProjector.project(packages: first.snapshot.packages, shipCatalog: first.catalog)
            let encoded = try encoder().encode(first.snapshot)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(HangarSnapshot.self, from: encoded)
            let store = FileSnapshotStore(directoryURL: resources.temporaryDirectory())
            try await store.save(first.snapshot, for: first.session)
            let restored = try await store.load(for: first.session)
            XCTAssertEqual(decoded.packages.count, 10_000)
            XCTAssertEqual(restored?.packages.count, 10_000)
            XCTAssertEqual(projected.count, first.snapshot.fleet.count)
            try checkpoint("two_10000_pledge_accounts_with_projection_json_and_restore")
            withExtendedLifetime((first, second, groups, otherGroups, projected, encoded, decoded, restored)) {}
        }
        try await inventory()
        try checkpoint("after_inventory_scope")
        let heavy = BenchmarkInventory.makeBuybackHeavy(pledgeCount: 1_000)
        let buybacks = heavy.snapshot.buyback.groupedForBuybackDisplay
        XCTAssertEqual(buybacks.count, 2_000)
        try checkpoint("1000_pledges_2000_unique_buybacks")
        let payload = autoreleasepool { benchmarkImageData() }
        let requests = BenchmarkImageRequestCounter()
        let session = resources.session { request in
            requests.increment()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "image/jpeg"])!, payload)
        }
        let directory = resources.temporaryDirectory()
        let store = URLCachedImageStore(cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
                                        session: session, storageDirectoryURL: directory)
        var images: [UIImage] = []
        for index in 0..<16 {
            let url = try XCTUnwrap(URL(string: "https://image-benchmark.example.invalid/memory-\(index).jpg"))
            let image = try await store.image(for: url, targetPointSize: CGSize(width: 84, height: 84),
                                              displayScale: 3, maxRetries: 1)
            XCTAssertEqual(benchmarkDraw(image), 252)
            images.append(image)
        }
        XCTAssertEqual(requests.value, 16)
        try checkpoint("16_distinct_cached_images_retained_after_first_draw")
        let imageDiskBytes = try directoryBytes(directory)
        await store.clear()
        images.removeAll()
        try checkpoint("after_cache_clear")
        withExtendedLifetime((heavy, buybacks)) {}
        let report: [String: Any] = [
            "schemaVersion": 1, "diagnostic": "process-memory-high-water-v1",
            "fixtureVersion": BenchmarkInventory.version, "deviceModel": model(),
            "os": UIDevice.current.systemVersion,
            "build": ProcessInfo.processInfo.environment["HANGAR_BENCHMARK_BUILD"] ?? "unspecified",
            "isSimulator": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] != nil,
            "thermalStateStart": thermalStart, "thermalStateEnd": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "imageCount": 16, "imageStubRequests": requests.value, "imageDiskBytes": imageDiskBytes,
            "imageJPEGBytes": payload.count,
            "imageJPEGSHA256": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            "physicalNetworkRequests": 0, "checkpoints": checkpoints
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "memory-high-water.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func recordPrepared(_ name: String, count: Int,
                                prepare: @MainActor () async throws -> Void,
                                operation: @MainActor () async throws -> Int) async throws {
        var timings: [Double] = []
        for iteration in 0...samples {
            try await prepare()
            let start = DispatchTime.now().uptimeNanoseconds
            checksum &+= try await operation()
            if iteration > 0 {
                timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
        }
        append(name, count: count, timings: timings)
    }

    private func benchmarkImageData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2_048, height: 1_024), format: format).image { context in
            for y in 0..<32 {
                for x in 0..<64 {
                    UIColor(red: CGFloat((x * 17 + y * 7) % 256) / 255,
                            green: CGFloat((x * 3 + y * 29) % 256) / 255,
                            blue: CGFloat((x * 31 + y * 11) % 256) / 255, alpha: 1).setFill()
                    context.fill(CGRect(x: x * 32, y: y * 32, width: 32, height: 32))
                }
            }
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }

    private func benchmarkDraw(_ image: UIImage) -> Int {
        autoreleasepool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            format.preferredRange = .standard
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: 84, height: 84), format: format).image { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: 84, height: 84))
            }
            return rendered.cgImage?.width ?? 0
        }
    }

    private func directoryBytes(_ directory: URL) throws -> Int {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
        }
        return total
    }

    private func makeModel(workload: BenchmarkInventory.Workload, defaults: UserDefaults) -> AppModel {
        let diagnostics = AuthenticationDiagnosticsStore()
        let environment = AppEnvironment(
            sessionStore: FakeSessionStore(storedSnapshot: .init(activeSession: workload.session, savedSessions: [workload.session])),
            snapshotStore: FakeSnapshotStore(snapshot: workload.snapshot),
            imageCache: FakeRemoteImageCache(),
            hangarRepository: FakeHangarRepository(
                snapshot: workload.snapshot, hangarSnapshot: workload.snapshot,
                buybackSnapshot: workload.snapshot, accountSnapshot: workload.snapshot
            ),
            sensitiveActionAuthorizer: PreviewSensitiveActionAuthorizer(),
            authService: PreviewAuthenticationService(diagnostics: diagnostics),
            recaptchaBroker: RecaptchaBroker(diagnostics: diagnostics),
            authIPRegionChecker: PreviewAuthenticationIPRegionChecker(),
            authDiagnostics: diagnostics, refreshDiagnostics: RefreshDiagnosticsStore(),
            subscriptionStore: SubscriptionStore(userDefaults: defaults, storeKitEnabled: false),
            userDefaults: defaults, responseCache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            shipCatalogStore: HostedShipCatalogStore(), shipDetailCatalogStore: HostedShipDetailCatalogStore()
        )
        let model = AppModel(environment: environment)
        model.session = workload.session
        model.savedSessions = [workload.session]
        model.loadState = .loaded(workload.snapshot)
        return model
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func record(_ stage: String, count: Int, operation: () throws -> Int) rethrows {
        checksum &+= try operation()
        var timings: [Double] = []
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = try autoreleasepool(invoking: operation)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            checksum &+= value
        }
        append(stage, count: count, timings: timings)
    }

    private func recordAsync(_ stage: String, count: Int, operation: () async throws -> Int) async throws {
        checksum &+= try await operation()
        var timings: [Double] = []
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = try await operation()
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            checksum &+= value
        }
        append(stage, count: count, timings: timings)
    }

    private func append(_ stage: String, count: Int, timings: [Double]) {
        let mean = timings.reduce(0, +) / Double(timings.count)
        let variance = timings.map { pow($0 - mean, 2) }.reduce(0, +) / Double(timings.count)
        measurements.append([
            "stage": stage, "pledges": count, "samplesMs": timings,
            "medianMs": timings.sorted()[timings.count / 2], "minMs": timings.min()!,
            "maxMs": timings.max()!, "standardDeviationMs": sqrt(variance),
            "coefficientOfVariation": mean > 0 ? sqrt(variance) / mean : 0
        ])
    }

    private func model() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

private final class BenchmarkImageRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
