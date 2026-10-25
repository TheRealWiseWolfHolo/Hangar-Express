#if DEBUG || HANGAR_BENCHMARKS
import Foundation
import UIKit

/// Opt-in developer profiling only. Never retain requests, URLs, headers,
/// credentials, response contents, remote addresses, or account identifiers.
nonisolated final class PerformanceNetworkMetrics: @unchecked Sendable {
    static let shared = PerformanceNetworkMetrics()
    static let enabled = ProcessInfo.processInfo.environment["HANGAR_NETWORK_PROFILE"] == "1"

    private struct Run: Encodable, Sendable {
        let id: Int
        let scope: String
        let startedUTC: String
        var elapsedMs: Double?
        var visibleError: Bool?
        var htmlTasksStarted = 0
        var metricCallbacks = 0
        var transactions = 0
        var redirects = 0
        var cacheTypes: [String: Int] = [:]
        var protocols: [String: Int] = [:]
        var requestHeaderBytes: Int64 = 0
        var requestBodyBytes: Int64 = 0
        var responseHeaderBytes: Int64 = 0
        var responseEncodedBodyBytes: Int64 = 0
        var responseDecodedBodyBytes: Int64 = 0
    }

    private struct Report: Encodable, Sendable {
        let schemaVersion = 1
        let coverage = "RSIAccountHTTPPageClient URLSession tasks only; browser/GraphQL, hosted feeds and image sessions are unobserved. Byte counters are Foundation-reported HTTP data, not TLS/packet overhead. Zero may mean unavailable. Callbacks may finish after the refresh; compare started/callback counts."
        let runnerState: String
        let runs: [Run]
    }

    private let lock = NSLock()
    private let writer = DispatchQueue(label: "HangarExpress.PerformanceMetadataWriter")
    private var runs: [Run] = []
    private var startedNS: [Int: UInt64] = [:]
    private var activeID: Int?
    private var nextID = 1
    private var runnerState = "not-started"

    func begin(scope: String) -> Int? {
        guard Self.enabled else { return nil }
        return lock.withLock {
            let id = nextID
            nextID += 1
            runs.append(Run(id: id, scope: scope, startedUTC: ISO8601DateFormatter().string(from: Date())))
            startedNS[id] = DispatchTime.now().uptimeNanoseconds
            activeID = id
            if runs.count > 10 {
                let removed = runs.removeFirst()
                startedNS[removed.id] = nil
            }
            return id
        }
    }

    func end(_ id: Int, visibleError: Bool) {
        lock.withLock {
            guard let index = runs.firstIndex(where: { $0.id == id }), let start = startedNS.removeValue(forKey: id) else { return }
            runs[index].elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            runs[index].visibleError = visibleError
            if activeID == id { activeID = nil }
            saveLocked()
        }
    }

    func delegateIfEnabled() -> (any URLSessionTaskDelegate)? {
        guard Self.enabled else { return nil }
        return lock.withLock {
            guard let id = activeID, let index = runs.firstIndex(where: { $0.id == id }) else { return nil }
            runs[index].htmlTasksStarted += 1
            return PerformanceRequestMetricsDelegate(owner: self, runID: id)
        }
    }

    fileprivate func record(_ metrics: URLSessionTaskMetrics, runID: Int) {
        lock.withLock {
            guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
            runs[index].metricCallbacks += 1
            runs[index].redirects += metrics.redirectCount
            for transaction in metrics.transactionMetrics {
                runs[index].transactions += 1
                let cacheType: String
                switch transaction.resourceFetchType {
                case .networkLoad: cacheType = "networkLoad"
                case .localCache: cacheType = "localCache"
                case .serverPush: cacheType = "serverPush"
                default: cacheType = "unknown"
                }
                runs[index].cacheTypes[cacheType, default: 0] += 1
                runs[index].protocols[transaction.networkProtocolName ?? "unavailable", default: 0] += 1
                runs[index].requestHeaderBytes += transaction.countOfRequestHeaderBytesSent
                runs[index].requestBodyBytes += transaction.countOfRequestBodyBytesSent
                runs[index].responseHeaderBytes += transaction.countOfResponseHeaderBytesReceived
                runs[index].responseEncodedBodyBytes += transaction.countOfResponseBodyBytesReceived
                runs[index].responseDecodedBodyBytes += transaction.countOfResponseBodyBytesAfterDecoding
            }
            // Most callbacks arrive before end. Late callbacks update the saved
            // run by immutable ID, never the next refresh's counters.
            if runs[index].elapsedMs != nil { saveLocked() }
        }
    }

    func setRunnerState(_ state: String) {
        guard Self.enabled else { return }
        lock.withLock { runnerState = state; saveLocked() }
    }

    /// Called with the lock held so report snapshots enqueue in revision order.
    private func saveLocked() {
        let report = Report(runnerState: runnerState, runs: runs)
        writer.async {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("HangerExpress/PerformanceProfile", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: directory.appendingPathComponent("refresh-metrics.json"), options: .atomic)
            } catch {
                // Profiling failure must not change refresh behavior.
            }
        }
    }
}

nonisolated private final class PerformanceRequestMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let owner: PerformanceNetworkMetrics
    let runID: Int
    init(owner: PerformanceNetworkMetrics, runID: Int) { self.owner = owner; self.runID = runID }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        owner.record(metrics, runID: runID)
    }
}

/// Automates only explicitly requested read-only scopes in a diagnostic build.
@MainActor
enum PerformanceLiveRefreshRunner {
    private static var didRun = false
    static func runIfRequested(_ model: AppModel) async {
        guard PerformanceNetworkMetrics.enabled, !didRun,
              let raw = ProcessInfo.processInfo.environment["HANGAR_LIVE_PROFILE_SCOPES"] else { return }
        didRun = true
        let scopes = raw.split(separator: ",").compactMap { value -> AppModel.RefreshScope? in
            switch value {
            case "account": .account
            case "hangar": .hangar
            case "buyback": .buyback
            default: nil
            }
        }
        let recorder = PerformanceNetworkMetrics.shared
        guard !scopes.isEmpty, scopes.count == raw.split(separator: ",").count else {
            recorder.setRunnerState("invalid-scopes")
            return
        }
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled }
        recorder.setRunnerState("waiting-for-bootstrap-refresh")
        do {
            for _ in 0..<2_400 {
                if !model.isRefreshing { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !model.isRefreshing, model.session != nil, model.snapshot != nil else {
                recorder.setRunnerState("blocked-no-loaded-session-or-refresh-busy")
                return
            }
            recorder.setRunnerState("running")
            for scope in scopes {
                try Task.checkCancellation()
                await model.refresh(scope: scope)
                if model.lastRefreshErrorMessage != nil {
                    recorder.setRunnerState("stopped-visible-refresh-error")
                    return
                }
            }
            // Let queued delegate callbacks settle outside the measured scopes.
            try await Task.sleep(for: .milliseconds(500))
            recorder.setRunnerState("complete")
        } catch {
            recorder.setRunnerState("cancelled")
        }
    }
}
#endif
