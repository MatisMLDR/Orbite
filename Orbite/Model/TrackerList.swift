import Foundation

/// What a tracker does, in the words the UI uses.
nonisolated enum TrackerCategory: String, Codable, Sendable, CaseIterable {
    case advertising, analytics, social, fingerprinting, telemetry, other

    var label: String {
        switch self {
        case .advertising: String(localized: "Advertising")
        case .analytics: String(localized: "Audience measurement")
        case .social: String(localized: "Social network")
        case .fingerprinting: String(localized: "Fingerprinting")
        case .telemetry: String(localized: "Telemetry")
        case .other: String(localized: "Tracking")
        }
    }

    /// Short text for the sidebar tag.
    var tag: String {
        switch self {
        case .advertising: String(localized: "AD")
        case .analytics: String(localized: "ANALYTICS")
        case .social: String(localized: "SOCIAL")
        case .fingerprinting: String(localized: "FINGERPRINT")
        case .telemetry: String(localized: "TELEMETRY")
        case .other: String(localized: "TRACKING")
        }
    }
}

nonisolated struct TrackerInfo: Hashable, Sendable {
    var owner: String
    var category: TrackerCategory
    /// Share of websites that load it (DuckDuckGo Tracker Radar), when known.
    var prevalence: Double?
}

/// DuckDuckGo's tracker lists (CC BY-NC-SA 4.0) plus a few app telemetry endpoints, matched by domain suffix.
nonisolated struct TrackerList: Sendable {
    /// Web trackers by registrable domain: they count whoever calls them.
    var web: [String: TrackerInfo] = [:]
    /// In-app SDK hosts (App Tracking Protection list): they only count outside browsers, where a site
    /// the person opens on purpose (www.facebook.com) is not tracking.
    var apps: [String: TrackerInfo] = [:]

    var isEmpty: Bool { web.isEmpty && apps.isEmpty }
    var count: Int { web.count + apps.count }

    /// Categories that mean tracking; a list entry with any other (content delivery, login, payment…) is a service.
    private static let tracking: Set<String> = [
        "Ad Motivated Tracking", "Advertising", "Analytics", "Third-Party Analytics Marketing", "Audience Measurement",
        "Action Pixels", "Ad Fraud", "Session Replay", "Tag Manager",
    ]
    private static let neutral: Set<String> = ["Badge", "Obscure Ownership", "Unknown High Risk Behavior", "Malware"]

    /// App telemetry endpoints the lists leave out, kept short and uncontroversial.
    static let telemetry: [String: String] = [
        "sentry.io": "Sentry",
        "sentry-cdn.com": "Sentry",
        "bugsnag.com": "Bugsnag",
        "crashlytics.com": "Google",
        "crashlyticsreports-pa.googleapis.com": "Google",
        "firebaselogging-pa.googleapis.com": "Google",
        "app-measurement.com": "Google",
        "api.mixpanel.com": "Mixpanel",
        "api.amplitude.com": "Amplitude",
        "api2.amplitude.com": "Amplitude",
        "api.segment.io": "Segment",
        "browser-intake-datadoghq.com": "Datadog",
        "browser-intake-datadoghq.eu": "Datadog",
        "logs.datadoghq.com": "Datadog",
        "logs.datadoghq.eu": "Datadog",
        "nr-data.net": "New Relic",
        "mobile-collector.newrelic.com": "New Relic",
        "in.appcenter.ms": "Microsoft",
        "events.data.microsoft.com": "Microsoft",
        "dc.services.visualstudio.com": "Microsoft",
        "incoming.telemetry.mozilla.org": "Mozilla",
        "i.posthog.com": "PostHog",
        "app.posthog.com": "PostHog",
        "xp.apple.com": "Apple",
    ]

    static func parse(web webData: Data?, apps appData: Data?) throws -> TrackerList {
        var list = TrackerList()
        if let webData {
            let file = try JSONDecoder().decode(TDSFile.self, from: webData)
            for (domain, entry) in file.trackers {
                guard let category = webCategory(entry) else { continue }
                list.web[domain.lowercased()] = TrackerInfo(owner: entry.owner?.displayName ?? entry.owner?.name ?? domain,
                                                            category: category, prevalence: entry.prevalence)
            }
        }
        if let appData {
            let file = try JSONDecoder().decode(TDSFile.self, from: appData)
            for (host, entry) in file.trackers where entry.default == "block" {
                list.apps[host.lowercased()] = TrackerInfo(owner: entry.owner?.displayName ?? entry.owner?.name ?? host,
                                                           category: .other, prevalence: nil)
            }
        }
        for (host, owner) in telemetry {
            list.apps[host] = TrackerInfo(owner: owner, category: .telemetry, prevalence: nil)
        }
        return list
    }

    /// nil when the entry is a service rather than a tracker.
    static func webCategory(_ entry: TDSFile.Tracker) -> TrackerCategory? {
        let categories = Set(entry.categories ?? [])
        let blocked = entry.default == "block"
        let onlyTracking = !categories.isEmpty && categories.isSubset(of: tracking.union(neutral))
            && !categories.isDisjoint(with: tracking)
        guard blocked || onlyTracking else { return nil }
        if !categories.isDisjoint(with: ["Advertising", "Ad Motivated Tracking", "Ad Fraud"]) { return .advertising }
        if !categories.isDisjoint(with: ["Social - Share", "Social Network", "Social - Comment"]) { return .social }
        if !categories.isDisjoint(with: tracking) { return .analytics }
        if (entry.fingerprinting ?? 0) >= 2 { return .fingerprinting }
        return .other
    }

    /// The tracker behind a hostname, trying it and every parent domain.
    func lookup(_ hostname: String, inBrowser: Bool) -> TrackerInfo? {
        var name = Substring(hostname.lowercased())
        if name.hasSuffix(".") { name = name.dropLast() }
        while name.contains(".") {
            if !inBrowser, let info = apps[String(name)] { return info }
            if let info = web[String(name)] { return info }
            guard let dot = name.firstIndex(of: ".") else { break }
            name = name[name.index(after: dot)...]
        }
        return nil
    }
}

/// The part of DuckDuckGo's tds.json Orbite reads.
nonisolated struct TDSFile: Decodable, Sendable {
    struct Owner: Decodable, Sendable {
        var name: String?
        var displayName: String?
    }

    struct Tracker: Decodable, Sendable {
        var owner: Owner?
        var `default`: String?
        var categories: [String]?
        var prevalence: Double?
        var fingerprinting: Int?
    }

    var trackers: [String: Tracker]
}

/// How much of a set of hosts' traffic goes to trackers, and to whom.
nonisolated struct TrackerSummary: Sendable {
    struct Owner: Sendable, Equatable {
        var name: String
        var bytes: UInt64
        var hosts: Int
    }

    var trackerHosts = 0
    var trackerBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    /// Biggest first.
    var owners: [Owner] = []

    var share: Double { totalBytes == 0 ? 0 : Double(trackerBytes) / Double(totalBytes) }

    static func make(_ items: [(tracker: TrackerInfo?, bytes: UInt64)]) -> TrackerSummary {
        var summary = TrackerSummary()
        var owners: [String: Owner] = [:]
        for item in items {
            summary.totalBytes += item.bytes
            guard let tracker = item.tracker else { continue }
            summary.trackerHosts += 1
            summary.trackerBytes += item.bytes
            owners[tracker.owner, default: Owner(name: tracker.owner, bytes: 0, hosts: 0)].bytes += item.bytes
            owners[tracker.owner]?.hosts += 1
        }
        summary.owners = owners.values.sorted { ($0.bytes, $0.hosts, $1.name) > ($1.bytes, $1.hosts, $0.name) }
        return summary
    }
}
