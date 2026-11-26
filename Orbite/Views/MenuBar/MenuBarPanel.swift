import AppKit
import SwiftUI

/// The panel under the menu bar item: live rates, the apps talking right now, today's volume,
/// the network, and the way back to the window.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model

    private static let rowHeight: CGFloat = 28
    private static let rowLimit = 5
    @State private var showsDiagnosis = false

    var body: some View {
        let store = model.store
        let _ = store.tick
        let rate = store.totalRate

        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    DirectionPill(direction: .up, value: Format.rate(rate.outPerSecond))
                    DirectionPill(direction: .down, value: Format.rate(rate.inPerSecond))
                }
                RateSparkline(rates: store.recentRates)
                    .frame(height: 34)
                    .drawingGroup()
                    .accessibilityHidden(true)
                stats
            }

            Divider()
            if showsDiagnosis { diagnosis } else { liveApps }
            Divider()
            today
            network
            mobileData
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 7) {
            OrbitGlyph(sending: false, receiving: false)
                .frame(width: 16, height: 16)
            Text("Orbite")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.store.streamError == nil {
                Circle().fill(Theme.live).frame(width: 6, height: 6)
                    .shadow(color: Theme.live.opacity(0.7), radius: 3)
                Text("Live")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Label("Measuring stopped", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var stats: some View {
        let store = model.store
        return HStack(spacing: 12) {
            stat(Format.plural(store.activeConnections, "connection", "connections"), symbol: "point.3.connected.trianglepath.dotted")
            stat(Format.plural(store.visibleSites.count, "place", "places"), symbol: "mappin.and.ellipse")
            stat(Format.plural(store.countryCount, "country", "countries"), symbol: "flag")
        }
        .font(.system(size: 11.5, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ text: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).lineLimit(1)
        }
    }

    /// Fixed height for five rows: a popover that resizes every second jumps under the menu bar.
    private var liveApps: some View {
        let apps = model.store.liveApps(limit: Self.rowLimit)
        return VStack(alignment: .leading, spacing: 6) {
            modeSwitch
            VStack(spacing: 0) {
                if apps.isEmpty {
                    Text("No traffic right now")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(apps) { app in
                        LiveAppRow(app: app, height: Self.rowHeight) {
                            model.menuBar?.showMainWindow(selecting: .app(app.id))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: Self.rowHeight * CGFloat(Self.rowLimit))
        }
    }

    /// « En ce moment » or « Diagnostic » in the same fixed-height area, so the popover keeps its size.
    private var modeSwitch: some View {
        HStack(spacing: 10) {
            ForEach([false, true], id: \.self) { diagnosis in
                Button {
                    showsDiagnosis = diagnosis
                    if diagnosis, !model.diagnosis.isRunning, model.diagnosis.result.map({ Date().timeIntervalSince($0.date) > 30 }) ?? true {
                        Task { await model.diagnosis.run(model: model) }
                    }
                } label: {
                    Text(diagnosis ? "Why is it slow?" : "Right now")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(showsDiagnosis == diagnosis ? .primary : .tertiary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var diagnosis: some View {
        let runner = model.diagnosis
        return VStack(alignment: .leading, spacing: 6) {
            modeSwitch
            VStack(alignment: .leading, spacing: 8) {
                switch runner.state {
                case .idle, .running:
                    VStack(spacing: 8) {
                        ProgressView(value: { if case .running(let value) = runner.state { value } else { 0 } }())
                        Text("Measuring the router and the internet…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done(let result):
                    DiagnosisFindings(result: result, compact: true) { _ in model.menuBar?.showDiagnosis() }
                    Spacer(minLength: 0)
                    HStack {
                        Button("Run Again") { Task { await runner.run(model: model) } }
                        Spacer()
                        Button("Details…") { model.menuBar?.showDiagnosis() }
                    }
                    .controlSize(.small)
                }
            }
            .frame(height: Self.rowHeight * CGFloat(Self.rowLimit))
        }
    }

    /// Shown on a mobile network or with a data plan set; its height never changes while the panel is open.
    @ViewBuilder private var mobileData: some View {
        let networks = model.networks
        let onMobile = model.network.currentNetwork.flatMap { networks.record($0.id)?.isMobile } ?? false
        if onMobile || networks.quotaGB > 0 {
            let usage = networks.mobileUsage()
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Mobile data")
                MobileDataGauge(used: usage.total.total, quotaGB: networks.quotaGB, since: usage.since, compact: true)
            }
        }
    }

    private var today: some View {
        let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let total = model.store.total(from: start)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Today")
            HStack(spacing: 8) {
                DirectionPill(direction: .up, value: Format.bytes(total.bytesOut), caption: String(localized: "sent"))
                DirectionPill(direction: .down, value: Format.bytes(total.bytesIn), caption: String(localized: "received"))
            }
        }
    }

    private var network: some View {
        let network = model.network
        let name: String = if !network.isOnline {
            String(localized: "Offline")
        } else if let wifi = network.wifi {
            wifi.ssid ?? "Wi-Fi"
        } else {
            network.serviceName ?? network.interface ?? String(localized: "Network")
        }
        return HStack(spacing: 7) {
            Image(systemName: network.isOnline ? network.medium.symbol : "wifi.slash")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if network.vpnActive { Tag(text: "VPN") }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open Orbite") { model.menuBar?.showMainWindow() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Spacer()
            Button {
                model.menuBar?.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings…")
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.regular)
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// App icon, name and live rates; the whole row opens the window on this app.
private struct LiveAppRow: View {
    let app: AppActivity
    let height: CGFloat
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AppIconView(identity: app.identity, size: 18)
                Text(app.identity.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                RatePair(rate: app.rate, font: .system(size: 11, weight: .semibold))
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(height: height)
            .background(Color.primary.opacity(hovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open Orbite on \(app.identity.name)")
    }
}
