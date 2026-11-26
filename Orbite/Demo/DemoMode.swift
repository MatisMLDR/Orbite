#if DEBUG
import AppKit
import CoreLocation
import Foundation

/// Screenshot mode, in Debug builds only. `ORBITE_DEMO=1` fills Orbite with a made-up week of traffic
/// instead of the Mac's own: nothing is read from nettop, the helper, Location Services or the Wi-Fi card,
/// and the data folder is a temporary one, so the real history is neither shown nor touched.
///
/// - `ORBITE_DEMO_SCENE`: what to show once the data is in: `globe` (default), `app:<name>`,
///   `host:<label>`, `site:<city>`, `recap`, `diagnosis`, `search`, `journal`.
/// - `ORBITE_DEMO_WINDOW`: the window's content size, such as `1440x900`.
/// - `ORBITE_DEMO_APPEARANCE`: `dark` or `light`.
///
/// Map settings and the language come from launch arguments, which macOS reads without saving them:
/// `-mapLook globe -globeDayNight YES -AppleLanguages '(en)' -AppleLocale en_US`.
nonisolated enum Demo {
    static let isActive = ProcessInfo.processInfo.environment["ORBITE_DEMO"] == "1"
    static var scene: String { ProcessInfo.processInfo.environment["ORBITE_DEMO_SCENE"] ?? "globe" }

    /// Paris: a home that is nobody's in particular.
    static let home = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)

    static var windowSize: CGSize? {
        let parts = (ProcessInfo.processInfo.environment["ORBITE_DEMO_WINDOW"] ?? "").split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
        return CGSize(width: width, height: height)
    }

    static var appearance: NSAppearance? {
        switch ProcessInfo.processInfo.environment["ORBITE_DEMO_APPEARANCE"] {
        case "dark": NSAppearance(named: .darkAqua)
        case "light": NSAppearance(named: .aqua)
        default: nil
        }
    }

    /// A fresh data folder, with copies of the GeoIP and tracker databases already on this Mac so the map
    /// works without downloading them again.
    static let directory: URL = {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("OrbiteDemo", isDirectory: true)
        try? fileManager.removeItem(at: folder)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbite", isDirectory: true)
        for name in ["GeoIP", "Trackers"] {
            try? fileManager.copyItem(at: real.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        return folder
    }()

    /// What the diagnosis « measures »: a quick router, a normal internet.
    static let pings = (router: PingStats(sent: 10, received: 10, median: 3.2),
                        internet: PingStats(sent: 10, received: 10, median: 14.8))
}

/// Feeds made-up nettop samples through the real pipeline: a week of history first, then one sample a second.
@MainActor
final class DemoFeed {
    private enum Rhythm {
        case day, evening, night, steady

        /// Share of the full rate at an hour of the day.
        func activity(hour: Int) -> Double {
            switch self {
            case .day: [0.04, 0.02, 0.02, 0.02, 0.02, 0.03, 0.08, 0.3, 0.7, 1, 1, 0.9, 0.6, 0.8, 0.9, 1, 0.9, 0.8, 0.6, 0.5, 0.5, 0.4, 0.2, 0.1][hour]
            case .evening: [0.4, 0.2, 0.02, 0.01, 0.01, 0.01, 0.02, 0.05, 0.1, 0.1, 0.1, 0.1, 0.3, 0.2, 0.1, 0.1, 0.1, 0.2, 0.5, 0.8, 1, 1, 0.9, 0.7][hour]
            case .night: [0.1, 0.6, 1, 1, 0.8, 0.2, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.05][hour]
            case .steady: 0.6
            }
        }
    }

    private struct App {
        let pid: Int32
        let path: String
        /// What nettop prints, truncated like the kernel's process name.
        var name: String { String((path as NSString).lastPathComponent.prefix(15)) }
    }

    private struct Flow {
        let pid: Int32
        let hostname: String
        let address: String
        let port: Int
        let transport: TransportKind
        /// Bytes a second at full activity.
        let down: Double
        let up: Double
        let rtt: Double
        let rhythm: Rhythm
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
    }

    private let apps: [App] = [
        App(pid: 41_001, path: "/Applications/Safari.app/Contents/MacOS/Safari"),
        App(pid: 41_002, path: "/System/Applications/Music.app/Contents/MacOS/Music"),
        App(pid: 41_003, path: "/System/Applications/TV.app/Contents/MacOS/TV"),
        App(pid: 41_004, path: "/System/Applications/Photos.app/Contents/MacOS/Photos"),
        App(pid: 41_005, path: "/System/Applications/Mail.app/Contents/MacOS/Mail"),
        App(pid: 41_006, path: "/System/Applications/Messages.app/Contents/MacOS/Messages"),
        App(pid: 41_007, path: "/System/Applications/Maps.app/Contents/MacOS/Maps"),
        App(pid: 41_008, path: "/System/Applications/News.app/Contents/MacOS/News"),
        App(pid: 41_009, path: "/System/Applications/Podcasts.app/Contents/MacOS/Podcasts"),
        App(pid: 41_010, path: "/System/Applications/Weather.app/Contents/MacOS/Weather"),
        App(pid: 41_011, path: "/System/Applications/App Store.app/Contents/MacOS/App Store"),
        App(pid: 41_020, path: "/usr/bin/curl"),
        App(pid: 41_021, path: "/usr/bin/git"),
        App(pid: 41_030, path: "/usr/libexec/nsurlsessiond"),
        App(pid: 41_031, path: "/usr/libexec/apsd"),
    ]

    // Addresses of public cloud regions, so the GeoIP database spreads them around the world.
    private var flows: [Flow] = [
        Flow(pid: 41_001, hostname: "www.nhk.or.jp", address: "13.112.10.20", port: 443, transport: .tcp, down: 60_000, up: 4_000, rtt: 242, rhythm: .day),
        Flow(pid: 41_001, hostname: "www.abc.net.au", address: "13.236.10.20", port: 443, transport: .tcp, down: 40_000, up: 3_000, rtt: 288, rhythm: .evening),
        Flow(pid: 41_001, hostname: "g1.globo.com", address: "18.228.10.20", port: 443, transport: .tcp, down: 35_000, up: 3_000, rtt: 203, rhythm: .day),
        Flow(pid: 41_001, hostname: "www.bbc.co.uk", address: "35.176.10.20", port: 443, transport: .tcp, down: 90_000, up: 6_000, rtt: 12, rhythm: .day),
        Flow(pid: 41_001, hostname: "www.spiegel.de", address: "3.120.10.20", port: 443, transport: .tcp, down: 50_000, up: 4_000, rtt: 17, rhythm: .day),
        Flow(pid: 41_001, hostname: "github.com", address: "140.82.112.3", port: 443, transport: .tcp, down: 120_000, up: 20_000, rtt: 148, rhythm: .day),
        Flow(pid: 41_001, hostname: "www.lemonde.fr", address: "15.188.10.20", port: 443, transport: .tcp, down: 80_000, up: 5_000, rtt: 4, rhythm: .day),
        Flow(pid: 41_001, hostname: "rr4---sn-25ge7nzk.googlevideo.com", address: "34.155.10.20", port: 443, transport: .quic, down: 900_000, up: 30_000, rtt: 6, rhythm: .evening),
        Flow(pid: 41_001, hostname: "www.straitstimes.com", address: "13.228.10.20", port: 443, transport: .tcp, down: 25_000, up: 2_000, rtt: 168, rhythm: .day),
        Flow(pid: 41_001, hostname: "www.ndtv.com", address: "13.126.10.20", port: 443, transport: .tcp, down: 20_000, up: 2_000, rtt: 118, rhythm: .day),
        Flow(pid: 41_001, hostname: "www.cbc.ca", address: "3.96.10.20", port: 443, transport: .tcp, down: 30_000, up: 2_000, rtt: 94, rhythm: .day),
        Flow(pid: 41_001, hostname: "www.news24.com", address: "13.244.10.20", port: 443, transport: .tcp, down: 15_000, up: 1_500, rtt: 163, rhythm: .evening),
        Flow(pid: 41_001, hostname: "www.chosun.com", address: "13.124.10.20", port: 443, transport: .tcp, down: 15_000, up: 1_500, rtt: 258, rhythm: .day),
        Flow(pid: 41_001, hostname: "www.rte.ie", address: "34.240.10.20", port: 443, transport: .tcp, down: 25_000, up: 2_000, rtt: 21, rhythm: .day),
        Flow(pid: 41_001, hostname: "www.scmp.com", address: "43.198.10.20", port: 443, transport: .tcp, down: 20_000, up: 2_000, rtt: 208, rhythm: .day),
        Flow(pid: 41_001, hostname: "www.dn.se", address: "13.48.10.20", port: 443, transport: .tcp, down: 25_000, up: 2_000, rtt: 34, rhythm: .day),
        Flow(pid: 41_001, hostname: "stats.g.doubleclick.net", address: "142.250.179.110", port: 443, transport: .tcp, down: 3_000, up: 6_000, rtt: 151, rhythm: .day),
        Flow(pid: 41_001, hostname: "www.google-analytics.com", address: "108.177.10.20", port: 443, transport: .tcp, down: 2_000, up: 5_000, rtt: 150, rhythm: .day),
        Flow(pid: 41_001, hostname: "sb.scorecardresearch.com", address: "52.84.150.10", port: 443, transport: .tcp, down: 1_000, up: 3_000, rtt: 86, rhythm: .day),
        Flow(pid: 41_002, hostname: "aod.itunes.apple.com", address: "17.253.144.10", port: 443, transport: .tcp, down: 36_000, up: 1_000, rtt: 152, rhythm: .evening),
        Flow(pid: 41_002, hostname: "audio-ssl.itunes.apple.com", address: "23.215.0.136", port: 443, transport: .tcp, down: 30_000, up: 800, rtt: 84, rhythm: .day),
        Flow(pid: 41_003, hostname: "play-edge.itunes.apple.com", address: "2.18.10.20", port: 443, transport: .tcp, down: 2_400_000, up: 20_000, rtt: 14, rhythm: .evening),
        Flow(pid: 41_004, hostname: "p48-content.icloud.com", address: "17.248.236.20", port: 443, transport: .tcp, down: 10_000, up: 600_000, rtt: 155, rhythm: .night),
        Flow(pid: 41_005, hostname: "p48-imap.mail.me.com", address: "17.253.144.10", port: 993, transport: .tcp, down: 8_000, up: 2_000, rtt: 150, rhythm: .day),
        Flow(pid: 41_006, hostname: "identity.ess.apple.com", address: "17.248.236.20", port: 443, transport: .tcp, down: 2_000, up: 1_500, rtt: 154, rhythm: .steady),
        Flow(pid: 41_007, hostname: "gspe35-ssl.ls.apple.com", address: "2.18.10.20", port: 443, transport: .tcp, down: 50_000, up: 2_000, rtt: 15, rhythm: .day),
        Flow(pid: 41_008, hostname: "news-edge.apple.com", address: "23.215.0.136", port: 443, transport: .tcp, down: 30_000, up: 1_000, rtt: 85, rhythm: .day),
        Flow(pid: 41_009, hostname: "anchor.fm", address: "18.184.10.20", port: 443, transport: .tcp, down: 40_000, up: 1_000, rtt: 19, rhythm: .evening),
        Flow(pid: 41_010, hostname: "weatherkit.apple.com", address: "17.253.144.10", port: 443, transport: .tcp, down: 3_000, up: 500, rtt: 151, rhythm: .steady),
        Flow(pid: 41_011, hostname: "osxapps.itunes.apple.com", address: "13.56.10.20", port: 443, transport: .tcp, down: 150_000, up: 2_000, rtt: 146, rhythm: .day),
        Flow(pid: 41_020, hostname: "example.com", address: "23.215.0.136", port: 80, transport: .tcp, down: 5_000, up: 1_000, rtt: 86, rhythm: .day),
        Flow(pid: 41_021, hostname: "github.com", address: "140.82.112.3", port: 443, transport: .tcp, down: 80_000, up: 10_000, rtt: 147, rhythm: .day),
        Flow(pid: 41_030, hostname: "swcdn.apple.com", address: "3.80.10.20", port: 443, transport: .tcp, down: 300_000, up: 3_000, rtt: 88, rhythm: .day),
        Flow(pid: 41_031, hostname: "courier.push.apple.com", address: "17.253.144.10", port: 5223, transport: .tcp, down: 500, up: 300, rtt: 150, rhythm: .steady),
    ]

    private unowned let model: AppModel
    private var timer: Timer?
    private var random = SplitMix(seed: 2026)
    private var tick = 0

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        for app in apps { model.resolver.demoPaths[app.pid] = app.path }
        model.names.ingest(flows.map { DNSMapping(address: $0.address, hostname: $0.hostname, seenAt: Date()) })
        if let appearance = Demo.appearance { NSApp.appearance = appearance }
        waitForDatabase(tries: 50)
    }

    /// Places need the GeoIP database: history fed before it opens would have no place.
    private func waitForDatabase(tries: Int) {
        guard model.store.geo == nil, tries > 0 else {
            fillHistory()
            run()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.waitForDatabase(tries: tries - 1) }
    }

    /// A week of hours, then the last day in 5-minute steps. Each step is two samples a second apart: the
    /// first only sets the counters, the second carries the step's bytes.
    private func fillHistory() {
        let now = Date().timeIntervalSince1970
        let calendar = Calendar.current
        var steps: [(start: TimeInterval, length: TimeInterval)] = []
        var time = (now - 7 * 86_400).rounded(.down)
        while time < now - 86_400 { steps.append((time, 3600)); time += 3600 }
        while time < now - 330 { steps.append((time, 300)); time += 300 }
        for step in steps {
            let date = Date(timeIntervalSince1970: step.start)
            let hour = calendar.component(.hour, from: date)
            let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
            model.store.ingest(sample(at: date))
            for index in flows.indices {
                // Some days a site is not visited at all; the others vary around its usual rhythm.
                var dayRandom = SplitMix(seed: UInt64(day * 131 + index))
                let presence = dayRandom.next() < 0.2 ? 0 : 0.5 + dayRandom.next()
                let share = 0.1 * flows[index].rhythm.activity(hour: hour) * presence * (0.8 + 0.4 * random.next())
                add(index, seconds: step.length * share)
            }
            model.store.ingest(sample(at: date.addingTimeInterval(1)))
        }
        // The last five minutes second by second, like the live feed, for the charts of the live window.
        time = now - 300
        while time < now - 1 {
            liveStep(at: Date(timeIntervalSince1970: time))
            time += 1
        }
    }

    private func run() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        self.timer = timer
        step()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showScene() }
    }

    private func step() {
        liveStep(at: Date())
        let store = model.store
        model.networks.ingest(store: store, network: model.network.currentNetwork, now: store.now)
        model.menuBarFeed.update(from: store)
        model.network.setDemoLinkRate(store.totalRate)
    }

    /// One live second: every flow moves, around a slow wave so the comets come and go.
    private func liveStep(at date: Date) {
        tick += 1
        for index in flows.indices {
            let wave = 0.55 + 0.45 * sin(Double(tick) / 7 + Double(index) * 1.7)
            let level = flows[index].rhythm == .night ? 0.15 : 1.0
            add(index, seconds: level * wave * (0.85 + 0.3 * random.next()))
        }
        model.store.ingest(sample(at: date))
    }

    private func add(_ index: Int, seconds: Double) {
        guard seconds > 0 else { return }
        flows[index].bytesIn += UInt64(flows[index].down * seconds)
        flows[index].bytesOut += UInt64(flows[index].up * seconds)
    }

    private func sample(at date: Date) -> NetTopSample {
        let processes = apps.map { app in
            let own = flows.enumerated().filter { $0.element.pid == app.pid }
            let netFlows = own.map { index, flow in
                NetTopFlow(transport: flow.transport, isIPv6: false,
                           local: SocketEndpoint(address: "192.168.1.24", port: 50_000 + index),
                           remote: SocketEndpoint(address: flow.address, port: flow.port), interface: "en0",
                           state: flow.transport == .tcp ? "Established" : "", bytesIn: flow.bytesIn,
                           bytesOut: flow.bytesOut, retransmitted: 0,
                           rtt: flow.transport == .tcp ? flow.rtt * (0.95 + 0.1 * random.next()) : nil)
            }
            return NetTopProcess(name: app.name, pid: app.pid,
                                 bytesIn: netFlows.reduce(0) { $0 + $1.bytesIn },
                                 bytesOut: netFlows.reduce(0) { $0 + $1.bytesOut }, flows: netFlows)
        }
        return NetTopSample(date: date, processes: processes)
    }

    private func showScene() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            if let size = Demo.windowSize {
                window.setContentSize(size)
                window.center()
            }
            // In front, or Stage Manager keeps it as a thumbnail at the side of the screen.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        let ui = model.ui
        let store = model.store
        let scene = Demo.scene
        let argument = scene.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        switch scene.split(separator: ":").first.map(String.init) ?? scene {
        case "app":
            ui.selection = store.apps.values.first { $0.identity.name == argument }.map { .app($0.id) }
        case "host":
            for app in store.apps.values {
                if let host = app.hosts.values.first(where: { $0.label == argument }) {
                    ui.selection = .host("\(app.id)|\(host.label)")
                    break
                }
            }
        case "site":
            ui.selection = store.sites.values.first { $0.title == argument }.map { .site($0.id) }
        case "recap": ui.showRecap = true
        case "diagnosis": ui.showDiagnosis = true
        case "search": ui.showPalette = true
        case "journal": ui.showJournal = true
        default: break
        }
    }
}

/// Small, seeded random numbers: the same demo on every run.
private struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// 0 ..< 1.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
#endif
