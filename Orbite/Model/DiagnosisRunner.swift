import Foundation
import Observation

/// Runs « Pourquoi c'est lent ? »: pings the router and the internet for a few seconds, reads what Orbite
/// already measures, and keeps the result for the sheet and the menu bar panel.
@Observable
final class DiagnosisRunner {
    enum State: Equatable {
        case idle
        case running(Double)
        case done(DiagnosisResult)
    }

    private(set) var state: State = .idle
    static let probe = "1.1.1.1"

    var isRunning: Bool { if case .running = state { true } else { false } }
    var result: DiagnosisResult? { if case .done(let result) = state { result } else { nil } }

    func run(model: AppModel) async {
        guard !isRunning else { return }
        state = .running(0)
        let network = model.network
        network.refresh()
        let router = network.router.flatMap { IPAddress.scope($0) == .localNetwork ? $0 : nil }

        let progress = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let fraction = min(0.95, Date().timeIntervalSince(start) / 3.5)
                if case .running = self?.state { self?.state = .running(fraction) }
            }
        }
        let (routerStats, internetStats) = await measure(router: router)
        progress.cancel()

        let store = model.store
        let now = store.now
        let identity = network.currentNetwork
        let record = identity.flatMap { model.networks.record($0.id) }
        var input = DiagnosisInput()
        input.online = network.isOnline
        if let wifi = network.wifi {
            let band = wifi.channel?.components(separatedBy: " · ").last
            input.wifi = .init(rssi: wifi.rssi, noise: wifi.noise, band: band, transmitRate: wifi.transmitRate)
        }
        input.router = routerStats
        input.routerAddress = router
        input.internet = internetStats
        input.routerBaseline = record?.routerBaseline
        input.internetBaseline = record?.internetBaseline
        input.currentRate = store.totalRate.total
        input.peakRate = record?.peakRate ?? 0
        if let top = store.liveApps(limit: 1).first {
            input.topTalker = .init(id: top.id, name: top.identity.name, rate: top.rate.total,
                                    uploading: top.rate.outPerSecond > top.rate.inPerSecond)
        }
        input.destinations = store.sites.values.compactMap { site in
            guard site.connections > 0, let rtt = site.rtt else { return nil }
            return .init(id: site.id, title: site.title, rtt: rtt, baseline: site.rttBaseline, loss: site.loss.ratio(now: now))
        }
        input.lossyApps = store.apps.values.compactMap { app in
            app.loss.ratio(now: now).map { .init(id: app.id, name: app.identity.name, ratio: $0) }
        }

        let result = Diagnosis.run(input)
        // A healthy measure teaches what « usual » is on this network.
        let unhealthy: Set<String> = ["router", "internet-loss", "internet-slow", "offline"]
        if let identity, !result.findings.contains(where: { unhealthy.contains($0.id) }) {
            model.networks.setBaselines(router: routerStats?.silent == false ? routerStats?.median : nil,
                                        internet: internetStats?.median, for: identity.id)
        }
        state = .done(result)
    }

    func reset() { state = .idle }

    /// Both probes run at the same time: the router here, the internet in a child task.
    private func measure(router: String?) async -> (PingStats?, PingStats?) {
        #if DEBUG
        if Demo.isActive {
            try? await Task.sleep(for: .seconds(2.5))
            return (Demo.pings.router, Demo.pings.internet)
        }
        #endif
        async let internetPing = Pinger.ping(Self.probe)
        let routerStats: PingStats? = if let router { await Pinger.ping(router) } else { nil }
        return (routerStats, await internetPing)
    }
}
