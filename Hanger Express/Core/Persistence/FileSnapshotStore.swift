import Foundation

actor FileSnapshotStore: SnapshotStore {
    private let directoryURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
    }

    private nonisolated struct Envelope: Codable {
        let schemaVersion: Int
        let snapshot: HangarSnapshot
    }

    func load(for session: UserSession) async throws -> HangarSnapshot? {
        let interval = PerformanceTrace.begin("SnapshotLoad")
        defer { PerformanceTrace.end("SnapshotLoad", interval) }
        let data: Data
        do { data = try Data(contentsOf: fileURL(for: session)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch { throw SnapshotStorageError.unavailable }
        do {
            let decoder = Self.makeDecoder()
            // Inspect the envelope before attempting legacy decoding: a future
            // schema must never be mistaken for an old snapshot and overwritten.
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["schemaVersion"] != nil {
                guard object["schemaVersion"] as? Int == 1 else { throw SnapshotStorageError.unsupportedVersion }
                let envelope = try decoder.decode(Envelope.self, from: data)
                guard envelope.schemaVersion == 1 else { throw SnapshotStorageError.unsupportedVersion }
                return envelope.snapshot
            }
            return try decoder.decode(HangarSnapshot.self, from: data)
        } catch let error as SnapshotStorageError { throw error }
        catch { throw SnapshotStorageError.corrupted }
    }

    func save(_ snapshot: HangarSnapshot, for session: UserSession) async throws {
        let interval = PerformanceTrace.begin("SnapshotSave")
        defer { PerformanceTrace.end("SnapshotSave", interval) }
        do {
            try ensureDirectoryExists()
            try preserveUnreadableFile(for: session)
            let data = try Self.makeEncoder().encode(Envelope(schemaVersion: 1, snapshot: snapshot))
            try data.write(to: fileURL(for: session), options: [.atomic])
        } catch let error as SnapshotStorageError { throw error }
        catch { throw SnapshotStorageError.unavailable }
    }

    func delete(for session: UserSession) async throws {
        let url = fileURL(for: session)
        try removeIfPresent(url)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        do {
            let prefix = url.deletingPathExtension().lastPathComponent + ".unreadable-"
            for backup in try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                where backup.lastPathComponent.hasPrefix(prefix) {
                try removeIfPresent(backup)
            }
        } catch { throw SnapshotStorageError.unavailable }
    }

    func clear() async throws {
        try removeIfPresent(directoryURL)
    }

    private func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
        catch { throw SnapshotStorageError.unavailable }
    }

    private func preserveUnreadableFile(for session: UserSession) throws {
        let url = fileURL(for: session)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let decoder = Self.makeDecoder()
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["schemaVersion"] != nil {
            guard object["schemaVersion"] as? Int == 1 else { throw SnapshotStorageError.unsupportedVersion }
            if (try? decoder.decode(Envelope.self, from: data)) != nil { return }
        } else if (try? decoder.decode(HangarSnapshot.self, from: data)) != nil { return }
        // Keep the recoverable original before replacing a damaged cache with a
        // successful refresh. Unknown future versions are never overwritten.
        try FileManager.default.copyItem(at: url, to: url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(UUID().uuidString).json"))
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for session: UserSession) -> URL {
        directoryURL.appendingPathComponent("\(fileName(for: session.accountKey)).json", isDirectory: false)
    }

    private func fileName(for accountKey: String) -> String {
        Data(accountKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return appSupportURL
            .appendingPathComponent("HangerExpress", isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true)
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
