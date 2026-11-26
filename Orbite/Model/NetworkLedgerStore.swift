import Foundation
import Observation
import os

nonisolated private let log = Logger(subsystem: "app.matis.Orbite", category: "networks")

/// Counts every sample against the network the Mac is on, for the « Réseaux » view and mobile data.
/// Stored in networks.json, on this Mac only.
@Observable
final class NetworkLedgerStore {
    /// Bumped every few seconds while traffic flows: views showing networks read it to refresh.
    private(set) var revision = 0

    @ObservationIgnored private(set) var ledger: NetworkLedger
    @ObservationIgnored private var day: (index: Int32, end: Int)?
    @ObservationIgnored private var lastPublish = 0
    @ObservationIgnored private var recentTotals: [UInt64] = []

    static var file: URL { HistoryStore.directory.appendingPathComponent("networks.json") }
    static let quotaKey = "mobileQuotaGB"
    static let resetDayKey = "mobileResetDay"

    init() {
        if let data = try? Data(contentsOf: Self.file), let loaded = try? JSONDecoder().decode(NetworkLedger.self, from: data) {
            ledger = loaded
        } else {
            ledger = NetworkLedger()
        }
    }

    var networks: [NetworkRecord] {
        access(keyPath: \.revision)
        return ledger.networks.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    func record(_ id: String) -> NetworkRecord? {
        access(keyPath: \.revision)
        return ledger.networks[id]
    }

    // MARK: - Recording

    /// One nettop sample: its bytes go to the current network, its peak rate is tracked.
    func ingest(store: TrafficStore, network identity: NetworkIdentity?, now: Int) {
        guard let identity else { return }
        let today = dayIndex(for: now)
        ledger.record(identity, total: store.lastSampleTotal, byApp: store.lastSampleByApp, at: now, day: today)
        recentTotals.append(store.lastSampleTotal.total)
        if recentTotals.count > 10 { recentTotals.removeFirst(recentTotals.count - 10) }
        if recentTotals.count == 10 {
            ledger.notePeak(Double(recentTotals.reduce(0, +)) / 10, for: identity.id, at: now)
        }
        if !store.lastSamplePlaintext.isEmpty { ledger.notePlaintext(store.lastSamplePlaintext, for: identity.id) }
        if now - lastPublish >= 5 {
            lastPublish = now
            revision += 1
        }
    }

    /// Local day of an epoch second, recomputed only when the day changes.
    func dayIndex(for second: Int) -> Int32 {
        if let day, second < day.end, second >= day.end - 90_000 { return day.index }
        let date = Date(timeIntervalSince1970: TimeInterval(second))
        let index = NetworkLedger.dayIndex(date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))
            .map { Int($0.timeIntervalSince1970) } ?? second + 86_400
        day = (index, end)
        return index
    }

    // MARK: - Mobile data

    /// Data plan size in GB; 0 means no plan is followed.
    var quotaGB: Double {
        get { access(keyPath: \.quotaGB); return UserDefaults.standard.double(forKey: Self.quotaKey) }
        set { withMutation(keyPath: \.quotaGB) { UserDefaults.standard.set(max(0, newValue), forKey: Self.quotaKey) } }
    }

    var resetDay: Int {
        get {
            access(keyPath: \.resetDay)
            let value = UserDefaults.standard.integer(forKey: Self.resetDayKey)
            return (1...31).contains(value) ? value : 1
        }
        set { withMutation(keyPath: \.resetDay) { UserDefaults.standard.set(min(31, max(1, newValue)), forKey: Self.resetDayKey) } }
    }

    /// Mobile data since the plan's last reset day.
    func mobileUsage(now: Date = Date()) -> (total: Traffic, byApp: [String: Traffic], since: Int32) {
        access(keyPath: \.revision)
        let start = NetworkLedger.cycleStart(resetDay: resetDay, now: now)
        let today = NetworkLedger.dayIndex(now)
        let usage = ledger.mobileUsage(fromDay: start, toDay: today)
        return (usage.total, usage.byApp, start)
    }

    func setMobile(_ value: Bool?, for id: String) {
        ledger.setMobileOverride(value, for: id)
        revision += 1
    }

    func setBaselines(router: Double?, internet: Double?, for id: String) {
        ledger.setBaselines(router: router, internet: internet, for: id)
        revision += 1
    }

    func forget(_ id: String) {
        ledger.networks[id] = nil
        revision += 1
    }

    // MARK: - Storage

    func save() {
        let now = Int(Date().timeIntervalSince1970)
        ledger.prune(now: now, today: dayIndex(for: now))
        do {
            try FileManager.default.createDirectory(at: HistoryStore.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: Self.file, options: .atomic)
        } catch {
            log.error("networks not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    func erase() {
        try? FileManager.default.removeItem(at: Self.file)
        ledger = NetworkLedger()
        revision += 1
    }
}
