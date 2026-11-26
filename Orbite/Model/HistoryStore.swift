import Foundation
import os

nonisolated private let log = Logger(subsystem: "app.matis.Orbite", category: "history")

nonisolated struct HistorySnapshot: Codable, Sendable {
    /// 2 adds optional fields only: a version 1 file still decodes whole.
    static let currentVersion = 2
    var version = currentVersion
    var savedAt: Date
    var global: TrafficBuckets
    var apps: [AppRecord]
    var sites: [SiteRecord]
}

nonisolated struct AppRecord: Codable, Sendable {
    var identity: AppIdentity
    var lastSeen: Int
    var buckets: TrafficBuckets
    var siteIDs: [String]
    var hosts: [HostRecord]
    var processes: [ProcessRecord]
}

nonisolated struct HostRecord: Codable, Sendable {
    var label: String
    var kind: HostLabelKind
    var hostnames: [String]
    var addresses: [String]
    var ports: [PortUse]
    var siteIDs: [String]
    var organization: String?
    var lastSeen: Int
    var buckets: TrafficBuckets
    // Version 2
    var plaintext: [PlaintextProtocol]?
    var plaintextLastSeen: Int?
    var rttBaseline: Double?
}

nonisolated struct ProcessRecord: Codable, Sendable {
    var name: String
    var path: String
    var hostLabels: [String]
    var lastSeen: Int
    var buckets: TrafficBuckets
}

nonisolated struct SiteRecord: Codable, Sendable {
    var id: String
    var place: GeoPlace
    var addresses: [String]
    var labels: [String]
    var organizations: [String]
    var appIDs: [String]
    var ports: [PortUse]
    var lastSeen: Int
    var buckets: TrafficBuckets
    // Version 2
    var rttBaseline: Double?
}

/// Keeps a week of per-minute and per-hour history in Application Support, on this Mac only.
nonisolated enum HistoryStore {
    static var directory: URL {
        #if DEBUG
        if Demo.isActive { return Demo.directory }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Orbite", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("history.json") }

    static func load() -> HistorySnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            let snapshot = try JSONDecoder().decode(HistorySnapshot.self, from: data)
            return (1...HistorySnapshot.currentVersion).contains(snapshot.version) ? snapshot : nil
        } catch {
            log.error("history unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func save(_ snapshot: HistorySnapshot) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: file, options: .atomic)
        } catch {
            log.error("history not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func erase() {
        try? FileManager.default.removeItem(at: file)
    }
}
