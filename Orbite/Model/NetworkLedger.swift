import Foundation

/// Which network the Mac is on, as far as traffic accounting goes: the Wi-Fi it is joined to, the
/// Ethernet link, or the cellular modem. A VPN on top does not change it.
nonisolated struct NetworkIdentity: Equatable, Codable, Sendable {
    enum Medium: String, Codable, Sendable { case wifi, ethernet, cellular, other }

    var id: String
    var name: String
    var medium: Medium
    var isExpensive: Bool
    var security: String?

    static func wifi(ssid: String?, expensive: Bool, security: String?) -> NetworkIdentity {
        guard let ssid, !ssid.isEmpty else {
            return NetworkIdentity(id: "wifi:?", name: String(localized: "Wi-Fi (name hidden)"), medium: .wifi, isExpensive: expensive, security: security)
        }
        return NetworkIdentity(id: "wifi:\(ssid)", name: ssid, medium: .wifi, isExpensive: expensive, security: security)
    }

    static func ethernet(name: String?, expensive: Bool) -> NetworkIdentity {
        NetworkIdentity(id: "ethernet", name: name ?? "Ethernet", medium: .ethernet, isExpensive: expensive)
    }

    static func cellular(expensive: Bool) -> NetworkIdentity {
        NetworkIdentity(id: "cellular", name: String(localized: "Cellular network"), medium: .cellular, isExpensive: true)
    }
}

/// Everything Orbite keeps about one network.
nonisolated struct NetworkRecord: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var medium: NetworkIdentity.Medium
    var security: String?
    var firstSeen: Int
    var lastSeen: Int
    /// macOS flagged it as costly the last time (iPhone Personal Hotspot, cellular).
    var expensive: Bool
    /// The person's own answer to « count it as mobile data », when given.
    var mobileOverride: Bool?
    var buckets = TrafficBuckets()
    /// Per local day (see `NetworkLedger.dayIndex`), per app, for 62 days.
    var appDays: [Int32: [String: Traffic]] = [:]
    /// Highest 10-second average rate seen in the last 30 days, in bytes per second, and when.
    var peakRate: Double = 0
    var peakAt: Int = 0
    /// Usual round trip to the router and to the internet probe, from earlier diagnoses, in ms.
    var routerBaseline: Double?
    var internetBaseline: Double?
    /// « App · host » reached unencrypted on this network, newest last.
    var plaintextHosts: [String] = []

    var isMobile: Bool { mobileOverride ?? (expensive || medium == .cellular) }

    func total(fromDay first: Int32, toDay last: Int32) -> (total: Traffic, byApp: [String: Traffic]) {
        var total = Traffic.zero
        var byApp: [String: Traffic] = [:]
        for (day, apps) in appDays where day >= first && day <= last {
            for (app, traffic) in apps {
                total += traffic
                byApp[app, default: .zero] += traffic
            }
        }
        return (total, byApp)
    }
}

/// Traffic per network and per day, on this Mac only (networks.json).
nonisolated struct NetworkLedger: Codable, Sendable {
    var version = 1
    var networks: [String: NetworkRecord] = [:]
    /// Whole-Mac total per local day, kept 90 days, for week-over-week comparisons.
    var globalDays: [Int32: Traffic] = [:]

    static let appDayHorizon: Int32 = 62
    static let globalDayHorizon: Int32 = 90
    static let peakHorizon = 30 * 86_400
    static let plaintextCap = 30

    /// Adds one sample's bytes to the current network. Records are changed in place: copying one out
    /// would copy its buckets every second.
    mutating func record(_ identity: NetworkIdentity, total: Traffic, byApp: [String: Traffic], at second: Int, day: Int32) {
        if networks[identity.id] == nil {
            networks[identity.id] = NetworkRecord(id: identity.id, name: identity.name, medium: identity.medium,
                                                  security: identity.security, firstSeen: second, lastSeen: second,
                                                  expensive: identity.isExpensive)
        }
        update(identity.id) { record in
            if record.name != identity.name { record.name = identity.name }
            if record.medium != identity.medium { record.medium = identity.medium }
            if let security = identity.security, record.security != security { record.security = security }
            if record.expensive != identity.isExpensive { record.expensive = identity.isExpensive }
            record.lastSeen = second
            guard !total.isZero else { return }
            record.buckets.add(total, at: second)
            for (app, traffic) in byApp where !traffic.isZero { record.appDays[day, default: [:]][app, default: .zero] += traffic }
        }
        if !total.isZero { globalDays[day, default: .zero] += total }
    }

    private mutating func update(_ id: String, _ body: (inout NetworkRecord) -> Void) {
        guard networks[id] != nil else { return }
        body(&networks[id]!)
    }

    /// Keeps the highest recent 10-second average; an old peak gives way to the best of the last 30 days.
    mutating func notePeak(_ rate: Double, for id: String, at second: Int) {
        update(id) { record in
            if rate > record.peakRate || second - record.peakAt > Self.peakHorizon {
                record.peakRate = rate
                record.peakAt = second
            }
        }
    }

    mutating func notePlaintext(_ entries: Set<String>, for id: String) {
        update(id) { record in
            for entry in entries.sorted() where !record.plaintextHosts.contains(entry) { record.plaintextHosts.append(entry) }
            if record.plaintextHosts.count > Self.plaintextCap {
                record.plaintextHosts.removeFirst(record.plaintextHosts.count - Self.plaintextCap)
            }
        }
    }

    mutating func setBaselines(router: Double?, internet: Double?, for id: String) {
        update(id) { record in
            // Slow average over diagnoses, so one bad evening does not become the norm.
            if let router { record.routerBaseline = record.routerBaseline.map { $0 * 0.7 + router * 0.3 } ?? router }
            if let internet { record.internetBaseline = record.internetBaseline.map { $0 * 0.7 + internet * 0.3 } ?? internet }
        }
    }

    mutating func setMobileOverride(_ value: Bool?, for id: String) {
        update(id) { $0.mobileOverride = value }
    }

    mutating func prune(now: Int, today: Int32) {
        for id in networks.keys {
            update(id) { record in
                record.buckets.prune(now: now)
                record.appDays = record.appDays.filter { $0.key > today - Self.appDayHorizon }
            }
        }
        globalDays = globalDays.filter { $0.key > today - Self.globalDayHorizon }
    }

    /// Mobile data from `firstDay` to `lastDay` included, on every network counted as mobile.
    func mobileUsage(fromDay firstDay: Int32, toDay lastDay: Int32) -> (total: Traffic, byApp: [String: Traffic]) {
        var total = Traffic.zero
        var byApp: [String: Traffic] = [:]
        for record in networks.values where record.isMobile {
            let part = record.total(fromDay: firstDay, toDay: lastDay)
            total += part.total
            for (app, traffic) in part.byApp { byApp[app, default: .zero] += traffic }
        }
        return (total, byApp)
    }

    // MARK: - Calendar days

    /// Days since 1970-01-01 in the given calendar's time zone: the same number all day long, across
    /// daylight saving changes.
    static func dayIndex(_ date: Date, calendar: Calendar = .current) -> Int32 {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return Int32(civilDays(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1))
    }

    /// Howard Hinnant's days_from_civil.
    static func civilDays(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// First day of the current data plan cycle: the reset day of this month, or of the previous one if it
    /// has not come yet. A reset on the 31st falls on the last day of shorter months.
    static func cycleStart(resetDay: Int, now: Date, calendar: Calendar = .current) -> Int32 {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let year = parts.year ?? 1970, month = parts.month ?? 1, day = parts.day ?? 1
        func clamped(_ year: Int, _ month: Int) -> Int {
            let length = daysInMonth(year: year, month: month)
            return min(max(resetDay, 1), length)
        }
        if day >= clamped(year, month) {
            return Int32(civilDays(year: year, month: month, day: clamped(year, month)))
        }
        let previousMonth = month == 1 ? 12 : month - 1
        let previousYear = month == 1 ? year - 1 : year
        return Int32(civilDays(year: previousYear, month: previousMonth, day: clamped(previousYear, previousMonth)))
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}
