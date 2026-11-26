import Foundation

/// The last 24 hours cut into 5-minute slots, for every place and in all: built once from the minute
/// buckets, then read by slot while the replay plays, without touching the store.
nonisolated struct ReplayTimeline: Sendable {
    static let slotSeconds = 300
    static let slotCount = 288
    /// Slots summed for what the map shows at a given moment: the last 15 minutes.
    static let trail = 3

    /// Epoch second where slot 0 starts.
    let start: Int
    let global: [Traffic]
    let sites: [String: [Traffic]]

    var end: Int { start + Self.slotCount * Self.slotSeconds }

    init(start: Int, global: [Traffic], sites: [String: [Traffic]]) {
        self.start = start
        self.global = global
        self.sites = sites
    }

    /// The 24 hours ending at the slot that holds `now`.
    static func build(now: Int, global: [Int32: Traffic], sites: [String: [Int32: Traffic]]) -> ReplayTimeline {
        let end = (now / slotSeconds + 1) * slotSeconds
        let start = end - slotCount * slotSeconds
        func slots(_ minutes: [Int32: Traffic]) -> [Traffic]? {
            var result = Array(repeating: Traffic.zero, count: slotCount)
            var any = false
            for (minute, traffic) in minutes {
                let second = Int(minute) * 60
                guard second >= start, second < end else { continue }
                result[(second - start) / slotSeconds] += traffic
                any = true
            }
            return any ? result : nil
        }
        var perSite: [String: [Traffic]] = [:]
        for (id, minutes) in sites {
            if let slots = slots(minutes) { perSite[id] = slots }
        }
        return ReplayTimeline(start: start, global: slots(global) ?? Array(repeating: .zero, count: slotCount), sites: perSite)
    }

    func date(of slot: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(start + slot * Self.slotSeconds))
    }

    /// Bytes per place over the trail ending at `slot`, and over the slot alone.
    func places(at slot: Int) -> [(id: String, trail: Traffic, now: Traffic)] {
        let slot = min(max(slot, 0), Self.slotCount - 1)
        let first = max(0, slot - Self.trail + 1)
        return sites.compactMap { id, slots in
            var trail = Traffic.zero
            for index in first...slot { trail += slots[index] }
            return trail.isZero ? nil : (id, trail, slots[slot])
        }
    }
}
