import Foundation

/// What the week's recap is built from, gathered by the app.
nonisolated struct RecapInput: Sendable {
    struct App: Sendable {
        var id: String
        var name: String
        var hours: [Int32: Traffic]
    }

    struct Place: Sendable, Equatable {
        var title: String
        var countryCode: String?
        var country: String?
        var distanceKm: Double
        var bytes: UInt64
    }

    struct Network: Sendable, Equatable {
        var name: String
        var bytes: UInt64
    }

    var start: Int
    var end: Int
    /// Whole-Mac hour buckets.
    var global: [Int32: Traffic]
    /// The seven days before, when the ledger covers them.
    var previousWeek: Traffic?
    var apps: [App]
    var places: [Place]
    var domainCount: Int
    var trackerShare: Double?
    var topTrackerOwner: String?
    var newApps = 0
    var newDomains = 0
    var newCountries = 0
    var networks: [Network] = []
    var mobile: UInt64 = 0
}

/// The week in a few figures.
nonisolated struct Recap: Sendable, Equatable {
    struct AppLine: Sendable, Equatable {
        var id: String
        var name: String
        var bytes: UInt64
    }

    var start: Int
    var end: Int
    var total: Traffic
    /// Against the week before: +0.25 is 25 % more.
    var change: Double?
    var topApps: [AppLine]
    var countryCount: Int
    var farthest: RecapInput.Place?
    var domainCount: Int
    var newApps: Int
    var newDomains: Int
    var newCountries: Int
    var trackerShare: Double?
    var topTrackerOwner: String?
    /// Busiest local day (its start, epoch second) and its volume.
    var busiestDay: (start: Int, bytes: UInt64)?
    /// Local hour of the day (0…23) that carries the most over the week.
    var busiestHour: Int?
    /// The app that moves the most between midnight and 6 h.
    var nightOwl: AppLine?
    var networks: [RecapInput.Network]
    var mobile: UInt64

    static func == (lhs: Recap, rhs: Recap) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end && lhs.total == rhs.total && lhs.topApps == rhs.topApps
            && lhs.busiestDay?.start == rhs.busiestDay?.start && lhs.busiestHour == rhs.busiestHour
    }

    static let nightOwlFloor: UInt64 = 5_000_000

    static func make(_ input: RecapInput, calendar: Calendar = .current) -> Recap {
        let firstHour = Int32(input.start / 3600), lastHour = Int32((input.end - 1) / 3600)
        var total = Traffic.zero
        var days: [Int: UInt64] = [:]
        var hoursOfDay: [Int: UInt64] = [:]
        for (hour, traffic) in input.global where hour >= firstHour && hour <= lastHour {
            total += traffic
            let date = Date(timeIntervalSince1970: TimeInterval(Int(hour) * 3600))
            let dayStart = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
            days[dayStart, default: 0] += traffic.total
            hoursOfDay[calendar.component(.hour, from: date), default: 0] += traffic.total
        }

        var apps: [AppLine] = []
        var owl: AppLine?
        for app in input.apps {
            var bytes: UInt64 = 0, night: UInt64 = 0
            for (hour, traffic) in app.hours where hour >= firstHour && hour <= lastHour {
                bytes += traffic.total
                let local = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(Int(hour) * 3600)))
                if local < 6 { night += traffic.total }
            }
            if bytes > 0 { apps.append(AppLine(id: app.id, name: app.name, bytes: bytes)) }
            if night >= nightOwlFloor, night > (owl?.bytes ?? 0) { owl = AppLine(id: app.id, name: app.name, bytes: night) }
        }
        apps.sort { ($0.bytes, $1.name) > ($1.bytes, $0.name) }

        let places = input.places.filter { $0.bytes > 0 }
        let change = input.previousWeek.flatMap { previous -> Double? in
            previous.total > 0 ? Double(total.total) / Double(previous.total) - 1 : nil
        }
        return Recap(
            start: input.start, end: input.end, total: total, change: change, topApps: Array(apps.prefix(5)),
            countryCount: Set(places.compactMap(\.countryCode)).count,
            farthest: places.max { $0.distanceKm < $1.distanceKm },
            domainCount: input.domainCount, newApps: input.newApps, newDomains: input.newDomains,
            newCountries: input.newCountries, trackerShare: input.trackerShare, topTrackerOwner: input.topTrackerOwner,
            busiestDay: days.max { $0.value < $1.value }.map { ($0.key, $0.value) },
            busiestHour: hoursOfDay.max { $0.value < $1.value }?.key,
            nightOwl: owl,
            networks: input.networks.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes },
            mobile: input.mobile)
    }
}
