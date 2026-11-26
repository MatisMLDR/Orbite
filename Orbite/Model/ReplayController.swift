import Foundation
import Observation

/// Plays the last 24 hours on the map: 24 hours in a minute at 1×, faster on demand.
@Observable
final class ReplayController {
    let timeline: ReplayTimeline
    /// The slot on screen; changes about five times a second at 1×, which is when the map is rebuilt.
    private(set) var slot = 0
    private(set) var playing = false
    var speed: Double = 1

    @ObservationIgnored private var position = 0.0
    @ObservationIgnored private var task: Task<Void, Never>?

    static let secondsAtNormalSpeed = 60.0

    init(timeline: ReplayTimeline) {
        self.timeline = timeline
        // Start where something happened, not on an empty night.
        let first = timeline.global.firstIndex { !$0.isZero } ?? 0
        position = Double(max(0, first - ReplayTimeline.trail))
        slot = Int(position)
    }

    var date: Date { timeline.date(of: slot) }
    var atEnd: Bool { slot >= ReplayTimeline.slotCount - 1 }

    func play() {
        if atEnd { seek(0) }
        playing = true
        task?.cancel()
        task = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.playing else { return }
                let now = clock.now
                let elapsed = last.duration(to: now)
                last = now
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                self.position += seconds * self.speed * Double(ReplayTimeline.slotCount) / Self.secondsAtNormalSpeed
                if self.position >= Double(ReplayTimeline.slotCount - 1) {
                    self.position = Double(ReplayTimeline.slotCount - 1)
                    self.playing = false
                }
                let slot = Int(self.position)
                if slot != self.slot { self.slot = slot }
            }
        }
    }

    func pause() {
        playing = false
        task?.cancel()
        task = nil
    }

    func toggle() { playing ? pause() : play() }

    func seek(_ slot: Int) {
        position = Double(min(max(slot, 0), ReplayTimeline.slotCount - 1))
        if Int(position) != self.slot { self.slot = Int(position) }
    }

    func stop() { pause() }
}
