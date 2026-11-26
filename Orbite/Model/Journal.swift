import Foundation

/// Something worth telling: a first contact, an unusual volume, a summary of an absence.
nonisolated struct JournalEvent: Codable, Sendable, Identifiable, Hashable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case newApp, newDomain, newCountry, unusual, whileAway, recapReady
    }

    var id = UUID()
    var date: Int
    var kind: Kind
    var appID: String?
    var appName: String?
    /// Domain, country code, or « up » / « down » for an unusual volume.
    var subject: String?
    /// Country name, or how far above the usual an unusual volume is (« 12 »).
    var detail: String?
    var bytes: UInt64?
    /// Away period length in seconds, for `whileAway`.
    var duration: Int?
}

/// What the journal has already met, kept for good, and the events of the last 30 days.
nonisolated struct JournalState: Codable, Sendable {
    var version = 1
    var createdAt: Int
    /// Discoveries before this second only teach: a fresh journal would otherwise call everything new.
    var learnUntil: Int
    /// Oldest second the seeding history covered: first-seen dates at that edge mean « or before ».
    var historyStart: Int?
    var apps: [String: Int] = [:]
    /// « appID|domain » → first seen.
    var domains: [String: Int] = [:]
    /// « appID|CC » → first seen.
    var countries: [String: Int] = [:]
    var events: [JournalEvent] = []
    /// Last unusual event per app and direction (« appID|up »), to keep one per 6 hours.
    var lastUnusual: [String: Int] = [:]
    /// Day index (NetworkLedger.dayIndex) of the last « recap ready » event.
    var lastRecapDay: Int32?

    init(now: Int, learning: Bool) {
        createdAt = now
        learnUntil = learning ? now + JournalRules.learningPeriod : now
    }
}

/// A first contact as the store reports it, with names resolved.
nonisolated enum JournalObservation: Sendable {
    case app(id: String, name: String)
    case domain(appID: String, appName: String, domain: String)
    case country(appID: String, appName: String, code: String, name: String?)
}

/// Rules that turn observations into events, without any I/O so they can be tested.
nonisolated enum JournalRules {
    static let learningPeriod = 600
    static let eventLifetime = 30 * 86_400
    static let maxEvents = 2000

    /// Records an observation in the known sets; returns the event when it is truly new and worth showing.
    /// Browsers meet new domains all day: for them only new countries make an event.
    static func observe(_ observation: JournalObservation, in state: inout JournalState, now: Int,
                        isBrowser: Bool) -> JournalEvent? {
        let silent = now < state.learnUntil
        switch observation {
        case .app(let id, let name):
            guard state.apps[id] == nil else { return nil }
            state.apps[id] = now
            return silent ? nil : JournalEvent(date: now, kind: .newApp, appID: id, appName: name)
        case .domain(let appID, let appName, let domain):
            let key = "\(appID)|\(domain)"
            guard state.domains[key] == nil else { return nil }
            state.domains[key] = now
            return silent || isBrowser ? nil
                : JournalEvent(date: now, kind: .newDomain, appID: appID, appName: appName, subject: domain)
        case .country(let appID, let appName, let code, let name):
            let key = "\(appID)|\(code)"
            guard state.countries[key] == nil else { return nil }
            state.countries[key] = now
            return silent ? nil
                : JournalEvent(date: now, kind: .newCountry, appID: appID, appName: appName, subject: code, detail: name)
        }
    }

    /// Adds an event, then drops what is older than 30 days or beyond the cap.
    static func append(_ event: JournalEvent, to state: inout JournalState, now: Int) {
        state.events.append(event)
        prune(&state, now: now)
    }

    static func prune(_ state: inout JournalState, now: Int) {
        let oldest = now - eventLifetime
        if state.events.first.map({ $0.date < oldest }) == true {
            state.events.removeAll { $0.date < oldest }
        }
        if state.events.count > maxEvents { state.events.removeFirst(state.events.count - maxEvents) }
    }

    /// Seeds the known sets from history without making events. `firstSeen` is the oldest bucket of each entity.
    static func seed(_ state: inout JournalState, apps: [String: Int], domains: [String: Int], countries: [String: Int]) {
        for (key, date) in apps where state.apps[key].map({ date < $0 }) ?? true { state.apps[key] = date }
        for (key, date) in domains where state.domains[key].map({ date < $0 }) ?? true { state.domains[key] = date }
        for (key, date) in countries where state.countries[key].map({ date < $0 }) ?? true { state.countries[key] = date }
        let oldest = (Array(apps.values) + Array(domains.values) + Array(countries.values)).min()
        if let oldest { state.historyStart = min(state.historyStart ?? oldest, oldest) }
    }

    /// Events of the same app and kind within the same clock hour read as one line, newest first.
    static func group(_ events: [JournalEvent]) -> [JournalGroup] {
        var groups: [JournalGroup] = []
        var index: [String: Int] = [:]
        for event in events.sorted(by: { $0.date > $1.date }) {
            let mergeable = event.kind == .newDomain || event.kind == .newCountry
            let key = "\(event.kind.rawValue)|\(event.appID ?? "")|\(event.date / 3600)"
            if mergeable, let position = index[key] {
                groups[position].events.append(event)
            } else {
                if mergeable { index[key] = groups.count }
                groups.append(JournalGroup(events: [event]))
            }
        }
        return groups
    }
}

/// One line of the journal: an event, or several of the same kind for one app within an hour.
nonisolated struct JournalGroup: Identifiable, Hashable, Sendable {
    var events: [JournalEvent]

    var id: UUID { events[0].id }
    var latest: JournalEvent { events[0] }
    var kind: JournalEvent.Kind { latest.kind }
    var date: Int { latest.date }

    /// Sentence for the line.
    var title: String {
        let app = latest.appName ?? String(localized: "An app")
        switch kind {
        case .newApp:
            return String(localized: "\(app) connects for the first time")
        case .newDomain:
            let domains = events.compactMap(\.subject)
            if domains.count == 1 { return String(localized: "\(app) contacts \(domains[0]) for the first time") }
            return String(localized: "\(app) contacts \(domains.count) new domains")
        case .newCountry:
            let names = events.map { $0.detail ?? $0.subject ?? "?" }
            if names.count == 1 { return String(localized: "\(app) talks with \(Self.country(names[0], code: latest.subject)) for the first time") }
            return String(localized: "\(app) talks with \(names.count) new countries")
        case .unusual:
            let volume = Format.bytes(latest.bytes ?? 0)
            return latest.subject == "up" ? String(localized: "\(app) sends \(volume) in an hour") : String(localized: "\(app) receives \(volume) in an hour")
        case .whileAway:
            return String(localized: "While you were away (\(Format.duration(latest.duration ?? 0))): \(Format.bytes(latest.bytes ?? 0)) exchanged")
        case .recapReady:
            return String(localized: "Your weekly recap is ready")
        }
    }

    /// Second line: the list behind a merged line, or context.
    var subtitle: String? {
        switch kind {
        case .newDomain where events.count > 1:
            return events.compactMap(\.subject).prefix(4).joined(separator: ", ") + (events.count > 4 ? "…" : "")
        case .newCountry where events.count > 1:
            return events.map { "\(Format.flag($0.subject)) \($0.detail ?? $0.subject ?? "")" }.prefix(4).joined(separator: ", ")
        case .unusual:
            guard let factor = latest.detail else { return String(localized: "Much more than usual") }
            return String(localized: "About \(factor)× more than a usual hour")
        case .whileAway:
            return latest.appName.map { String(localized: "Mostly \($0)") }
        default:
            return nil
        }
    }

    private static func country(_ name: String, code: String?) -> String {
        "\(Format.flag(code)) \(name)"
    }
}
