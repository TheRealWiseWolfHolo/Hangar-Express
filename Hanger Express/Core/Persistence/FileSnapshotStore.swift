import Foundation

nonisolated struct FileSnapshotStore: SnapshotStore {
    private let directoryURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
    }

    func load(for session: UserSession) async -> HangarSnapshot? {
        let fileURL = fileURL(for: session)

        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        guard let snapshot = try? Self.makeDecoder().decode(HangarSnapshot.self, from: data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        return snapshot
    }

    func save(_ snapshot: HangarSnapshot, for session: UserSession) async {
        do {
            try ensureDirectoryExists()
            let data = try Self.makeEncoder().encode(snapshot)
            try data.write(to: fileURL(for: session), options: [.atomic])
        } catch {
#if DEBUG
            print("FileSnapshotStore failed to save snapshot for \(session.accountKey): \(error)")
#endif
        }
    }

    func delete(for session: UserSession) async {
        try? FileManager.default.removeItem(at: fileURL(for: session))
    }

    func clear() async {
        try? FileManager.default.removeItem(at: directoryURL)
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

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return appSupportURL
            .appendingPathComponent("HangerExpress", isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
