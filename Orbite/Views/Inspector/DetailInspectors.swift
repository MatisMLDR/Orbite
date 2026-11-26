import SwiftUI

// MARK: - Host (a domain or an organization under an app)

struct HostInspector: View {
    @Environment(AppModel.self) private var model
    let host: HostActivity

    var body: some View {
        let store = model.store
        let app = store.apps[host.appID]
        let kindText: String = switch host.kind {
        case .domain: String(localized: "Domain seen in DNS")
        case .organization: String(localized: "Organization's network (domain name unknown)")
        case .address: String(localized: "Address with no known name")
        case .local: String(localized: "Local network devices")
        }

        InspectorHeader(title: host.label, subtitle: [app.map { String(localized: "in \($0.identity.name)") }, kindText].compactMap { $0 }.joined(separator: " · ")) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.download.gradient)
                Image(systemName: HostRow.symbol(host.kind))
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: Theme.download.opacity(0.35), radius: 6, y: 2)
        }
        TotalsBlock(window: host.window, rate: host.rate, live: store.window.isLive)

        ThroughputSection(selection: .host(host.id), window: host.window)

        InspectorSection("Network") {
            InfoGrid {
                if let organization = host.organization {
                    InfoRow("Organization", HostLabel.cleanOrganization(organization))
                }
                InfoRow("IP addresses") {
                    AddressList(addresses: host.addresses.sorted { IPSort.less($0, $1) })
                }
                if host.kind == .domain, let first = model.journal.firstSeen(appID: host.appID, domain: host.label) {
                    InfoRow("First contact", model.journal.firstSeenText(first))
                }
            }
        }

        HostPrivacySection(host: host)

        ConnectionDetails(hosts: [host], connections: host.connections, rtt: host.rtt, live: store.window.isLive)

        DestinationsSection(siteIDs: host.siteIDs)

        if host.kind == .organization, !model.helper.isEnabled {
            HelperHint()
        }
    }
}

/// IP addresses with their reverse DNS name underneath, looked up on demand.
struct AddressList: View {
    @Environment(AppModel.self) private var model
    let addresses: [String]
    @State private var showAll = false

    var body: some View {
        let _ = model.names.revision
        let shown = showAll ? addresses : Array(addresses.prefix(4))
        VStack(alignment: .leading, spacing: 5) {
            ForEach(shown, id: \.self) { address in
                VStack(alignment: .leading, spacing: 0) {
                    Text(address)
                        .font(.system(size: 12, design: .monospaced))
                    if let reverse = model.names.reverseName(for: address), !reverse.isEmpty {
                        Text(reverse)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if addresses.count > 4 {
                Button(showAll ? "Less" : "+ \(addresses.count - 4) more") {
                    withAnimation(.snappy) { showAll.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HelperHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.download)
            VStack(alignment: .leading, spacing: 6) {
                Text("Turn on real domain names to see youtube.com instead of “Google”.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn On…") { model.helper.enable() }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Theme.sectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Process (a macOS service)

struct ProcessInspector: View {
    @Environment(AppModel.self) private var model
    let process: ProcessActivity

    var body: some View {
        let store = model.store
        let app = store.apps[process.appID]
        let signature = process.path.isEmpty ? nil : model.resolver.signature(path: process.path)
        let livePIDs = process.pids.filter { kill($0, 0) == 0 || errno == EPERM }.sorted()
        let user = livePIDs.first.flatMap(LibProc.uid(of:)).map(LibProc.userName(of:))
        let hosts = process.hostLabels.compactMap { app?.hosts[$0] }.sorted { $0.window.total > $1.window.total }

        InspectorHeader(title: process.name, subtitle: app.map { $0.identity.kind == .system ? String(localized: "macOS service") : $0.identity.name }) {
            ProcessIconView(path: process.path, size: 54)
        }
        TotalsBlock(window: process.window, rate: process.rate, live: store.window.isLive)

        ThroughputSection(selection: .process(process.id), window: process.window)

        InspectorSection("Processes") {
            InfoGrid {
                if !process.path.isEmpty { InfoRow("Path") { PathValue(path: process.path) } }
                if let signature { InfoRow("Code ID", signature.codeID) }
                if let user { InfoRow("User", user) }
                if !livePIDs.isEmpty { InfoRow("PID", livePIDs.prefix(6).map(String.init).joined(separator: ", ")) }
            }
        }

        if !hosts.isEmpty {
            ConnectionDetails(hosts: hosts, connections: process.connections, rtt: process.rtt, live: store.window.isLive)
            DestinationsSection(siteIDs: Set(hosts.flatMap(\.siteIDs)))
        }
    }
}

// MARK: - Site (a place on the map)

struct SiteInspector: View {
    @Environment(AppModel.self) private var model
    let site: SiteActivity

    var body: some View {
        let store = model.store
        let place = site.place
        let distance = GeoMath.distanceKm(model.home.coordinate, site.coordinate)
        let apps = site.appIDs.compactMap { store.apps[$0] }.sorted { $0.window.total > $1.window.total }
        let subtitle = [place.region, place.country].compactMap { $0 }.filter { $0 != place.city }.joined(separator: ", ")

        InspectorHeader(title: site.title, subtitle: subtitle.isEmpty ? nil : subtitle) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.background.secondary)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1.5)
                Text(Format.flag(place.countryCode))
                    .font(.system(size: 32))
            }
        }
        TotalsBlock(window: site.window, rate: site.rate, live: store.window.isLive)

        ThroughputSection(selection: .site(site.id), window: site.window)

        InspectorSection("Location") {
            InfoGrid {
                if let city = place.city { InfoRow("City", city) }
                if let region = place.region { InfoRow("Region", region) }
                if let country = place.country { InfoRow("Country", "\(Format.flag(place.countryCode)) \(country)") }
                InfoRow("Distance", Format.distance(kilometers: distance))
                InfoRow("Light", Format.milliseconds(distance / 299.792 * 1.5))
                    .help("Shortest one-way time through fiber over this distance")
                InfoRow("Coordinates", "\(Format.decimal(place.latitude, digits: 3)), \(Format.decimal(place.longitude, digits: 3))")
            }
        }

        InspectorSection("Network") {
            InfoGrid {
                if !site.organizations.isEmpty {
                    InfoRow("Organizations") { ValueList(values: site.organizations.sorted(), limit: 3) }
                }
                InfoRow("Domains") { ValueList(values: site.labels.sorted(), limit: 5) }
                InfoRow("IP addresses") { AddressList(addresses: site.addresses.sorted { IPSort.less($0, $1) }) }
                let ports = site.ports.sorted()
                if !ports.isEmpty {
                    InfoRow("Ports") { ValueList(values: ports.map { Format.port($0.port, transport: $0.transport) }, limit: 3) }
                }
                if store.window.isLive { InfoRow("Connections", String(localized: "\(site.connections) active")) }
                if let rtt = site.rtt { InfoRow("Latency", Format.milliseconds(rtt)) }
            }
        }

        if !apps.isEmpty {
            InspectorSection("Apps") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(apps.prefix(10)) { app in
                        Button {
                            withAnimation(Theme.selection) {
                                model.ui.selection = .app(app.id)
                                model.ui.expanded.insert(app.id)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                AppIconView(identity: app.identity, size: 20)
                                Text(app.identity.name).font(.system(size: 12.5, weight: .medium))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        AttributionFooter()
    }
}

struct AttributionFooter: View {
    var body: some View {
        Link(destination: URL(string: "https://db-ip.com")!) {
            Text("IP Geolocation by DB-IP")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }
}
