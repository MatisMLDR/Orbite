import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let _ = store.tick
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.ui.selection {
                case .app(let id):
                    if let app = store.apps[id] { AppInspector(app: app) } else { NetworkOverview() }
                case .host(let id):
                    if let host = store.host(id: id) { HostInspector(host: host) } else { NetworkOverview() }
                case .process(let id):
                    if let process = store.process(id: id) { ProcessInspector(process: process) } else { NetworkOverview() }
                case .site(let id):
                    if let site = store.sites[id] { SiteInspector(site: site) } else { NetworkOverview() }
                case .network(let id):
                    if let network = model.networks.record(id) { NetworkInspector(network: network) } else { NetworkOverview() }
                case nil:
                    NetworkOverview()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            // Scrolled to the end, the last line sits above the bottom blur, not under it.
            .padding(.bottom, Self.bottomEdge + 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Content blurs and melts into the panel at the window's top and bottom edges instead of being cut.
        .edgeBlur(top: Self.topEdge, bottom: Self.bottomEdge)
        // No toolbar item sits over the inspector and the toolbar has no background: start at the top.
        .ignoresSafeArea(.container, edges: .top)
        .animation(Theme.selection, value: model.ui.selection)
    }

    /// Clear of the header at rest (it starts 22 pt down), deep enough to soften what scrolls under the edge.
    private static let topEdge: CGFloat = 26
    private static let bottomEdge: CGFloat = Theme.edgeBlur
}

/// Icon, title and subtitle at the top of every inspector, and the ✕ that closes it.
struct InspectorHeader<Icon: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let subtitle: String?
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            icon
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 21, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .textSelection(.enabled)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button {
                // Closing ends the selection too: picking it again then opens the panel again.
                withAnimation(Theme.selection) {
                    model.ui.showInspector = false
                    model.ui.selection = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Theme.track, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close the panel")
            .alignmentGuide(VerticalAlignment.center) { $0[.top] + 27 }
        }
        .padding(.top, 8)
    }
}

/// Volume pills for the window and the live rate under them.
struct TotalsBlock: View {
    let window: Traffic
    let rate: Rate
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DirectionPill(direction: .up, value: Format.bytes(window.bytesOut), large: true)
                DirectionPill(direction: .down, value: Format.bytes(window.bytesIn), large: true)
            }
            if let ratio = UploadRatio.text(window) {
                Label(ratio, systemImage: "arrow.up.forward")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.upload)
                    .padding(.horizontal, 4)
            }
            if live {
                HStack(spacing: 6) {
                    Circle()
                        .fill(rate.isActive ? Theme.live : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(rate.isActive ? "Right now" : "Idle")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if rate.isActive { RatePair(rate: rate) }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

/// Histogram of one entity over the window, with peak and average.
struct ThroughputSection: View {
    @Environment(AppModel.self) private var model
    let selection: Selection
    let window: Traffic
    var retransmission: Double?

    var body: some View {
        let store = model.store
        let bins = store.histogram(for: selection)
        let span = store.window.span
        let binWidth = bins.count == 5 ? 60 : span.bins.width
        let peak = bins.map(\.total).max() ?? 0
        InspectorSection("Throughput") {
            VStack(alignment: .leading, spacing: 12) {
                MirrorHistogram(bins: bins, binWidth: binWidth, end: store.window.histogramEnd(now: store.now))
                    .frame(height: 64)
                InfoGrid {
                    InfoRow("Peak", Format.rate(Double(peak) / Double(binWidth)))
                    InfoRow("Average", Format.rate(Double(window.total) / Double(span.seconds)))
                    if let retransmission {
                        InfoRow("Retransmitted", Format.percent(retransmission))
                    }
                }
            }
        }
    }
}

// MARK: - App

struct AppInspector: View {
    @Environment(AppModel.self) private var model
    let app: AppActivity

    var body: some View {
        let store = model.store
        let hosts = store.sortedHosts(of: app, search: "")
        let livePIDs = app.processes.values.flatMap(\.pids).filter { kill($0, 0) == 0 || errno == EPERM }
        let mainPath = app.identity.bundlePath ?? app.identity.executablePath
            ?? app.processes.values.max { $0.window.total < $1.window.total }?.path ?? ""
        let signature = mainPath.isEmpty ? nil : model.resolver.signature(path: mainPath)
        let user = livePIDs.first.flatMap(LibProc.uid(of:)).map(LibProc.userName(of:))
        let subtitle: String = {
            switch app.identity.kind {
            case .app: return signature?.identifier ?? "App"
            case .system: return String(localized: "System services and daemons")
            case .tool: return String(localized: "Command-line tool")
            }
        }()

        InspectorHeader(title: app.identity.name, subtitle: subtitle) {
            AppIconView(identity: app.identity, size: 54)
        }
        TotalsBlock(window: app.window, rate: app.rate, live: store.window.isLive)

        ThroughputSection(selection: .app(app.id), window: app.window,
                          retransmission: app.sentForRetransmission > 100_000
                            ? Double(app.retransmitted) / Double(app.sentForRetransmission) : nil)

        InspectorSection("Processes") {
            InfoGrid {
                if !mainPath.isEmpty {
                    InfoRow("Path") { PathValue(path: mainPath) }
                }
                if let signature { InfoRow("Code ID", signature.codeID) }
                if let user { InfoRow("User", user) }
                if !livePIDs.isEmpty {
                    InfoRow("PID", livePIDs.sorted().prefix(6).map(String.init).joined(separator: ", ")
                            + (livePIDs.count > 6 ? " …" : ""))
                }
                if app.identity.kind == .system {
                    InfoRow("Services", Format.count(app.processes.count))
                }
                if let first = model.journal.firstSeen(appID: app.id) {
                    InfoRow("First connection", model.journal.firstSeenText(first))
                }
            }
        }

        ConnectionDetails(hosts: hosts, connections: app.connections, rtt: app.rtt, live: store.window.isLive)

        AppPrivacySection(app: app)

        DestinationsSection(siteIDs: app.siteIDs)
    }
}

/// Hostnames, addresses, ports, protocols of a set of hosts.
struct ConnectionDetails: View {
    @Environment(AppModel.self) private var model
    let hosts: [HostActivity]
    let connections: Int
    let rtt: Double?
    let live: Bool

    var body: some View {
        let hostnames = hosts.flatMap { host in host.hostnames.isEmpty ? [host.label] : host.hostnames.sorted() }
        let addresses = Array(Set(hosts.flatMap(\.addresses))).sorted { IPSort.less($0, $1) }
        let ports = Set(hosts.flatMap(\.ports))
        let tcp = ports.filter { $0.transport == .tcp }.sorted()
        let udp = ports.filter { $0.transport != .tcp }.sorted()
        let protocols = Set(ports.map(\.transport.label)).sorted()

        InspectorSection("Connection details") {
            InfoGrid {
                InfoRow("Period", model.store.window.isLive ? model.store.window.span.longLabel.capitalizedFirst
                        : Format.window(model.store.window, now: model.store.now))
                InfoRow("Hostnames") { ValueList(values: uniqued(hostnames)) }
                InfoRow("IP addresses") { ValueList(values: addresses, monospaced: true) }
                if !tcp.isEmpty {
                    InfoRow("TCP ports") { ValueList(values: tcp.map { Format.port($0.port, transport: .tcp) }, limit: 3) }
                }
                if !udp.isEmpty {
                    InfoRow("UDP ports") { ValueList(values: udp.map { Format.port($0.port, transport: $0.transport) }, limit: 3) }
                }
                if !protocols.isEmpty { InfoRow("Protocols", protocols.joined(separator: ", ")) }
                if live { InfoRow("Connections", String(localized: "\(connections) active")) }
                if let rtt { InfoRow("Latency", Format.milliseconds(rtt)) }
            }
        }
    }

    private func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Places a selection talks to, biggest first; a click selects the place.
struct DestinationsSection: View {
    @Environment(AppModel.self) private var model
    let siteIDs: Set<String>

    var body: some View {
        let store = model.store
        let sites = siteIDs.compactMap { store.sites[$0] }
            .filter { $0.isVisible(in: store.window) }
            .sorted { $0.window.total > $1.window.total }
        if !sites.isEmpty {
            let top = Double(sites.first?.window.total ?? 1)
            InspectorSection("Destinations") {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(sites.prefix(8)) { site in
                        Button {
                            withAnimation(Theme.selection) { model.ui.selection = .site(site.id) }
                        } label: {
                            PlaceRow(site: site, fraction: Double(site.window.total) / max(top, 1))
                        }
                        .buttonStyle(.plain)
                    }
                    if sites.count > 8 {
                        Text("+ \(sites.count - 8) other places")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct PlaceRow: View {
    let site: SiteActivity
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(Format.flag(site.place.countryCode))
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 0) {
                    Text(site.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text([site.place.country, site.organizations.sorted().first].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(Format.bytes(site.window.total))
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ShareBar(fraction: fraction)
        }
        .contentShape(Rectangle())
    }
}

/// A path that wraps, with a button to reveal it in the Finder.
struct PathValue: View {
    let path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(path)
                .font(.system(size: 12))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "arrow.forward.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        }
    }
}

enum IPSort {
    /// IPv4 before IPv6, then numeric order.
    static func less(_ lhs: String, _ rhs: String) -> Bool {
        let a = IPAddress.bytes(lhs) ?? [], b = IPAddress.bytes(rhs) ?? []
        if a.count != b.count { return a.count < b.count }
        return a.lexicographicallyPrecedes(b)
    }
}
