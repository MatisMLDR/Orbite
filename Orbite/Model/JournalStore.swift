import AppKit
import CoreGraphics
import Foundation
import Observation
import os

nonisolated private let log = Logger(subsystem: "app.matis.Orbite", category: "journal")

/// The journal of firsts: keeps what Orbite has met, turns new contacts and odd volumes into events,
/// and remembers which events the window has not shown yet. Stored in journal.json, on this Mac only.
@Observable
final class JournalStore {
    /// Newest last.
    private(set) var events: [JournalEvent] = []
    private(set) var lastVisit: Int

    @ObservationIgnored private var state: JournalState
    @ObservationIgnored private var fileExisted: Bool
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var awaySince: Int?
    @ObservationIgnored private var lastTick: Int?

    private static let lastVisitKey = "journalLastVisit"
    static let awayThreshold = 30 * 60
    static let awayFloor: UInt64 = 20_000_000

    static var file: URL { HistoryStore.directory.appendingPathComponent("journal.json") }

    init() {
        let now = Int(Date().timeIntervalSince1970)
        if let data = try? Data(contentsOf: Self.file), let loaded = try? JSONDecoder().decode(JournalState.self, from: data) {
            state = loaded
            fileExisted = true
        } else {
            state = JournalState(now: now, learning: false)
            fileExisted = false
        }
        let stored = UserDefaults.standard.integer(forKey: Self.lastVisitKey)
        lastVisit = stored > 0 ? stored : now
        JournalRules.prune(&state, now: now)
        events = state.events
    }

    var unseen: [JournalEvent] { events.filter { $0.date > lastVisit } }

    // MARK: - Setup

    /// A new journal learns from the history on disk without making events; with no history either,
    /// it listens quietly for ten minutes.
    func prepare(from store: TrafficStore) {
        guard !fileExisted else { return }
        let now = Int(Date().timeIntervalSince1970)
        seed(from: store)
        if store.apps.isEmpty { state.learnUntil = now + JournalRules.learningPeriod }
        fileExisted = true
        save()
    }

    func start(store: TrafficStore) {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self, weak store] _ in
            MainActor.assumeIsolated {
                guard let self, let store else { return }
                self.tick(store: store)
            }
        }
        timer.tolerance = 10
        self.timer = timer
    }

    private func seed(from store: TrafficStore) {
        var apps: [String: Int] = [:], domains: [String: Int] = [:], countries: [String: Int] = [:]
        func oldest(_ stats: ActivityStats, _ fallback: Int) -> Int {
            stats.buckets.hours.keys.min().map { Int($0) * 3600 } ?? fallback
        }
        for app in store.apps.values {
            apps[app.id] = oldest(app.stats, app.lastSeen)
            for host in app.hosts.values where host.kind == .domain {
                domains["\(app.id)|\(host.label)"] = oldest(host.stats, host.lastSeen)
            }
            for siteID in app.siteIDs {
                guard let site = store.sites[siteID], let code = site.place.countryCode else { continue }
                let key = "\(app.id)|\(code)"
                let date = oldest(site.stats, site.lastSeen)
                countries[key] = min(countries[key] ?? date, date)
            }
        }
        JournalRules.seed(&state, apps: apps, domains: domains, countries: countries)
    }

    // MARK: - Discoveries

    func handle(_ discovery: Discovery, store: TrafficStore) {
        let now = store.now
        let observation: JournalObservation
        switch discovery {
        case .app(let identity):
            observation = .app(id: identity.id, name: identity.name)
        case .host(let appID, let label, let kind):
            guard kind == .domain else { return }
            observation = .domain(appID: appID, appName: store.apps[appID]?.identity.name ?? appID, domain: label)
        case .country(let appID, let code, let name):
            observation = .country(appID: appID, appName: store.apps[appID]?.identity.name ?? appID, code: code, name: name)
        }
        let appID: String = switch observation {
        case .app(let id, _): id
        case .domain(let id, _, _), .country(let id, _, _, _): id
        }
        let browser = Browsers.contains(store.apps[appID]?.identity)
        if let event = JournalRules.observe(observation, in: &state, now: now, isBrowser: browser) {
            add(event, now: now)
        }
    }

    private func add(_ event: JournalEvent, now: Int) {
        JournalRules.append(event, to: &state, now: now)
        events = state.events
    }

    // MARK: - Periodic checks

    /// Every minute: notices an absence ending. Every ten: looks for unusual hours.
    private func tick(store: TrafficStore) {
        let now = Int(Date().timeIntervalSince1970)
        defer { lastTick = now }
        // A long gap means the Mac slept: what came before is no absence to report.
        if let lastTick, now - lastTick > Self.awayThreshold { awaySince = nil }
        checkAway(store: store, now: now)
        ticks += 1
        if ticks % 10 == 0 {
            checkUnusual(store: store, now: now)
            checkRecap(now: now)
        }
    }

    /// Monday brings a « recap ready » line, once, when there is a week behind.
    private func checkRecap(now: Int) {
        let date = Date(timeIntervalSince1970: TimeInterval(now))
        guard Calendar.current.component(.weekday, from: date) == 2, now - state.createdAt >= 3 * 86_400 else { return }
        let today = NetworkLedger.dayIndex(date)
        guard state.lastRecapDay != today else { return }
        state.lastRecapDay = today
        add(JournalEvent(date: now, kind: .recapReady), now: now)
    }

    private func checkAway(store: TrafficStore, now: Int) {
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = Int(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput))
        if idle >= Self.awayThreshold {
            if awaySince == nil { awaySince = now - idle }
            return
        }
        guard let since = awaySince, idle < 120 else { return }
        awaySince = nil
        let end = now - idle
        let total = store.global.buckets.sum(from: since, to: end, now: now)
        guard total.total >= Self.awayFloor else { return }
        let top = store.apps.values
            .map { ($0, $0.stats.buckets.sum(from: since, to: end, now: now).total) }
            .max { $0.1 < $1.1 }
        add(JournalEvent(date: end, kind: .whileAway, appID: top?.0.id, appName: top?.0.identity.name,
                         bytes: total.total, duration: end - since), now: now)
    }

    private func checkUnusual(store: TrafficStore, now: Int) {
        for app in store.apps.values {
            guard let finding = AnomalyRules.check(hours: app.stats.buckets.hours, now: now) else { continue }
            let key = "\(app.id)|\(finding.direction.rawValue)"
            guard AnomalyRules.allowed(key, in: state.lastUnusual, now: now) else { continue }
            state.lastUnusual[key] = now
            add(JournalEvent(date: now, kind: .unusual, appID: app.id, appName: app.identity.name,
                             subject: finding.direction.rawValue, detail: finding.factor > 0 ? "\(finding.factor)" : nil,
                             bytes: finding.bytes), now: now)
        }
    }

    // MARK: - Reading

    func firstSeen(appID: String) -> Int? { state.apps[appID] }
    func firstSeen(appID: String, domain: String) -> Int? { state.domains["\(appID)|\(domain)"] }

    /// « aujourd'hui à 14:05 », or « le 17 nov. ou avant » when the date is where the history began.
    func firstSeenText(_ date: Int) -> String {
        let moment = Format.moment(Date(timeIntervalSince1970: TimeInterval(date)))
        if let start = state.historyStart, date <= start + 3600, date < state.createdAt {
            let day = Date(timeIntervalSince1970: TimeInterval(date))
                .formatted(.dateTime.day().month(.abbreviated).locale(Format.locale))
            return String(localized: "on \(day) or before")
        }
        return moment
    }

    /// The window showed the events: the next visit starts from now.
    func markSeen() {
        let now = Int(Date().timeIntervalSince1970)
        guard lastVisit < now else { return }
        lastVisit = now
        UserDefaults.standard.set(now, forKey: Self.lastVisitKey)
    }

    // MARK: - Storage

    func save() {
        do {
            try FileManager.default.createDirectory(at: HistoryStore.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: Self.file, options: .atomic)
        } catch {
            log.error("journal not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forgets everything; the next ten minutes learn again.
    func erase() {
        try? FileManager.default.removeItem(at: Self.file)
        state = JournalState(now: Int(Date().timeIntervalSince1970), learning: true)
        events = []
        awaySince = nil
    }
}
