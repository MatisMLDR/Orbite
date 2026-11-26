import Foundation

/// Bytes received and sent.
nonisolated struct Traffic: Codable, Hashable, Sendable {
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0

    static let zero = Traffic()

    var total: UInt64 { bytesIn + bytesOut }
    var isZero: Bool { bytesIn == 0 && bytesOut == 0 }

    static func + (lhs: Traffic, rhs: Traffic) -> Traffic {
        Traffic(bytesIn: lhs.bytesIn + rhs.bytesIn, bytesOut: lhs.bytesOut + rhs.bytesOut)
    }

    static func += (lhs: inout Traffic, rhs: Traffic) { lhs = lhs + rhs }

    /// Saturating difference (never below zero).
    static func - (lhs: Traffic, rhs: Traffic) -> Traffic {
        Traffic(bytesIn: lhs.bytesIn >= rhs.bytesIn ? lhs.bytesIn - rhs.bytesIn : 0,
                bytesOut: lhs.bytesOut >= rhs.bytesOut ? lhs.bytesOut - rhs.bytesOut : 0)
    }
}

/// Bytes per second.
nonisolated struct Rate: Equatable, Sendable {
    var inPerSecond: Double = 0
    var outPerSecond: Double = 0

    static let zero = Rate()
    var total: Double { inPerSecond + outPerSecond }
    var isActive: Bool { total > 0 }

    init(inPerSecond: Double = 0, outPerSecond: Double = 0) {
        self.inPerSecond = inPerSecond
        self.outPerSecond = outPerSecond
    }

    init(_ traffic: Traffic, over seconds: Double) {
        let interval = max(seconds, 0.001)
        inPerSecond = Double(traffic.bytesIn) / interval
        outPerSecond = Double(traffic.bytesOut) / interval
    }
}

/// The last `capacity` seconds, one slot per second, with a running sum.
nonisolated struct SecondRing: Sendable {
    let capacity: Int
    private var slots: [Traffic]
    /// Epoch second of the newest slot.
    private(set) var newest: Int
    private(set) var sum = Traffic.zero

    init(capacity: Int = 300, now: Int) {
        self.capacity = capacity
        slots = Array(repeating: .zero, count: capacity)
        newest = now
    }

    /// Moves the ring forward to `second`, clearing the slots that fall out of it.
    mutating func advance(to second: Int) {
        guard second > newest else { return }
        let steps = min(second - newest, capacity)
        for step in 1...steps {
            let index = (newest + step) % capacity
            sum = sum - slots[index]
            slots[index] = .zero
        }
        newest = second
    }

    mutating func add(_ traffic: Traffic, at second: Int) {
        advance(to: second)
        guard second > newest - capacity, !traffic.isZero else { return }
        let index = ((second % capacity) + capacity) % capacity
        slots[index] += traffic
        sum += traffic
    }

    func value(at second: Int) -> Traffic {
        guard second <= newest, second > newest - capacity else { return .zero }
        return slots[((second % capacity) + capacity) % capacity]
    }

    /// Sum of the seconds in `[start, end)`; zero for the part the ring no longer (or not yet) holds.
    func sum(from start: Int, to end: Int) -> Traffic {
        let first = max(start, newest - capacity + 1), last = min(end, newest + 1)
        guard first < last else { return .zero }
        var total = Traffic.zero
        for second in first..<last {
            total += value(at: second)
        }
        return total
    }

    /// `count` bins of `width` seconds ending at `end` (exclusive), oldest first.
    func bins(count: Int, width: Int, end: Int) -> [Traffic] {
        (0..<count).map { index in
            let start = end - (count - index) * width
            return sum(from: start, to: start + width)
        }
    }
}

/// Minute buckets for the last day and hour buckets for the last week, keyed by epoch index.
nonisolated struct TrafficBuckets: Codable, Sendable {
    var minutes: [Int32: Traffic] = [:]
    var hours: [Int32: Traffic] = [:]

    static let minuteHorizon = 26 * 3600
    static let hourHorizon = 8 * 86_400

    var isEmpty: Bool { minutes.isEmpty && hours.isEmpty }

    mutating func add(_ traffic: Traffic, at second: Int) {
        guard !traffic.isZero else { return }
        minutes[Int32(second / 60), default: .zero] += traffic
        hours[Int32(second / 3600), default: .zero] += traffic
    }

    /// Sum over `[start, end)`. Minute precision inside the last day, hour precision beyond.
    func sum(from start: Int, to end: Int, now: Int) -> Traffic {
        guard end > start else { return .zero }
        var total = Traffic.zero
        if start >= now - Self.minuteHorizon + 3600 {
            let first = Int32(start / 60), last = Int32((end - 1) / 60)
            for (minute, traffic) in minutes where minute >= first && minute <= last { total += traffic }
        } else {
            let first = Int32(start / 3600), last = Int32((end - 1) / 3600)
            for (hour, traffic) in hours where hour >= first && hour <= last { total += traffic }
        }
        return total
    }

    /// `count` bins of `width` seconds ending at `end` (exclusive), oldest first.
    func bins(count: Int, width: Int, end: Int, now: Int) -> [Traffic] {
        let start = end - count * width
        var result = Array(repeating: Traffic.zero, count: count)
        let useMinutes = start >= now - Self.minuteHorizon + 3600 && width >= 60
        if useMinutes {
            for (minute, traffic) in minutes {
                let second = Int(minute) * 60
                guard second >= start, second < end else { continue }
                result[(second - start) / width] += traffic
            }
        } else {
            for (hour, traffic) in hours {
                let second = Int(hour) * 3600
                guard second >= start, second < end else { continue }
                result[(second - start) / width] += traffic
            }
        }
        return result
    }

    mutating func prune(now: Int) {
        let oldestMinute = Int32((now - Self.minuteHorizon) / 60)
        let oldestHour = Int32((now - Self.hourHorizon) / 3600)
        minutes = minutes.filter { $0.key >= oldestMinute }
        hours = hours.filter { $0.key >= oldestHour }
    }
}

/// Length of the period the app summarizes.
nonisolated enum WindowSpan: String, CaseIterable, Identifiable, Codable, Sendable {
    case fiveMinutes, hour, day, week

    var id: Self { self }

    var seconds: Int {
        switch self {
        case .fiveMinutes: 300
        case .hour: 3600
        case .day: 86_400
        case .week: 7 * 86_400
        }
    }

    var label: String {
        switch self {
        case .fiveMinutes: "5 min"
        case .hour: "1 h"
        case .day: "24 h"
        case .week: String(localized: "7 d")
        }
    }

    var longLabel: String {
        switch self {
        case .fiveMinutes: String(localized: "last 5 minutes")
        case .hour: String(localized: "last hour")
        case .day: String(localized: "last 24 hours")
        case .week: String(localized: "last 7 days")
        }
    }

    /// Histogram bins: count and width in seconds.
    var bins: (count: Int, width: Int) {
        switch self {
        case .fiveMinutes: (30, 10)
        case .hour: (30, 120)
        case .day: (48, 1800)
        case .week: (42, 14_400)
        }
    }
}

/// The period on screen: the last `span` (live) or a past one ending at `end`.
nonisolated struct TimeWindow: Equatable, Sendable {
    var span: WindowSpan = .fiveMinutes
    /// Epoch second (exclusive). nil = live, ending now.
    var end: Int?

    var isLive: Bool { end == nil }

    func range(now: Int) -> (start: Int, end: Int) {
        let stop = end ?? now + 1
        return (stop - span.seconds, stop)
    }

    /// Bin-aligned end, so live histograms do not shift sub-bin every second.
    func histogramEnd(now: Int) -> Int {
        let width = span.bins.width
        let stop = end ?? now + 1
        return ((stop + width - 1) / width) * width
    }
}
