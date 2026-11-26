import SwiftUI

/// ⌘K: finds any app, domain, place, country, tracker or network of the history, whatever the window
/// shows, and runs Orbite's actions.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var items: [SearchItem] = []
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = SearchIndex.rank(query, in: items, limit: 12)
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("App, domain, city, country, tracker, action…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .focused($focused)
                        .onSubmit { choose(results[safe: highlighted]) }
                        .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                        .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onChange(of: query) { highlighted = 0 }
                }
                .padding(.horizontal, 18)
                .frame(height: 54)

                if !results.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                    PaletteRow(item: item, highlighted: index == highlighted, now: model.store.now)
                                        .id(index)
                                        .onTapGesture { choose(item) }
                                        .onHover { if $0 { highlighted = index } }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 420)
                        .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
                    }
                } else if !query.isEmpty {
                    Divider()
                    Text("Nothing found in the history")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                }
            }
            .frame(width: 600)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .padding(.top, 90)
        }
        .onAppear {
            items = SearchCatalog.items(model: model)
            focused = true
        }
    }

    private func move(_ step: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = (highlighted + step + count) % count
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { model.ui.showPalette = false }
    }

    private func choose(_ item: SearchItem?) {
        guard let item else { return }
        close()
        SearchCatalog.perform(item.payload, model: model)
    }
}

private struct PaletteRow: View {
    @Environment(AppModel.self) private var model
    let item: SearchItem
    let highlighted: Bool
    let now: Int

    var body: some View {
        HStack(spacing: 11) {
            icon
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.kind != .action {
                VStack(alignment: .trailing, spacing: 1) {
                    if item.weight > 0 {
                        Text(Format.bytes(item.weight))
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                    }
                    if let lastSeen = item.lastSeen {
                        Text(Format.ago(Date(timeIntervalSince1970: TimeInterval(lastSeen)),
                                        now: Date(timeIntervalSince1970: TimeInterval(now))))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(item.kind.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        let parts = item.payload.split(separator: "|", maxSplits: 1).map(String.init)
        if item.kind == .app, parts.count == 2, let app = model.store.apps[parts[1]] {
            AppIconView(identity: app.identity, size: 24)
        } else if item.kind == .country || item.kind == .place, let flag = item.keywords.last, flag.unicodeScalars.count == 2 {
            Text(flag).font(.system(size: 19))
        } else {
            SymbolIcon(symbol: Self.symbol(item), size: 24, colors: [Color.secondary.opacity(0.7), .secondary])
        }
    }

    static func symbol(_ item: SearchItem) -> String {
        switch item.kind {
        case .action: item.keywords.first ?? "command"
        case .app: "app"
        case .domain: "globe"
        case .organization: "building.2"
        case .place: "mappin"
        case .country: "flag"
        case .tracker: "eye.trianglebadge.exclamationmark"
        case .network: "wifi"
        }
    }
}

/// Builds the palette's items from everything Orbite keeps, and carries out a choice.
enum SearchCatalog {
    static func items(model: AppModel) -> [SearchItem] {
        let store = model.store
        let now = store.now
        let weekStart = now - 7 * 86_400
        func week(_ stats: ActivityStats) -> Double { Double(stats.buckets.sum(from: weekStart, to: now + 1, now: now).total) }
        var items = actions()

        var domains: [String: (host: HostActivity, apps: Set<String>, weight: Double, hostnames: Set<String>)] = [:]
        /// Per name: the busiest host (opened on choice), its own weight, the total weight, how many hosts.
        typealias Best = (host: HostActivity, best: Double, weight: Double, count: Int)
        func merge(_ entry: Best?, _ host: HostActivity, _ weight: Double) -> Best {
            guard let entry else { return (host, weight, weight, 1) }
            let better = weight > entry.best
            return (better ? host : entry.host, better ? weight : entry.best, entry.weight + weight, entry.count + 1)
        }
        var organizations: [String: Best] = [:]
        var owners: [String: Best] = [:]
        for app in store.apps.values {
            items.append(SearchItem(id: "app|\(app.id)", kind: .app, title: app.identity.name, subtitle: app.identity.kind.label,
                                    weight: week(app.stats), lastSeen: app.lastSeen, payload: "app|\(app.id)"))
            for host in app.hosts.values {
                let weight = week(host.stats)
                switch host.kind {
                case .domain:
                    var entry = domains[host.label] ?? (host, [], 0, [])
                    if weight > entry.weight || entry.weight == 0 { entry.host = host }
                    entry.apps.insert(app.identity.name)
                    entry.weight += weight
                    entry.hostnames.formUnion(host.hostnames.prefix(8))
                    domains[host.label] = entry
                case .organization:
                    organizations[host.label] = merge(organizations[host.label], host, weight)
                default:
                    break
                }
                if let tracker = host.tracker { owners[tracker.owner] = merge(owners[tracker.owner], host, weight) }
            }
        }
        for (label, entry) in domains {
            items.append(SearchItem(id: "domain|\(label)", kind: .domain, title: label,
                                    subtitle: entry.apps.sorted().prefix(3).joined(separator: ", "),
                                    keywords: Array(entry.hostnames), weight: entry.weight, lastSeen: entry.host.lastSeen,
                                    payload: "host|\(entry.host.id)"))
        }
        for (label, entry) in organizations {
            items.append(SearchItem(id: "org|\(label)", kind: .organization, title: label,
                                    subtitle: store.apps[entry.host.appID]?.identity.name, weight: entry.weight,
                                    lastSeen: entry.host.lastSeen, payload: "host|\(entry.host.id)"))
        }
        for (owner, entry) in owners {
            items.append(SearchItem(id: "tracker|\(owner)", kind: .tracker, title: owner,
                                    subtitle: "\(entry.host.tracker?.category.label ?? String(localized: "Tracking")) · \(Format.plural(entry.count, "domain", "domains"))",
                                    weight: entry.weight, payload: "host|\(entry.host.id)"))
        }

        var countries: [String: (name: String, site: SiteActivity, best: Double, weight: Double)] = [:]
        for site in store.sites.values {
            let weight = week(site.stats)
            let flag = Format.flag(site.place.countryCode)
            items.append(SearchItem(id: "site|\(site.id)", kind: .place, title: site.title,
                                    subtitle: [site.place.region, site.place.country].compactMap { $0 }.joined(separator: ", "),
                                    keywords: Array(site.organizations.prefix(4)) + [site.place.country ?? "", flag],
                                    weight: weight, lastSeen: site.lastSeen, payload: "site|\(site.id)"))
            if let code = site.place.countryCode {
                if let entry = countries[code] {
                    let better = weight > entry.best
                    countries[code] = (entry.name, better ? site : entry.site, better ? weight : entry.best, entry.weight + weight)
                } else {
                    countries[code] = (site.place.country ?? code, site, weight, weight)
                }
            }
        }
        for (code, entry) in countries {
            items.append(SearchItem(id: "country|\(code)", kind: .country, title: entry.name, subtitle: String(localized: "Country"),
                                    keywords: [code, Format.flag(code)], weight: entry.weight, payload: "site|\(entry.site.id)"))
        }
        for network in model.networks.networks {
            items.append(SearchItem(id: "network|\(network.id)", kind: .network, title: network.name,
                                    subtitle: NetworkInspector.kind(network),
                                    weight: Double(network.buckets.sum(from: weekStart, to: now + 1, now: now).total),
                                    lastSeen: network.lastSeen, payload: "network|\(network.id)"))
        }
        return items
    }

    private static func actions() -> [SearchItem] {
        func action(_ name: String, _ title: LocalizedStringResource, _ symbol: String, _ keywords: [String] = []) -> SearchItem {
            SearchItem(id: "action|\(name)", kind: .action, title: String(localized: title), keywords: [symbol] + keywords, payload: "action|\(name)")
        }
        return [
            action("replay", "Replay the Day", "play.circle", ["replay", "animation", "rejouer"]),
            action("diagnosis", "Why Is It Slow?", "stethoscope", ["diagnosis", "slow", "diagnostic", "lent", "lenteur"]),
            action("recap", "Weekly Recap", "chart.bar", ["summary", "wrapped", "bilan", "résumé"]),
            action("journal", "Journal of First Times", "book.pages", ["new", "nouveautés"]),
            action("export", "Export…", "square.and.arrow.up", ["csv", "json"]),
            action("live", "Back to Live", "dot.radiowaves.left.and.right"),
            action("span.fiveMinutes", "Period: Last 5 Minutes", "clock"),
            action("span.hour", "Period: Last Hour", "clock"),
            action("span.day", "Period: Last 24 Hours", "clock"),
            action("span.week", "Period: Last 7 Days", "calendar"),
            action("recenter", "Recenter the Map", "scope"),
        ]
    }

    static func perform(_ payload: String, model: AppModel) {
        let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let store = model.store
        let ui = model.ui
        let selection: Selection?
        switch parts[0] {
        case "app": selection = .app(parts[1])
        case "host": selection = .host(parts[1])
        case "site": selection = .site(parts[1])
        case "network": selection = .network(parts[1])
        case "action":
            run(parts[1], model: model)
            return
        default: selection = nil
        }
        guard let selection else { return }
        // Found in the history but quiet in this window: widen to the week so it shows everywhere.
        let visible: Bool = switch selection {
        case .app(let id): store.apps[id]?.isVisible(in: store.window) ?? false
        case .host(let id): store.host(id: id)?.isVisible(in: store.window) ?? false
        case .site(let id): store.sites[id]?.isVisible(in: store.window) ?? false
        default: true
        }
        if !visible { store.window = TimeWindow(span: .week, end: nil) }
        withAnimation(Theme.selection) {
            ui.selection = selection
            ui.showInspector = true
            if case .host(let id) = selection, let appID = id.split(separator: "|", maxSplits: 1).first {
                ui.expanded.insert(String(appID))
            }
        }
    }

    static func run(_ action: String, model: AppModel) {
        let ui = model.ui
        let store = model.store
        switch action {
        case "replay": model.startReplay()
        case "diagnosis": ui.showDiagnosis = true
        case "recap": withAnimation(.smooth(duration: 0.4)) { ui.showRecap = true }
        case "journal": ui.showJournal = true
        case "export": ui.showExport = true
        case "live": store.window = TimeWindow(span: store.window.span, end: nil)
        case "recenter": ui.recenterRequest += 1
        default:
            if action.hasPrefix("span."), let span = WindowSpan(rawValue: String(action.dropFirst(5))) {
                store.window = TimeWindow(span: span, end: nil)
            }
        }
    }
}
