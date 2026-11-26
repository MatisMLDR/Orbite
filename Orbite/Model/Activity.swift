import CoreLocation
import Foundation
import Observation

/// Counters behind every row and place. Not observed: the store copies what views show into
/// observed properties once per sample, and only when the value changed.
struct ActivityStats {
    /// Per-second history of the last 5 minutes; dropped when the entity goes quiet.
    var ring: SecondRing?
    var buckets = TrafficBuckets()
    private var closedCache: (key: String, value: Traffic)?

    mutating func record(_ traffic: Traffic, at second: Int) {
        if !traffic.isZero {
            if ring == nil { ring = SecondRing(capacity: 300, now: second) }
            buckets.add(traffic, at: second)
        }
        ring?.add(traffic, at: second)
        if ring?.sum.isZero == true { ring = nil }
    }

    /// Total over the window. Live windows reuse the sum of closed minutes (or hours) until the next one.
    mutating func total(in window: TimeWindow, now: Int, lastSeen: Int) -> Traffic {
        let (start, end) = window.range(now: now)
        guard lastSeen >= start - 3600 else { return .zero }
        if window.isLive && window.span == .fiveMinutes {
            return ring?.sum(from: start, to: end) ?? .zero
        }
        if window.isLive {
            let granularity = window.span == .week ? 3600 : 60
            let current = now / granularity
            let key = "\(window.span.rawValue)|\(current)"
            if closedCache?.key != key {
                closedCache = (key, buckets.sum(from: start, to: current * granularity, now: now))
            }
            let live = granularity == 60 ? buckets.minutes[Int32(current)] : buckets.hours[Int32(current)]
            return closedCache!.value + (live ?? .zero)
        }
        let key = "\(window.span.rawValue)|past|\(end)"
        if closedCache?.key != key {
            closedCache = (key, buckets.sum(from: start, to: end, now: now))
        }
        return closedCache!.value
    }

    /// Six 10-second columns for the row meters, oldest first.
    func meter(now: Int) -> [Traffic] {
        ring?.bins(count: 6, width: 10, end: now + 1) ?? Array(repeating: .zero, count: 6)
    }

    func histogram(for window: TimeWindow, now: Int) -> [Traffic] {
        let end = window.histogramEnd(now: now)
        if window.span == .fiveMinutes {
            // Seconds only for a window the ring holds whole (the live one); a past one reads the minutes.
            if window.isLive || (ring.map { end - 300 > $0.newest - $0.capacity } ?? false) {
                return ring?.bins(count: 30, width: 10, end: end) ?? Array(repeating: .zero, count: 30)
            }
            return buckets.bins(count: 5, width: 60, end: end, now: now)
        }
        let (count, width) = window.span.bins
        return buckets.bins(count: count, width: width, end: end, now: now)
    }
}

/// What every observed row exposes.
protocol ActivityEntity: AnyObject {
    var stats: ActivityStats { get set }
    var pending: Traffic { get set }
    var window: Traffic { get set }
    var rate: Rate { get set }
    var lastSeen: Int { get set }
    var connections: Int { get set }
    var rtt: Double? { get set }
    var rttSamples: (sum: Double, count: Int) { get set }
}

extension ActivityEntity {
    /// Records this sample's bytes and refreshes the observed values.
    func apply(now: Int, interval: Double, window timeWindow: TimeWindow) {
        let delta = pending
        pending = .zero
        stats.record(delta, at: now)
        if !delta.isZero { lastSeen = now }
        let newRate = Rate(delta, over: interval)
        if newRate != rate { rate = newRate }
        let total = stats.total(in: timeWindow, now: now, lastSeen: lastSeen)
        if total != window { window = total }
        let newRTT = rttSamples.count > 0 ? rttSamples.sum / Double(rttSamples.count) : nil
        if newRTT != rtt && (newRTT != nil || connections == 0) { rtt = newRTT }
        rttSamples = (0, 0)
    }

    /// Visible in the sidebar or on the map for this window.
    func isVisible(in timeWindow: TimeWindow) -> Bool {
        !window.isZero || (timeWindow.isLive && connections > 0)
    }

    var isActive: Bool { rate.isActive }
}

nonisolated struct PortUse: Hashable, Codable, Sendable, Comparable {
    var transport: TransportKind
    var port: Int

    static func < (lhs: PortUse, rhs: PortUse) -> Bool {
        (lhs.port, lhs.transport.rawValue) < (rhs.port, rhs.transport.rawValue)
    }
}

@Observable
final class AppActivity: Identifiable, ActivityEntity {
    let id: String
    var identity: AppIdentity
    var window = Traffic.zero
    var rate = Rate.zero
    var meter: [Traffic] = Array(repeating: .zero, count: 6)
    var lastSeen: Int
    var connections = 0
    var rtt: Double?
    var hosts: [String: HostActivity] = [:]
    var processes: [String: ProcessActivity] = [:]
    var siteIDs: Set<String> = []
    var retransmitted: UInt64 = 0
    var sentForRetransmission: UInt64 = 0

    @ObservationIgnored var loss = LossWindow()
    @ObservationIgnored var stats = ActivityStats()
    @ObservationIgnored var pending = Traffic.zero
    @ObservationIgnored var rttSamples: (sum: Double, count: Int) = (0, 0)

    init(identity: AppIdentity, lastSeen: Int) {
        id = identity.id
        self.identity = identity
        self.lastSeen = lastSeen
    }
}

@Observable
final class HostActivity: Identifiable, ActivityEntity {
    let id: String
    let appID: String
    let label: String
    var kind: HostLabelKind
    var hostnames: Set<String> = []
    var addresses: Set<String> = []
    var ports: Set<PortUse> = []
    var siteIDs: Set<String> = []
    var organization: String?
    var window = Traffic.zero
    var rate = Rate.zero
    var meter: [Traffic] = Array(repeating: .zero, count: 6)
    var lastSeen: Int
    var connections = 0
    var rtt: Double?
    /// The tracker behind one of its hostnames, from the tracker lists.
    var tracker: TrackerInfo?
    /// Unencrypted protocols this host was reached with.
    var plaintext: Set<PlaintextProtocol> = []

    @ObservationIgnored var stats = ActivityStats()
    @ObservationIgnored var pending = Traffic.zero
    @ObservationIgnored var rttSamples: (sum: Double, count: Int) = (0, 0)
    /// Last second it moved bytes in plaintext.
    @ObservationIgnored var plaintextLastSeen: Int?
    @ObservationIgnored var loss = LossWindow()
    @ObservationIgnored var rttBaseline: Double?

    /// Plaintext that matters: certificate checks and captive-portal probes do not count.
    var hasRiskyPlaintext: Bool { !plaintext.isEmpty && !SpecialHosts.isBenignPlaintext(hostnames: hostnames) }

    init(appID: String, label: String, kind: HostLabelKind, lastSeen: Int) {
        id = "\(appID)|\(label)"
        self.appID = appID
        self.label = label
        self.kind = kind
        self.lastSeen = lastSeen
    }
}

@Observable
final class ProcessActivity: Identifiable, ActivityEntity {
    let id: String
    let appID: String
    let name: String
    var path: String
    var pids: Set<Int32> = []
    var hostLabels: Set<String> = []
    var window = Traffic.zero
    var rate = Rate.zero
    var meter: [Traffic] = Array(repeating: .zero, count: 6)
    var lastSeen: Int
    var connections = 0
    var rtt: Double?

    @ObservationIgnored var stats = ActivityStats()
    @ObservationIgnored var pending = Traffic.zero
    @ObservationIgnored var rttSamples: (sum: Double, count: Int) = (0, 0)

    init(appID: String, name: String, path: String, lastSeen: Int) {
        id = "\(appID)|\(name)"
        self.appID = appID
        self.name = name
        self.path = path
        self.lastSeen = lastSeen
    }
}

@Observable
final class SiteActivity: Identifiable, ActivityEntity {
    let id: String
    let place: GeoPlace
    var addresses: Set<String> = []
    var labels: Set<String> = []
    var organizations: Set<String> = []
    var appIDs: Set<String> = []
    var ports: Set<PortUse> = []
    var window = Traffic.zero
    var rate = Rate.zero
    var lastSeen: Int
    var connections = 0
    var rtt: Double?

    @ObservationIgnored var stats = ActivityStats()
    @ObservationIgnored var pending = Traffic.zero
    @ObservationIgnored var rttSamples: (sum: Double, count: Int) = (0, 0)
    @ObservationIgnored var loss = LossWindow()
    @ObservationIgnored var rttBaseline: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }

    /// « Paris », or the country when the city is unknown.
    var title: String { place.city ?? place.country ?? String(localized: "Unknown place") }

    init(id: String, place: GeoPlace, lastSeen: Int) {
        self.id = id
        self.place = place
        self.lastSeen = lastSeen
    }

    static func identifier(for place: GeoPlace) -> String {
        String(format: "%.2f,%.2f", place.latitude, place.longitude)
    }
}

/// A remote address, looked up once.
struct Endpoint {
    var scope: AddressScope
    var place: GeoPlace?
    var owner: NetworkOwner?
    /// The owner's name cleaned for display (« Google »), worked out once per address.
    var organization: String?
    var siteID: String?
}
