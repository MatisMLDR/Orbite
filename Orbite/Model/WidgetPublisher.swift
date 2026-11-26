import Foundation
import WidgetKit

/// Writes what the desktop widget shows into the app group container, once a minute when it changed,
/// and asks WidgetKit to reload at most every 15 minutes (its daily budget is small).
final class WidgetPublisher {
    private var last: WidgetSnapshot?
    private var lastReload: Date?
    private var timer: Timer?

    func start(model: AppModel) {
        guard timer == nil, WidgetSnapshot.file != nil else { return }
        publish(model: model)
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self, weak model] _ in
            MainActor.assumeIsolated {
                guard let self, let model else { return }
                self.publish(model: model)
            }
        }
        timer.tolerance = 15
        self.timer = timer
    }

    func publish(model: AppModel) {
        guard let file = WidgetSnapshot.file else { return }
        let store = model.store
        let now = store.now
        let startOfDay = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let today = store.total(from: startOfDay)
        let hourEnd = (now / 3600 + 1) * 3600
        let hours = store.global.buckets.bins(count: 24, width: 3600, end: hourEnd, now: now).map(\.total)
        let top = store.apps.values
            .map { WidgetSnapshot.App(name: $0.identity.name, bytes: $0.stats.buckets.sum(from: startOfDay, to: now + 1, now: now).total) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
        let networks = model.networks
        let onMobile = model.network.currentNetwork.flatMap { networks.record($0.id)?.isMobile } ?? false
        let quota = networks.quotaGB > 0 ? UInt64(networks.quotaGB * 1_000_000_000) : nil
        let mobile = onMobile || quota != nil ? networks.mobileUsage().total.total : nil
        let event = JournalRules.group(model.journal.events.suffix(20)).first?.title
        // Rounded to the megabyte so a few bytes do not rewrite the file every minute.
        func round(_ value: UInt64) -> UInt64 { value / 1_000_000 * 1_000_000 }
        let snapshot = WidgetSnapshot(date: Date(), todayIn: round(today.bytesIn), todayOut: round(today.bytesOut),
                                      hours: hours.map(round), topApps: Array(top.prefix(3)).map { .init(name: $0.name, bytes: round($0.bytes)) },
                                      mobileUsed: mobile.map(round), mobileQuota: quota, lastEvent: event)
        var comparable = snapshot
        comparable.date = last?.date ?? snapshot.date
        guard comparable != last else { return }
        do {
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            last = snapshot
        } catch {
            return
        }
        if lastReload.map({ Date().timeIntervalSince($0) >= 15 * 60 }) ?? true {
            lastReload = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        }
    }
}
