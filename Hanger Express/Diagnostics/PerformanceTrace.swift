import os

/// Static stage names keep account data out of Instruments recordings.
nonisolated enum PerformanceTrace {
    private static let log = OSLog(
        subsystem: "com.wisewolfholo.Hanger-Express", category: .pointsOfInterest
    )

    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    static func measure<T>(_ name: StaticString, _ operation: () throws -> T) rethrows -> T {
        let id = begin(name)
        defer { end(name, id) }
        return try operation()
    }
}
