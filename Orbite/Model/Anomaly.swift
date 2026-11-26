import Foundation

/// An hour where an app sent or received far more than its usual active hour.
nonisolated struct AnomalyFinding: Equatable, Sendable {
    enum Direction: String, Sendable { case up, down }

    var direction: Direction
    var bytes: UInt64
    /// Median of the app's active hours over the week before.
    var usual: UInt64
    /// Epoch hour index the volume belongs to.
    var hour: Int32

    var factor: Int { usual == 0 ? 0 : Int((Double(bytes) / Double(usual)).rounded()) }
}

/// Compares an app's current and previous hour with the median of its active hours of the week before.
nonisolated enum AnomalyRules {
    static let uploadFactor = 10.0
    static let uploadFloor: UInt64 = 50_000_000
    static let downloadFactor = 20.0
    static let downloadFloor: UInt64 = 200_000_000
    /// Fewer active hours than this and there is no « usual » to compare with.
    static let minimumBaseline = 3
    static let cooldown = 6 * 3600

    /// The strongest finding for the current or the previous hour, if any.
    static func check(hours: [Int32: Traffic], now: Int) -> AnomalyFinding? {
        let current = Int32(now / 3600)
        let baselineStart = current - 1 - 7 * 24
        var outs: [UInt64] = [], ins: [UInt64] = []
        for (hour, traffic) in hours where hour >= baselineStart && hour < current - 1 {
            if traffic.bytesOut > 0 { outs.append(traffic.bytesOut) }
            if traffic.bytesIn > 0 { ins.append(traffic.bytesIn) }
        }
        var uploads: [AnomalyFinding] = [], downloads: [AnomalyFinding] = []
        for hour in [current, current - 1] {
            guard let traffic = hours[hour] else { continue }
            if let finding = judge(traffic.bytesOut, baseline: outs, factor: uploadFactor, floor: uploadFloor,
                                   direction: .up, hour: hour) { uploads.append(finding) }
            if let finding = judge(traffic.bytesIn, baseline: ins, factor: downloadFactor, floor: downloadFloor,
                                   direction: .down, hour: hour) { downloads.append(finding) }
        }
        // Sending a lot is the more telling of the two: it wins over any download.
        return uploads.max { $0.bytes < $1.bytes } ?? downloads.max { $0.bytes < $1.bytes }
    }

    private static func judge(_ bytes: UInt64, baseline: [UInt64], factor: Double, floor: UInt64,
                              direction: AnomalyFinding.Direction, hour: Int32) -> AnomalyFinding? {
        guard baseline.count >= minimumBaseline, bytes > floor else { return nil }
        let usual = median(baseline)
        guard Double(bytes) > Double(usual) * factor else { return nil }
        return AnomalyFinding(direction: direction, bytes: bytes, usual: usual, hour: hour)
    }

    static func median(_ values: [UInt64]) -> UInt64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// One event per app and direction every 6 hours.
    static func allowed(_ key: String, in last: [String: Int], now: Int) -> Bool {
        guard let previous = last[key] else { return true }
        return now - previous >= cooldown
    }
}
