import AppKit
import SwiftUI

/// Shown when nothing is selected: this Mac's connection, live rates and where the bytes go.
struct NetworkOverview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let network = model.network
        let live = store.window.isLive
        let apps = store.sortedApps(filter: .all, sort: .traffic, search: "")
        let countries = countryTotals()

        InspectorHeader(title: Self.computerName,
                        subtitle: live ? String(localized: "Overview · live") : String(localized: "Overview · \(Format.window(store.window, now: store.now))")) {
            Image(nsImage: NSImage(named: NSImage.computerName) ?? NSImage())
                .resizable()
                .interpolation(.high)
        }

        if live {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    DirectionPill(direction: .up, value: Format.rate(store.totalRate.outPerSecond), large: true)
                    DirectionPill(direction: .down, value: Format.rate(store.totalRate.inPerSecond), large: true)
                }
                RateSparkline(rates: store.recentRates)
                    .frame(height: 46)
                    .padding(.horizontal, 2)
                Text("Last minute, all apps together")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        } else {
            TotalsBlock(window: store.totalWindow, rate: .zero, live: false)
        }

        WhatsNewSection()

        InspectorSection("Connection") {
            InfoGrid {
                InfoRow("Interface") {
                    Label {
                        Text([network.serviceName, network.interface].compactMap { $0 }.joined(separator: " · "))
                    } icon: {
                        Image(systemName: network.medium.symbol).foregroundStyle(.secondary)
                    }
                    .labelStyle(.titleAndIcon)
                }
                InfoRow("Status", statusText(network))
                if let wifi = network.wifi {
                    InfoRow("Wi-Fi network", wifi.ssid ?? String(localized: "Name hidden (allow Location)"))
                    InfoRow("Signal") {
                        HStack(spacing: 6) {
                            SignalBars(bars: wifi.bars)
                            Text("\(wifi.rssi) dBm · noise \(wifi.noise) dBm")
                        }
                    }
                    InfoRow("Link rate", "\(Int(wifi.transmitRate)) Mbit/s")
                    if let channel = wifi.channel { InfoRow("Channel", channel) }
                    if let security = wifi.security { InfoRow("Security", security) }
                }
                if !network.ipv4.isEmpty { InfoRow("IPv4") { ValueList(values: network.ipv4, monospaced: true) } }
                if !network.ipv6.isEmpty { InfoRow("IPv6") { ValueList(values: network.ipv6, limit: 2, monospaced: true) } }
                if let router = network.router { InfoRow("Router", router) }
                if !network.dnsServers.isEmpty { InfoRow("DNS") { ValueList(values: network.dnsServers, limit: 3, monospaced: true) } }
                InfoRow("Actual interface", "↑ \(Format.rate(network.linkRate.outPerSecond))  ↓ \(Format.rate(network.linkRate.inPerSecond))")
                    .help("Everything that goes through the network card, system protocols included")
                if let share = store.tunnelShare {
                    InfoRow("VPN", String(localized: "\(Format.percent(share)) of the traffic goes through the tunnel\(store.tunnelInterface.map { " (\($0))" } ?? "")"))
                        .help("Share of the last minute's bytes that went through a tunnel interface")
                } else if network.vpnActive {
                    InfoRow("VPN", String(localized: "On, no traffic in the tunnel"))
                }
                if relayActive(store) {
                    InfoRow("Private Relay", String(localized: "On: Safari's destinations are hidden"))
                        .help("iCloud Private Relay hides the real destination: the map shows the relay")
                }
            }
        }

        MobileDataSection()

        NetworksSection()

        InspectorSection("Activity") {
            InfoGrid {
                InfoRow("Period", live ? store.window.span.longLabel.capitalizedFirst : Format.window(store.window, now: store.now))
                InfoRow("Sent", Format.bytes(store.totalWindow.bytesOut))
                InfoRow("Received", Format.bytes(store.totalWindow.bytesIn))
                if live { InfoRow("Connections", String(localized: "\(store.activeConnections) active")) }
                InfoRow("Apps", Format.count(apps.count))
                InfoRow("Places", Format.count(store.visibleSites.count))
                InfoRow("Countries", Format.count(store.countryCount))
            }
        }

        if !apps.isEmpty {
            let top = Double(apps.first?.window.total ?? 1)
            InspectorSection("Most active apps") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(apps.prefix(5)) { app in
                        Button {
                            withAnimation(Theme.selection) { model.ui.selection = .app(app.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    AppIconView(identity: app.identity, size: 18)
                                    Text(app.identity.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Spacer()
                                    Text(Format.bytes(app.window.total))
                                        .font(.system(size: 11.5, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                ShareBar(fraction: Double(app.window.total) / max(top, 1), color: Theme.upload)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        UploadersSection()

        PrivacyOverviewSection()

        if !countries.isEmpty {
            let top = Double(countries.first?.total ?? 1)
            InspectorSection("Countries") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(countries.prefix(6), id: \.code) { country in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(Format.flag(country.code)).font(.system(size: 15))
                                Text(country.name).font(.system(size: 12.5, weight: .medium))
                                Spacer()
                                Text(Format.bytes(country.total))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ShareBar(fraction: Double(country.total) / max(top, 1))
                        }
                    }
                }
            }
        }

        InspectorSection("Sources", defaultExpanded: false) {
            InfoGrid {
                InfoRow("Data", String(localized: "nettop (macOS), no admin rights"))
                InfoRow("Domain names") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.helper.state == .running ? Theme.live : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text(model.helper.state.label)
                        if model.helper.state == .notInstalled {
                            Button("Turn On…") { model.helper.enable() }.controlSize(.mini)
                        }
                    }
                }
                InfoRow("Geolocation", model.geo.month.map { "DB-IP Lite · \($0)" } ?? "DB-IP Lite")
                InfoRow("Mac's location", model.home.source.label)
            }
        }

        AttributionFooter()
    }

    /// Traffic to the iCloud Private Relay in the last ten minutes.
    private func relayActive(_ store: TrafficStore) -> Bool {
        let since = store.now - 600
        return store.apps.values.contains { app in
            app.hosts[SpecialHosts.privateRelayLabel].map { $0.lastSeen >= since } ?? false
        }
    }

    private func statusText(_ network: NetworkInfo) -> String {
        guard network.isOnline else { return String(localized: "Offline") }
        var parts = [String(localized: "Online")]
        if network.vpnActive { parts.append("VPN") }
        if network.isExpensive { parts.append(String(localized: "expensive connection")) }
        if network.isConstrained { parts.append(String(localized: "Low Data Mode")) }
        return parts.joined(separator: " · ")
    }

    private func countryTotals() -> [(code: String, name: String, total: UInt64)] {
        var totals: [String: (String, UInt64)] = [:]
        for site in model.store.visibleSites {
            guard let code = site.place.countryCode else { continue }
            let name = site.place.country ?? code
            totals[code, default: (name, 0)].1 += site.window.total
        }
        return totals.map { (code: $0.key, name: $0.value.0, total: $0.value.1) }
            .sorted { $0.total > $1.total }
    }
}

private struct SignalBars: View {
    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index <= bars ? Color.primary : Color.primary.opacity(0.15))
                    .frame(width: 3, height: CGFloat(3 + index * 2))
            }
        }
    }
}

extension NetworkOverview {
    /// The Mac's name, as in Sharing settings.
    static var computerName: String {
        #if DEBUG
        // Screenshot mode never shows the real name.
        if Demo.isActive { return "MacBook Pro" }
        #endif
        return Host.current().localizedName ?? String(localized: "This Mac")
    }
}
