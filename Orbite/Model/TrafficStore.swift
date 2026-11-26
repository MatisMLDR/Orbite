import CoreLocation
import Foundation
import Observation

/// Turns nettop samples into apps, hosts, processes and places, with rates, window totals and history.
@Observable
final class TrafficStore {
    private(set) var apps: [String: AppActivity] = [:]
    private(set) var sites: [String: SiteActivity] = [:]

    var window = TimeWindow() {
        didSet { if window != oldValue { refreshWindow() } }
    }

    // Aggregates for the current window.
    private(set) var totalWindow = Traffic.zero
    private(set) var totalRate = Rate.zero
    private(set) var activeConnections = 0
    private(set) var countryCount = 0
    /// Incremented once per sample: views computing derived data depend on it.
    private(set) var tick = 0
    private(set) var lastSampleDate: Date?
    var streamError: String?

    @ObservationIgnored let resolver: AppResolver
    @ObservationIgnored let names: HostnameResolver
    @ObservationIgnored var geo: GeoDatabase? {
        didSet { endpoints.removeAll() }
    }
    @ObservationIgnored var trackers: TrackerList? {
        didSet { trackerCache.removeAll(); reclassifyHosts() }
    }
    /// Share of the last minute's flow bytes that went through a VPN tunnel, and its interface.
    private(set) var tunnelShare: Double?
    private(set) var tunnelInterface: String?

    @ObservationIgnored private(set) var global = ActivityStats()
    @ObservationIgnored private var endpoints: [String: Endpoint] = [:]
    @ObservationIgnored private var previousFlows: [String: Traffic] = [:]
    @ObservationIgnored private var previousProcesses: [String: Traffic] = [:]
    @ObservationIgnored private var previousRetransmits: [String: UInt64] = [:]
    /// Counters per local socket (pid, transport, local address), to follow a socket whose remote changes.
    @ObservationIgnored private var previousSockets: [String: Traffic] = [:]
    @ObservationIgnored private var baseline = true
    /// Entities with connections in the previous sample (their count must go back to 0).
    @ObservationIgnored private var connected: [any ActivityEntity] = []
    /// Live 60-second series for the overview sparkline.
    @ObservationIgnored private(set) var recentRates: [Rate] = []
    /// The sidebar is on screen: its rows' meters follow every sample.
    @ObservationIgnored private var rowsLive = true
    /// Called when an app, a host or a place for an app shows up for the first time since launch.
    @ObservationIgnored var onDiscovery: ((Discovery) -> Void)?
    /// Bytes of the last sample, per app id and in all: what the network ledger attributes.
    @ObservationIgnored private(set) var lastSampleByApp: [String: Traffic] = [:]
    @ObservationIgnored private(set) var lastSampleTotal = Traffic.zero
    @ObservationIgnored private var trackerCache: [String: TrackerInfo?] = [:]
    /// « App · host » that moved bytes unencrypted in the last sample, for the network ledger.
    @ObservationIgnored private(set) var lastSamplePlaintext: Set<String> = []
    /// Per-sample flow bytes through a tunnel and in all, for the last 60 samples.
    @ObservationIgnored private var tunnelSamples: [(tunnel: UInt64, all: UInt64, interface: String?)] = []

    init(resolver: AppResolver, names: HostnameResolver) {
        self.resolver = resolver
        self.names = names
    }

    var now: Int { Int((lastSampleDate ?? Date()).timeIntervalSince1970) }

    // MARK: - Ingestion

    func ingest(_ sample: NetTopSample) {
        let now = Int(sample.date.timeIntervalSince1970)
        var interval = 1.0
        if let last = lastSampleDate {
            let gap = sample.date.timeIntervalSince(last)
            // After a long pause (sleep, nettop restart) counters are a new baseline, not a burst.
            if gap > 6 { baseline = true }
            interval = min(max(gap, 0.25), 5)
        }

        for entity in connected { entity.connections = 0 }
        connected.removeAll(keepingCapacity: true)

        var seenFlows = Set<String>()
        var seenProcesses = Set<String>()
        var currentSockets: [String: Traffic] = [:]
        var sampleTotal = Traffic.zero
        var sampleByApp: [String: Traffic] = [:]
        var tunnelBytes: UInt64 = 0, flowBytes: UInt64 = 0
        var tunnel: String?
        var plaintextNow = Set<String>()

        for process in sample.processes {
            let resolved = resolver.resolve(pid: process.pid, name: process.name)
            let app = appActivity(resolved.app, now: now)
            let processRow = processActivity(in: app, resolved, now: now)
            add(process.pid, to: \.pids, of: processRow)

            let processKey = "\(process.pid)|\(process.name)"
            seenProcesses.insert(processKey)
            let processDelta = delta(processKey, Traffic(bytesIn: process.bytesIn, bytesOut: process.bytesOut), &previousProcesses)

            for flow in process.flows {
                let remoteAddress = flow.remote.isWildcard ? "*" : (IPAddress.normalize(flow.remote.address) ?? flow.remote.address)
                let key = "\(process.pid)|\(flow.transport.rawValue)|\(flow.local.address).\(flow.local.port ?? 0)|\(remoteAddress).\(flow.remote.port ?? 0)"
                seenFlows.insert(key)
                let counters = Traffic(bytesIn: flow.bytesIn, bytesOut: flow.bytesOut)
                // A UDP socket that connects changes key: start from its previous counters, not zero.
                let socketKey = "\(process.pid)|\(flow.transport.rawValue)|\(flow.local.address).\(flow.local.port ?? 0)"
                if previousFlows[key] == nil, let before = previousSockets[socketKey] { previousFlows[key] = before }
                currentSockets[socketKey] = counters
                let flowDelta = delta(key, counters, &previousFlows)
                flowBytes += flowDelta.total
                if SpecialHosts.isTunnel(flow.interface), !flowDelta.isZero {
                    tunnelBytes += flowDelta.total
                    tunnel = flow.interface
                }

                let previousRetx = previousRetransmits[key]
                previousRetransmits[key] = flow.retransmitted
                var retxDelta: UInt64?
                if let previousRetx, flow.retransmitted >= previousRetx {
                    retxDelta = flow.retransmitted - previousRetx
                    app.retransmitted += flow.retransmitted - previousRetx
                    app.sentForRetransmission += flowDelta.bytesOut
                    app.loss.add(retransmitted: flow.retransmitted - previousRetx, sent: flowDelta.bytesOut, at: now)
                }

                if flow.remote.isWildcard { continue }
                let endpoint = endpoint(for: remoteAddress)
                if endpoint.scope == .loopback || endpoint.scope == .unspecified || endpoint.scope == .multicast { continue }

                let isConnected = flow.transport == .tcp ? flow.state == "Established" : true
                let (label, kind, hostname) = label(for: remoteAddress, endpoint: endpoint)
                let host = hostActivity(in: app, label: label, kind: kind, now: now)
                host.pending += flowDelta
                add(remoteAddress, to: \.addresses, of: host)
                if let hostname, !host.hostnames.contains(hostname) {
                    host.hostnames.insert(hostname)
                    classify(host, in: app)
                }
                if let organization = endpoint.owner?.organization, host.organization != organization {
                    host.organization = organization
                }
                if let port = flow.remote.port { add(PortUse(transport: flow.transport, port: port), to: \.ports, of: host) }
                if endpoint.scope == .internet, let port = flow.remote.port,
                   let clear = SpecialHosts.plaintext(transport: flow.transport, port: port) {
                    add(clear, to: \.plaintext, of: host)
                    if !flowDelta.isZero {
                        host.plaintextLastSeen = now
                        if !SpecialHosts.isBenignPlaintext(hostnames: host.hostnames) {
                            plaintextNow.insert("\(app.identity.name) · \(host.label)")
                        }
                    }
                }
                add(label, to: \.hostLabels, of: processRow)

                var site: SiteActivity?
                if let siteID = endpoint.siteID, let place = endpoint.place {
                    let place = siteActivity(siteID, place: place, now: now)
                    place.pending += flowDelta
                    add(remoteAddress, to: \.addresses, of: place)
                    add(label, to: \.labels, of: place)
                    add(app.id, to: \.appIDs, of: place)
                    if let organization = endpoint.organization { add(organization, to: \.organizations, of: place) }
                    if let port = flow.remote.port { add(PortUse(transport: flow.transport, port: port), to: \.ports, of: place) }
                    add(siteID, to: \.siteIDs, of: host)
                    if let retxDelta { place.loss.add(retransmitted: retxDelta, sent: flowDelta.bytesOut, at: now) }
                    if !app.siteIDs.contains(siteID) {
                        app.siteIDs.insert(siteID)
                        if let code = place.place.countryCode {
                            onDiscovery?(.country(appID: app.id, code: code, name: place.place.country))
                        }
                    }
                    site = place
                }

                if let retxDelta { host.loss.add(retransmitted: retxDelta, sent: flowDelta.bytesOut, at: now) }
                if isConnected {
                    let entities: [any ActivityEntity] = [app, host, processRow] + (site.map { [$0] } ?? [])
                    for entity in entities {
                        if entity.connections == 0 { connected.append(entity) }
                        entity.connections += 1
                        if let rtt = flow.rtt, rtt > 0 {
                            entity.rttSamples = (entity.rttSamples.sum + rtt, entity.rttSamples.count + 1)
                        }
                    }
                }
            }
            // The process total (external interfaces only) also holds sockets closed between samples.
            app.pending += processDelta
            processRow.pending += processDelta
            sampleTotal += processDelta
            if !processDelta.isZero { sampleByApp[app.id, default: .zero] += processDelta }
        }

        previousFlows = previousFlows.filter { seenFlows.contains($0.key) }
        previousRetransmits = previousRetransmits.filter { seenFlows.contains($0.key) }
        previousProcesses = previousProcesses.filter { seenProcesses.contains($0.key) }
        previousSockets = currentSockets
        baseline = false
        lastSampleDate = sample.date
        lastSampleByApp = sampleByApp
        lastSampleTotal = sampleTotal
        recordTunnel(tunnelBytes, of: flowBytes, interface: tunnel)
        lastSamplePlaintext = plaintextNow

        global.record(sampleTotal, at: now)
        let rate = Rate(sampleTotal, over: interval)
        recentRates.append(rate)
        if recentRates.count > 60 { recentRates.removeFirst(recentRates.count - 60) }
        applyAll(now: now, interval: interval)
        totalRate = rate
        tick += 1
    }

    private func recordTunnel(_ bytes: UInt64, of all: UInt64, interface: String?) {
        tunnelSamples.append((bytes, all, interface))
        if tunnelSamples.count > 60 { tunnelSamples.removeFirst(tunnelSamples.count - 60) }
        let tunnelled = tunnelSamples.reduce(0) { $0 + $1.tunnel }
        let total = tunnelSamples.reduce(0) { $0 + $1.all }
        let share: Double? = tunnelled > 0 && total > 0 ? Double(tunnelled) / Double(total) : nil
        // Rounded to the percent: the overview row should not redraw for every byte. Under 1 % is no tunnel worth naming.
        let rounded = share.map { ($0 * 100).rounded() / 100 }.flatMap { $0 > 0 ? $0 : nil }
        if rounded != tunnelShare { tunnelShare = rounded }
        let name = tunnelSamples.last(where: { $0.interface != nil })?.interface
        if name != tunnelInterface { tunnelInterface = name }
    }

    // MARK: - Trackers

    /// Looks the host's hostnames up in the tracker lists; browsers skip the in-app SDK list.
    private func classify(_ host: HostActivity, in app: AppActivity) {
        guard let trackers, !trackers.isEmpty else { return }
        let inBrowser = Browsers.contains(app.identity)
        var found: TrackerInfo?
        for hostname in host.hostnames {
            let key = "\(inBrowser ? 1 : 0)|\(hostname)"
            let info: TrackerInfo?
            if let cached = trackerCache[key] { info = cached } else {
                info = trackers.lookup(hostname, inBrowser: inBrowser)
                if trackerCache.count > 100_000 { trackerCache.removeAll(keepingCapacity: true) }
                trackerCache[key] = info
            }
            if let info { found = info; break }
        }
        if found == nil, host.kind == .domain { found = trackers.lookup(host.label, inBrowser: inBrowser) }
        if found != host.tracker { host.tracker = found }
    }

    private func reclassifyHosts() {
        for app in apps.values {
            for host in app.hosts.values { classify(host, in: app) }
        }
    }

    /// Writing an observed set notifies its views even when the element is already there: insert only what is new.
    private func add<Owner: AnyObject, Element: Hashable>(_ element: Element, to keyPath: ReferenceWritableKeyPath<Owner, Set<Element>>,
                                                         of owner: Owner) {
        if !owner[keyPath: keyPath].contains(element) { owner[keyPath: keyPath].insert(element) }
    }

    private func delta(_ key: String, _ current: Traffic, _ table: inout [String: Traffic]) -> Traffic {
        defer { table[key] = current }
        guard let previous = table[key] else { return baseline ? .zero : current }
        return current - previous
    }

    private func applyAll(now: Int, interval: Double) {
        for app in apps.values {
            app.apply(now: now, interval: interval, window: window)
            for host in app.hosts.values {
                host.apply(now: now, interval: interval, window: window)
                if host.connections > 0, let rtt = host.rtt { host.rttBaseline = LossWindow.baseline(host.rttBaseline, sample: rtt) }
            }
            for process in app.processes.values { process.apply(now: now, interval: interval, window: window) }
        }
        for site in sites.values {
            site.apply(now: now, interval: interval, window: window)
            if site.connections > 0, let rtt = site.rtt { site.rttBaseline = LossWindow.baseline(site.rttBaseline, sample: rtt) }
        }
        if rowsLive { refreshMeters(now: now) }
        refreshAggregates(now: now)
    }

    /// The sidebar's row meters, rebuilt from each entity's last seconds.
    private func refreshMeters(now: Int) {
        for app in apps.values {
            let meter = app.stats.meter(now: now)
            if meter != app.meter { app.meter = meter }
            for host in app.hosts.values {
                let hostMeter = host.stats.meter(now: now)
                if hostMeter != host.meter { host.meter = hostMeter }
            }
            for process in app.processes.values {
                let processMeter = process.stats.meter(now: now)
                if processMeter != process.meter { process.meter = processMeter }
            }
        }
    }

    /// Window closed: row meters stop; they catch up as soon as the window opens again.
    func setRowsLive(_ live: Bool) {
        guard live != rowsLive else { return }
        rowsLive = live
        if live { refreshMeters(now: now) }
    }

    private func refreshAggregates(now: Int) {
        let total = global.total(in: window, now: now, lastSeen: now)
        if total != totalWindow { totalWindow = total }
        let connections = apps.values.reduce(0) { $0 + $1.connections }
        if connections != activeConnections { activeConnections = connections }
        let countries = Set(visibleSites.compactMap(\.place.countryCode)).count
        if countries != countryCount { countryCount = countries }
    }

    /// Recomputes every total for a new window (span change or navigation in time).
    private func refreshWindow() {
        let now = self.now
        for app in apps.values {
            app.window = app.stats.total(in: window, now: now, lastSeen: app.lastSeen)
            for host in app.hosts.values { host.window = host.stats.total(in: window, now: now, lastSeen: host.lastSeen) }
            for process in app.processes.values {
                process.window = process.stats.total(in: window, now: now, lastSeen: process.lastSeen)
            }
        }
        for site in sites.values { site.window = site.stats.total(in: window, now: now, lastSeen: site.lastSeen) }
        refreshAggregates(now: now)
        tick += 1
    }

    // MARK: - Entities

    private func appActivity(_ identity: AppIdentity, now: Int) -> AppActivity {
        if let existing = apps[identity.id] {
            if existing.identity != identity && identity.kind != .system { existing.identity = identity }
            return existing
        }
        let app = AppActivity(identity: identity, lastSeen: now)
        apps[identity.id] = app
        onDiscovery?(.app(identity))
        return app
    }

    private func processActivity(in app: AppActivity, _ resolved: ResolvedProcess, now: Int) -> ProcessActivity {
        if let existing = app.processes[resolved.processName] {
            if existing.path.isEmpty, !resolved.path.isEmpty { existing.path = resolved.path }
            return existing
        }
        let process = ProcessActivity(appID: app.id, name: resolved.processName, path: resolved.path, lastSeen: now)
        app.processes[resolved.processName] = process
        return process
    }

    private func hostActivity(in app: AppActivity, label: String, kind: HostLabelKind, now: Int) -> HostActivity {
        if let existing = app.hosts[label] { return existing }
        let host = HostActivity(appID: app.id, label: label, kind: kind, lastSeen: now)
        app.hosts[label] = host
        onDiscovery?(.host(appID: app.id, label: label, kind: kind))
        return host
    }

    private func siteActivity(_ id: String, place: GeoPlace, now: Int) -> SiteActivity {
        if let existing = sites[id] { return existing }
        let site = SiteActivity(id: id, place: place, lastSeen: now)
        sites[id] = site
        return site
    }

    func endpoint(for address: String) -> Endpoint {
        if let cached = endpoints[address] { return cached }
        let scope = IPAddress.scope(address)
        var endpoint = Endpoint(scope: scope)
        if scope == .internet, let geo {
            endpoint.place = geo.place(for: address)
            endpoint.owner = geo.owner(for: address)
            endpoint.organization = endpoint.owner?.organization.map(HostLabel.cleanOrganization)
            endpoint.siteID = endpoint.place.map(SiteActivity.identifier)
        }
        if endpoints.count > 50_000 { endpoints.removeAll(keepingCapacity: true) }
        endpoints[address] = endpoint
        return endpoint
    }

    /// Domain from DNS when the helper saw it, else the network's owner, else the address.
    private func label(for address: String, endpoint: Endpoint) -> (String, HostLabelKind, String?) {
        let hostname = names.hostname(for: address)
        if endpoint.scope != .internet {
            return (String(localized: "Local network"), .local, hostname)
        }
        if let hostname {
            // Relay and resolver traffic stays apart from the provider's own services.
            if let service = SpecialHosts.service(of: hostname) {
                return (SpecialHosts.label(for: service), .domain, hostname)
            }
            return (HostLabel.registrableDomain(hostname), .domain, hostname)
        }
        if let organization = endpoint.organization {
            return (organization, .organization, nil)
        }
        return (address, .address, nil)
    }

    // MARK: - Queries for views

    var visibleSites: [SiteActivity] {
        sites.values.filter { $0.isVisible(in: window) }
    }

    func sortedApps(filter: AppFilter, sort: AppSort, search: String) -> [AppActivity] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = apps.values.filter { app in
            guard app.isVisible(in: window) else { return false }
            switch filter {
            case .all: break
            case .apps: if app.identity.kind != .app { return false }
            case .system: if app.identity.kind != .system { return false }
            case .tools: if app.identity.kind != .tool { return false }
            }
            guard !query.isEmpty else { return true }
            if app.identity.name.lowercased().contains(query) { return true }
            return app.hosts.values.contains { host in
                host.isVisible(in: window) && (host.label.lowercased().contains(query)
                    || host.hostnames.contains { $0.contains(query) }
                    || host.addresses.contains { $0.hasPrefix(query) })
            }
        }
        return list.sorted { lhs, rhs in
            switch sort {
            case .traffic:
                if lhs.window.total != rhs.window.total { return lhs.window.total > rhs.window.total }
            case .recent:
                if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
            case .upload:
                if lhs.window.bytesOut != rhs.window.bytesOut { return lhs.window.bytesOut > rhs.window.bytesOut }
            case .name:
                break
            }
            return lhs.identity.name.localizedCaseInsensitiveCompare(rhs.identity.name) == .orderedAscending
        }
    }

    func sortedHosts(of app: AppActivity, search: String) -> [HostActivity] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return app.hosts.values
            .filter { $0.isVisible(in: window) }
            .filter { query.isEmpty || app.identity.name.lowercased().contains(query) || $0.label.lowercased().contains(query)
                || $0.hostnames.contains { $0.contains(query) } }
            .sorted { ($0.window.total, $1.label) > ($1.window.total, $0.label) }
    }

    func sortedProcesses(of app: AppActivity) -> [ProcessActivity] {
        app.processes.values
            .filter { $0.isVisible(in: window) }
            .sorted { ($0.window.total, $1.name) > ($1.window.total, $0.name) }
    }

    /// Apps sending or receiving right now, busiest first, whatever window the main view shows.
    func liveApps(limit: Int) -> [AppActivity] {
        Array(apps.values.filter(\.rate.isActive)
            .sorted { ($0.rate.total, $1.identity.name) > ($1.rate.total, $0.identity.name) }
            .prefix(limit))
    }

    /// Everything sent and received since `start` (epoch second), from the global buckets.
    func total(from start: Int) -> Traffic {
        global.buckets.sum(from: start, to: now + 1, now: now)
    }

    func host(id: String) -> HostActivity? {
        guard let appID = id.split(separator: "|", maxSplits: 1).first else { return nil }
        let label = String(id.dropFirst(appID.count + 1))
        return apps[String(appID)]?.hosts[label]
    }

    func process(id: String) -> ProcessActivity? {
        guard let appID = id.split(separator: "|", maxSplits: 1).first else { return nil }
        let name = String(id.dropFirst(appID.count + 1))
        return apps[String(appID)]?.processes[name]
    }

    func histogram(for selection: Selection?) -> [Traffic] {
        let now = self.now
        switch selection {
        case .app(let id): return apps[id]?.stats.histogram(for: window, now: now) ?? global.histogram(for: window, now: now)
        case .host(let id): return host(id: id)?.stats.histogram(for: window, now: now) ?? []
        case .process(let id): return process(id: id)?.stats.histogram(for: window, now: now) ?? []
        case .site(let id): return sites[id]?.stats.histogram(for: window, now: now) ?? []
        case .network: return []
        case nil: return global.histogram(for: window, now: now)
        }
    }

    func windowTotal(for selection: Selection?) -> Traffic {
        switch selection {
        case .app(let id): apps[id]?.window ?? .zero
        case .host(let id): host(id: id)?.window ?? .zero
        case .process(let id): process(id: id)?.window ?? .zero
        case .site(let id): sites[id]?.window ?? .zero
        case .network: .zero
        case nil: totalWindow
        }
    }

    /// Sites touched by the selection, for highlighting lines on the map.
    func siteIDs(for selection: Selection?) -> Set<String>? {
        switch selection {
        case .app(let id): return apps[id]?.siteIDs
        case .host(let id): return host(id: id)?.siteIDs
        case .process(let id):
            guard let process = process(id: id), let app = apps[process.appID] else { return nil }
            return Set(process.hostLabels.compactMap { app.hosts[$0] }.flatMap(\.siteIDs))
        case .site(let id): return [id]
        case .network, nil: return nil
        }
    }

    // MARK: - Restoring history

    func restore(_ snapshot: HistorySnapshot) {
        global.buckets = snapshot.global
        for record in snapshot.apps {
            let app = AppActivity(identity: record.identity, lastSeen: record.lastSeen)
            app.stats.buckets = record.buckets
            app.siteIDs = Set(record.siteIDs)
            for hostRecord in record.hosts {
                let host = HostActivity(appID: app.id, label: hostRecord.label, kind: hostRecord.kind, lastSeen: hostRecord.lastSeen)
                host.stats.buckets = hostRecord.buckets
                host.hostnames = Set(hostRecord.hostnames)
                host.addresses = Set(hostRecord.addresses)
                host.ports = Set(hostRecord.ports)
                host.siteIDs = Set(hostRecord.siteIDs)
                host.organization = hostRecord.organization
                host.plaintext = Set(hostRecord.plaintext ?? [])
                host.plaintextLastSeen = hostRecord.plaintextLastSeen
                host.rttBaseline = hostRecord.rttBaseline
                app.hosts[host.label] = host
            }
            for processRecord in record.processes {
                let process = ProcessActivity(appID: app.id, name: processRecord.name, path: processRecord.path,
                                              lastSeen: processRecord.lastSeen)
                process.stats.buckets = processRecord.buckets
                process.hostLabels = Set(processRecord.hostLabels)
                app.processes[process.name] = process
            }
            apps[app.id] = app
        }
        reclassifyHosts()
        for record in snapshot.sites {
            let site = SiteActivity(id: record.id, place: record.place, lastSeen: record.lastSeen)
            site.stats.buckets = record.buckets
            site.addresses = Set(record.addresses)
            site.labels = Set(record.labels)
            site.organizations = Set(record.organizations)
            site.appIDs = Set(record.appIDs)
            site.ports = Set(record.ports)
            site.rttBaseline = record.rttBaseline
            sites[site.id] = site
        }
        refreshWindow()
    }

    func snapshot() -> HistorySnapshot {
        let now = self.now
        global.buckets.prune(now: now)
        func keep(_ lastSeen: Int, _ buckets: TrafficBuckets) -> Bool {
            !buckets.isEmpty && lastSeen >= now - TrafficBuckets.hourHorizon
        }
        var appRecords: [AppRecord] = []
        for app in apps.values {
            app.stats.buckets.prune(now: now)
            guard keep(app.lastSeen, app.stats.buckets) else { continue }
            let hosts = app.hosts.values.compactMap { host -> HostRecord? in
                host.stats.buckets.prune(now: now)
                guard keep(host.lastSeen, host.stats.buckets) else { return nil }
                return HostRecord(label: host.label, kind: host.kind, hostnames: Array(host.hostnames.prefix(40)),
                                  addresses: Array(host.addresses.prefix(40)), ports: Array(host.ports.prefix(20)),
                                  siteIDs: Array(host.siteIDs.prefix(40)), organization: host.organization,
                                  lastSeen: host.lastSeen, buckets: host.stats.buckets,
                                  plaintext: host.plaintext.isEmpty ? nil : host.plaintext.sorted(),
                                  plaintextLastSeen: host.plaintextLastSeen, rttBaseline: host.rttBaseline)
            }
            let processes = app.processes.values.compactMap { process -> ProcessRecord? in
                process.stats.buckets.prune(now: now)
                guard keep(process.lastSeen, process.stats.buckets) else { return nil }
                return ProcessRecord(name: process.name, path: process.path, hostLabels: Array(process.hostLabels.prefix(40)),
                                     lastSeen: process.lastSeen, buckets: process.stats.buckets)
            }
            appRecords.append(AppRecord(identity: app.identity, lastSeen: app.lastSeen, buckets: app.stats.buckets,
                                        siteIDs: Array(app.siteIDs), hosts: hosts, processes: processes))
        }
        let siteRecords = sites.values.compactMap { site -> SiteRecord? in
            site.stats.buckets.prune(now: now)
            guard keep(site.lastSeen, site.stats.buckets) else { return nil }
            return SiteRecord(id: site.id, place: site.place, addresses: Array(site.addresses.prefix(60)),
                              labels: Array(site.labels.prefix(60)), organizations: Array(site.organizations.prefix(20)),
                              appIDs: Array(site.appIDs.prefix(60)), ports: Array(site.ports.prefix(20)),
                              lastSeen: site.lastSeen, buckets: site.stats.buckets, rttBaseline: site.rttBaseline)
        }
        return HistorySnapshot(savedAt: Date(), global: global.buckets, apps: appRecords, sites: siteRecords)
    }

    /// Forgets everything (Réglages › Données).
    func clearHistory() {
        apps.removeAll()
        sites.removeAll()
        global = ActivityStats()
        connected.removeAll()
        recentRates.removeAll()
        refreshWindow()
    }
}

enum AppFilter: String, CaseIterable, Identifiable {
    case all, apps, system, tools
    var id: Self { self }
    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .apps: String(localized: "Apps")
        case .system: "macOS"
        case .tools: String(localized: "Tools")
        }
    }
}

enum AppSort: String, CaseIterable, Identifiable {
    case traffic, upload, recent, name
    var id: Self { self }
    var label: String {
        switch self {
        case .traffic: String(localized: "Volume")
        case .upload: String(localized: "Upload")
        case .recent: String(localized: "Recent activity")
        case .name: String(localized: "Name")
        }
    }
}

/// Something the store met for the first time since launch; the journal decides whether it is new for good.
enum Discovery {
    case app(AppIdentity)
    case host(appID: String, label: String, kind: HostLabelKind)
    case country(appID: String, code: String, name: String?)
}

enum Selection: Hashable {
    case app(String)
    case host(String)
    case process(String)
    case site(String)
    case network(String)
}
