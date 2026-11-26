import AppKit
import Foundation
import Observation
import SwiftUI

/// Wires the capture, the databases, the helper and the UI state together.
@Observable
final class AppModel {
    /// The running model, for App Intents and orbite:// links, which live outside the SwiftUI scenes.
    @ObservationIgnored nonisolated(unsafe) static weak var current: AppModel?
    let resolver = AppResolver()
    let names = HostnameResolver()
    let store: TrafficStore
    let geo = GeoDBUpdater()
    let trackers = TrackerListUpdater()
    let helper = HelperClient()
    let home = HomeLocation()
    let network = NetworkInfo()
    let ui = ViewState()
    let journal = JournalStore()
    let networks = NetworkLedgerStore()
    let diagnosis = DiagnosisRunner()
    /// The day replaying on the map, when it does.
    private(set) var replay: ReplayController?
    @ObservationIgnored private let widget = WidgetPublisher()
    /// What the menu bar item draws, published only when it changes.
    let menuBarFeed = MenuBarFeed()

    @ObservationIgnored private(set) var menuBar: MenuBarController?
    @ObservationIgnored private var stream: NetTopStream?
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var started = false
    /// The menu bar panel is on screen.
    @ObservationIgnored private var panelOpen = false
    #if DEBUG
    @ObservationIgnored private var demoFeed: DemoFeed?
    #endif

    init() {
        store = TrafficStore(resolver: resolver, names: names)
        if let snapshot = HistoryStore.load() { store.restore(snapshot) }
        journal.prepare(from: store)
        store.onDiscovery = { [weak self] discovery in
            guard let self else { return }
            self.journal.handle(discovery, store: self.store)
        }
        geo.onDatabase = { [weak self] database in self?.store.geo = database }
        trackers.onList = { [weak self] list in self?.store.trackers = list }
        helper.onMappings = { [weak self] mappings in self?.names.ingest(mappings) }
        ui.showOnboarding = !UserDefaults.standard.bool(forKey: ViewState.onboardingKey)
        #if DEBUG
        if Demo.isActive { ui.showOnboarding = false }
        #endif
        Self.current = self
    }

    // MARK: - Links and intents

    /// Brings the window back, optionally on a selection.
    func open(selecting selection: Selection? = nil) {
        if let menuBar {
            menuBar.showMainWindow(selecting: selection)
        } else {
            if let selection { ui.selection = selection }
            ui.openMainWindow?()
        }
    }

    /// orbite://app?id=…, orbite://diagnosis, orbite://recap, orbite://replay, orbite://journal, orbite://search.
    func handle(_ url: URL) {
        guard url.scheme == "orbite" else { return }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        switch url.host {
        case "app":
            open(selecting: id.flatMap { store.apps[$0] != nil ? .app($0) : nil })
        case "network":
            open(selecting: id.map { .network($0) })
        default:
            open()
        }
        DispatchQueue.main.async { [self] in
            switch url.host {
            case "diagnosis": ui.showDiagnosis = true
            case "recap": ui.showRecap = true
            case "replay": startReplay()
            case "journal": ui.showJournal = true
            case "search": ui.showPalette = true
            default: break
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if Demo.isActive { return startDemo() }
        #endif
        geo.start()
        trackers.start()
        helper.start()
        home.start()
        network.start()
        menuBar = MenuBarController(model: self)

        let stream = NetTopStream(
            onSample: { [weak self] sample in
                Task { @MainActor in
                    guard let self else { return }
                    self.store.ingest(sample)
                    self.networks.ingest(store: self.store, network: self.network.currentNetwork, now: self.store.now)
                    self.menuBarFeed.update(from: self.store)
                }
            },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.store.streamError = status }
            })
        stream.start()
        self.stream = stream
        journal.start(store: store)
        widget.start(model: self)
        updateActivity()

        let saveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        saveTimer.tolerance = 30
        self.saveTimer = saveTimer
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stream?.stop()
                self?.save()
            }
        }
    }

    #if DEBUG
    /// Screenshot mode: the databases on disk, made-up traffic, a fixed home and network, no helper.
    private func startDemo() {
        geo.start()
        trackers.start()
        home.showDemo()
        network.showDemo()
        journal.start(store: store)
        updateActivity()
        let feed = DemoFeed(model: self)
        demoFeed = feed
        feed.start()
    }
    #endif

    func save() {
        HistoryStore.save(store.snapshot())
        journal.save()
        networks.save()
    }

    // MARK: - What is on screen

    /// The main window opened or closed. Closed, its views are torn down and Orbite only measures.
    func setWindowOpen(_ open: Bool) {
        let closing = ui.windowOpen && !open
        if ui.windowOpen != open { ui.windowOpen = open }
        updateActivity()
        if closing {
            journal.markSeen()
            // Once SwiftUI has dropped the map, hand its freed pages back instead of waiting for memory pressure.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard self?.ui.windowOpen == false else { return }
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        updateActivity()
    }

    /// Work that only feeds what is on screen runs only while someone can see it.
    private func updateActivity() {
        guard started else { return }
        network.setActive(ui.windowOpen || panelOpen)
        store.setRowsLive(ui.windowOpen)
        menuBarFeed.setEverySecond(ui.windowOpen, store: store)
    }

    // MARK: - Replay

    /// Cuts the last 24 hours into slots off the main thread, then plays them.
    func startReplay() {
        let now = store.now
        let global = store.global.buckets.minutes
        let sites = store.sites.mapValues(\.stats.buckets.minutes)
        Task {
            let timeline = await Task.detached(priority: .userInitiated) {
                ReplayTimeline.build(now: now, global: global, sites: sites)
            }.value
            replay?.stop()
            let controller = ReplayController(timeline: timeline)
            withAnimation(.smooth(duration: 0.35)) { replay = controller }
            controller.play()
        }
    }

    func stopReplay() {
        replay?.stop()
        withAnimation(.smooth(duration: 0.35)) { replay = nil }
    }

    func clearHistory() {
        store.clearHistory()
        HistoryStore.erase()
        journal.erase()
        networks.erase()
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: ViewState.onboardingKey)
        ui.showOnboarding = false
    }
}

/// What the window shows: selection, filters, map look.
@Observable
final class ViewState {
    static let onboardingKey = "onboardingDone"

    var selection: Selection?
    var expanded: Set<String> = []
    /// Apps whose full host list is open (« N de plus… »).
    var showAll: Set<String> = []
    var search = ""
    var filter: AppFilter = .all
    var sort: AppSort = .traffic
    var showInspector = true
    var showOnboarding = false
    var showJournal = false
    var showDiagnosis = false
    var showPalette = false
    var showExport = false
    var showRecap = false
    /// The main window's width, for what must stay centred on the window rather than on the map.
    var windowWidth: CGFloat = 0
    /// The main window is open. SwiftUI keeps a closed window alive: RootView empties it.
    var windowOpen = true
    /// Incremented to ask the map to frame every place again.
    var recenterRequest = 0

    var mapLook: MapLook {
        get { access(keyPath: \.mapLook); return MapLook(rawValue: UserDefaults.standard.string(forKey: "mapLook") ?? "") ?? .standard }
        set { withMutation(keyPath: \.mapLook) { UserDefaults.standard.set(newValue.rawValue, forKey: "mapLook") } }
    }

    var showFlows: Bool {
        get { access(keyPath: \.showFlows); return UserDefaults.standard.object(forKey: "showFlows") as? Bool ?? true }
        set { withMutation(keyPath: \.showFlows) { UserDefaults.standard.set(newValue, forKey: "showFlows") } }
    }

    /// The globe lit by the real sun (day, dusk, night); off, it keeps the Plan's colours everywhere.
    var globeDayNight: Bool {
        get { access(keyPath: \.globeDayNight); return UserDefaults.standard.bool(forKey: "globeDayNight") }
        set { withMutation(keyPath: \.globeDayNight) { UserDefaults.standard.set(newValue, forKey: "globeDayNight") } }
    }

    static let menuBarKey = "menuBarEnabled"

    /// Orbite in the menu bar; when on, closing the window keeps the app measuring in the background.
    var menuBarEnabled: Bool {
        get { access(keyPath: \.menuBarEnabled); return UserDefaults.standard.bool(forKey: Self.menuBarKey) }
        set { withMutation(keyPath: \.menuBarEnabled) { UserDefaults.standard.set(newValue, forKey: Self.menuBarKey) } }
    }

    var menuBarStyle: MenuBarStyle {
        get {
            access(keyPath: \.menuBarStyle)
            return MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarStyle") ?? "") ?? .graphAndRates
        }
        set { withMutation(keyPath: \.menuBarStyle) { UserDefaults.standard.set(newValue.rawValue, forKey: "menuBarStyle") } }
    }

    /// The item exists but macOS left it out of the menu bar (no room next to the notch).
    var menuBarItemHidden = false

    /// Scene actions captured from the window: the menu bar panel lives outside the SwiftUI scenes.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var openSettingsWindow: (() -> Void)?
}

/// What the menu bar item shows.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, rates, graph, graphAndRates
    var id: Self { self }

    var label: String {
        switch self {
        case .icon: String(localized: "Icon only")
        case .rates: String(localized: "Rates")
        case .graph: String(localized: "Mini graph")
        case .graphAndRates: String(localized: "Graph + rates")
        }
    }

    /// Fixed width: an item that changes size every second makes the whole menu bar jump.
    var width: CGFloat {
        switch self {
        case .icon: 24
        case .rates: 62
        case .graph: 40
        case .graphAndRates: 100
        }
    }
}

enum MapLook: String, CaseIterable, Identifiable {
    case standard, globe, muted, satellite, hybrid
    var id: Self { self }

    var label: String {
        switch self {
        case .standard: String(localized: "Standard")
        case .globe: String(localized: "Globe")
        case .muted: String(localized: "Muted")
        case .satellite: String(localized: "Satellite")
        case .hybrid: String(localized: "Hybrid")
        }
    }

    var symbol: String {
        switch self {
        case .standard: "map"
        case .globe: "globe.americas"
        case .muted: "map.fill"
        case .satellite: "globe.europe.africa.fill"
        case .hybrid: "square.3.layers.3d"
        }
    }
}
