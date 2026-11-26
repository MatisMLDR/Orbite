import SwiftUI

/// Overview: the networks this Mac has been on, most recent first.
struct NetworksSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let networks = model.networks.networks
        let current = model.network.currentNetwork?.id
        let now = model.store.now
        if !networks.isEmpty {
            InspectorSection("Networks") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(networks.prefix(5)) { network in
                        Button {
                            withAnimation(Theme.selection) { model.ui.selection = .network(network.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: NetworkSymbols.symbol(network))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 5) {
                                        Text(network.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                        if network.isMobile { Tag(text: "MOBILE", tint: .orange) }
                                    }
                                    Text(network.id == current ? String(localized: "Connected") : Format.ago(Date(timeIntervalSince1970: TimeInterval(network.lastSeen))))
                                        .font(.system(size: 11))
                                        .foregroundStyle(network.id == current ? Theme.live : .secondary)
                                }
                                Spacer()
                                Text(Format.bytes(network.buckets.sum(from: now - 7 * 86_400, to: now + 1, now: now).total))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Overview and menu bar: mobile data used in the current plan cycle, against the quota if one is set.
struct MobileDataSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let networks = model.networks
        let usage = networks.mobileUsage()
        let onMobile = model.network.currentNetwork.flatMap { networks.record($0.id)?.isMobile } ?? false
        if networks.quotaGB > 0 || onMobile || !usage.total.isZero {
            InspectorSection("Mobile data") {
                VStack(alignment: .leading, spacing: 10) {
                    MobileDataGauge(used: usage.total.total, quotaGB: networks.quotaGB, since: usage.since)
                    let top = usage.byApp.sorted { $0.value.total > $1.value.total }.prefix(4)
                    if !top.isEmpty {
                        InfoGrid {
                            ForEach(Array(top), id: \.key) { appID, traffic in
                                InfoRow(model.store.apps[appID]?.identity.name ?? appID, Format.bytes(traffic.total))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// « 3,2 Go / 20 Go » with a bar that turns orange at 80 % and red past the quota.
struct MobileDataGauge: View {
    let used: UInt64
    let quotaGB: Double
    let since: Int32
    var compact = false

    var body: some View {
        let quota = quotaGB * 1_000_000_000
        let fraction = quota > 0 ? Double(used) / quota : 0
        let color: Color = fraction >= 1 ? .red : (fraction >= 0.8 ? .orange : Theme.live)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota > 0 ? "\(Format.bytes(used)) / \(Format.bytes(quota))" : Format.bytes(used))
                    .font(.system(size: compact ? 12.5 : 15, weight: .semibold))
                    .monospacedDigit()
                Spacer()
                Text("since \(Self.day(since))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if quota > 0 { ShareBar(fraction: fraction, color: color) }
        }
    }

    static func day(_ index: Int32) -> String {
        // Day index back to a date: noon UTC of that civil day, read in the local calendar.
        let date = Date(timeIntervalSince1970: TimeInterval(Int(index) * 86_400 + 43_200))
        return date.formatted(.dateTime.day().month(.wide).locale(Format.locale))
    }
}

enum NetworkSymbols {
    static func symbol(_ network: NetworkRecord) -> String {
        if network.expensive && network.medium == .wifi { return "personalhotspot" }
        switch network.medium {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .other: return "network"
        }
    }
}

// MARK: - Network inspector

struct NetworkInspector: View {
    @Environment(AppModel.self) private var model
    let network: NetworkRecord
    @State private var confirmForget = false

    var body: some View {
        let store = model.store
        let window = store.window
        let now = store.now
        let (start, end) = window.range(now: now)
        let total = network.buckets.sum(from: start, to: end, now: now)
        let (count, width) = window.span == .fiveMinutes ? (5, 60) : window.span.bins
        let histogramEnd = window.span == .fiveMinutes ? ((end + 59) / 60) * 60 : window.histogramEnd(now: now)
        let bins = network.buckets.bins(count: count, width: width, end: histogramEnd, now: now)
        let firstDay = model.networks.dayIndex(for: start)
        let lastDay = model.networks.dayIndex(for: max(start, end - 1))
        let apps = network.total(fromDay: firstDay, toDay: lastDay).byApp.sorted { $0.value.total > $1.value.total }
        let current = model.network.currentNetwork?.id == network.id

        InspectorHeader(title: network.name, subtitle: current ? String(localized: "Current network") : String(localized: "Seen \(Format.ago(Date(timeIntervalSince1970: TimeInterval(network.lastSeen))))")) {
            SymbolIcon(symbol: NetworkSymbols.symbol(network), size: 54,
                       colors: network.isMobile ? [.orange.opacity(0.85), .orange] : [Theme.download.opacity(0.85), Theme.download])
        }
        TotalsBlock(window: total, rate: .zero, live: false)

        InspectorSection("Throughput") {
            MirrorHistogram(bins: bins, binWidth: width, end: histogramEnd)
                .frame(height: 64)
        }

        InspectorSection("Network") {
            InfoGrid {
                InfoRow("Type", Self.kind(network))
                if let security = network.security {
                    InfoRow("Security") {
                        Text(security).foregroundStyle(NetworkInfo.isWeak(security) ? Theme.plaintext : .primary)
                    }
                }
                InfoRow("First visit", Format.moment(Date(timeIntervalSince1970: TimeInterval(network.firstSeen))))
                if !current {
                    InfoRow("Last visit", Format.moment(Date(timeIntervalSince1970: TimeInterval(network.lastSeen))))
                }
                if network.peakRate > 0 { InfoRow("Highest rate seen", Format.rate(network.peakRate)) }
                if let internet = network.internetBaseline { InfoRow("Usual latency", Format.milliseconds(internet)) }
                InfoRow("Mobile data") {
                    Toggle("", isOn: Binding(get: { network.isMobile }, set: { value in
                        let automatic = network.expensive || network.medium == .cellular
                        model.networks.setMobile(value == automatic ? nil : value, for: network.id)
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
        }

        if !apps.isEmpty {
            let top = Double(apps.first?.value.total ?? 1)
            InspectorSection("Apps on this network") {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(apps.prefix(8), id: \.key) { appID, traffic in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                if let app = store.apps[appID] { AppIconView(identity: app.identity, size: 18) }
                                Text(store.apps[appID]?.identity.name ?? appID).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(Format.bytes(traffic.total))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ShareBar(fraction: Double(traffic.total) / max(top, 1))
                        }
                    }
                    Text(window.span == .week ? "Per day over the period" : "Over the whole day")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }

        if !network.plaintextHosts.isEmpty {
            InspectorSection("In clear text on this network") {
                ValueList(values: network.plaintextHosts.reversed(), limit: 5)
            }
        }

        Button("Forget This Network…", role: .destructive) { confirmForget = true }
            .controlSize(.small)
            .confirmationDialog("Forget “\(network.name)”?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) {
                    model.ui.selection = nil
                    model.networks.forget(network.id)
                }
            } message: {
                Text("Its history in Orbite is deleted. It will show up again if the Mac reconnects to it.")
            }
    }

    static func kind(_ network: NetworkRecord) -> String {
        switch network.medium {
        case .wifi: network.expensive ? String(localized: "Personal Hotspot (Wi-Fi)") : "Wi-Fi"
        case .ethernet: "Ethernet"
        case .cellular: String(localized: "Cellular")
        case .other: String(localized: "Other")
        }
    }
}
