import SwiftUI

/// Overview: how much goes to trackers over the window, to whom, and which apps call them most.
struct PrivacyOverviewSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let window = store.window
        let apps = store.apps.values.filter { $0.isVisible(in: window) }
        let hosts = apps.flatMap { app in app.hosts.values.filter { $0.isVisible(in: window) } }
        let summary = TrackerSummary.make(hosts.map { ($0.tracker, $0.window.total) })
        let plaintext = hosts.filter(\.hasRiskyPlaintext)
        let chattiest = apps.map { app in
            (app: app, count: app.hosts.values.filter { $0.tracker != nil && $0.isVisible(in: window) }.count)
        }
        .filter { $0.count > 0 }
        .sorted { ($0.count, $1.app.identity.name) > ($1.count, $0.app.identity.name) }

        InspectorSection("Privacy") {
            VStack(alignment: .leading, spacing: 12) {
                switch model.trackers.phase {
                case .ready:
                    if summary.trackerHosts == 0 {
                        Text("No known tracker over this period.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Format.percent(summary.share))
                                .font(.system(size: 22, weight: .bold))
                                .monospacedDigit()
                            Text("of bytes to \(Format.plural(summary.trackerHosts, "tracking domain", "tracking domains"))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        let top = Double(summary.owners.first?.bytes ?? 1)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(summary.owners.prefix(4), id: \.name) { owner in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(owner.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                        Spacer()
                                        Text(Format.bytes(owner.bytes))
                                            .font(.system(size: 11.5, weight: .medium))
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    ShareBar(fraction: Double(owner.bytes) / max(top, 1), color: Theme.tracker)
                                }
                            }
                        }
                        if !chattiest.isEmpty {
                            InfoGrid {
                                InfoRow("Most trackers") {
                                    ValueList(values: chattiest.prefix(3).map { "\($0.app.identity.name) (\($0.count))" }, limit: 3)
                                }
                            }
                        }
                    }
                case .downloading:
                    Label("Downloading the tracker list…", systemImage: "arrow.down.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                case .missing, .failed:
                    HStack {
                        Text("Tracker list missing.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Download") { Task { await model.trackers.download() } }.controlSize(.small)
                    }
                }

                if !plaintext.isEmpty {
                    let names = Set(plaintext.compactMap { store.apps[$0.appID]?.identity.name }).sorted()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.open.fill")
                            .foregroundStyle(Theme.plaintext)
                            .font(.system(size: 12, weight: .semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Format.plural(plaintext.count, "connection", "connections")) without encryption")
                                .font(.system(size: 12.5, weight: .medium))
                            Text(names.prefix(4).joined(separator: ", ") + (names.count > 4 ? "…" : ""))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Overview: the apps that send the most over the window, with how much more they send than they receive.
struct UploadersSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let apps = model.store.sortedApps(filter: .all, sort: .upload, search: "").filter { $0.window.bytesOut > 0 }
        if !apps.isEmpty {
            let top = Double(apps.first?.window.bytesOut ?? 1)
            InspectorSection("Who sends the most") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(apps.prefix(5)) { app in
                        Button {
                            withAnimation(Theme.selection) { model.ui.selection = .app(app.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    AppIconView(identity: app.identity, size: 18)
                                    Text(app.identity.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    if let ratio = UploadRatio.factor(app.window) {
                                        Tag(text: "↑ \(Format.factor(ratio))", tint: Theme.upload)
                                    }
                                    Spacer()
                                    Text(Format.bytes(app.window.bytesOut))
                                        .font(.system(size: 11.5, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                ShareBar(fraction: Double(app.window.bytesOut) / max(top, 1), color: Theme.upload)
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

/// Host inspector: the tracker behind the domain and whether the traffic is encrypted.
struct HostPrivacySection: View {
    let host: HostActivity

    var body: some View {
        if host.tracker != nil || !host.plaintext.isEmpty {
            InspectorSection("Privacy") {
                InfoGrid {
                    if let tracker = host.tracker {
                        InfoRow("Tracking") {
                            HStack(spacing: 6) {
                                Tag(text: tracker.category.tag, tint: Theme.tracker)
                                Text(tracker.category.label)
                            }
                        }
                        InfoRow("Owner", tracker.owner)
                        if let prevalence = tracker.prevalence, prevalence > 0 {
                            InfoRow("Prevalence", String(localized: "on \(Format.percent(prevalence)) of websites"))
                        }
                    }
                    if !host.plaintext.isEmpty {
                        let protocols = host.plaintext.sorted().map(\.label).joined(separator: ", ")
                        InfoRow("Encryption") {
                            if host.hasRiskyPlaintext {
                                Label("No: \(protocols)", systemImage: "lock.open.fill")
                                    .foregroundStyle(Theme.plaintext)
                            } else {
                                Text("\(protocols) in clear text, to check a certificate (harmless)")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if host.tracker != nil {
                    Text("According to DuckDuckGo's list (Tracker Radar)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// App inspector: its trackers over the window.
struct AppPrivacySection: View {
    @Environment(AppModel.self) private var model
    let app: AppActivity

    var body: some View {
        let hosts = model.store.sortedHosts(of: app, search: "")
        let summary = TrackerSummary.make(hosts.map { ($0.tracker, $0.window.total) })
        let plaintext = hosts.filter(\.hasRiskyPlaintext)
        if summary.trackerHosts > 0 || !plaintext.isEmpty {
            InspectorSection("Privacy") {
                InfoGrid {
                    if summary.trackerHosts > 0 {
                        InfoRow("Trackers", "\(Format.plural(summary.trackerHosts, "domain", "domains")) · \(Format.bytes(summary.trackerBytes)) (\(Format.percent(summary.share)))")
                        InfoRow("Owned by") { ValueList(values: summary.owners.map(\.name), limit: 3) }
                    }
                    if !plaintext.isEmpty {
                        InfoRow("Clear text") {
                            ValueList(values: plaintext.map { "\($0.label) (\($0.plaintext.sorted().map(\.label).joined(separator: ", ")))" },
                                      limit: 3)
                        }
                    }
                }
            }
        }
    }
}

/// « Envoie 3,2× plus que reçu » for whatever sends much more than it receives.
enum UploadRatio {
    /// Out over in, when it sends more than it receives and over 1 Mo.
    static func factor(_ traffic: Traffic) -> Double? {
        guard traffic.bytesOut > 1_000_000, traffic.bytesOut > traffic.bytesIn else { return nil }
        return Double(traffic.bytesOut) / Double(max(traffic.bytesIn, 1))
    }

    static func text(_ traffic: Traffic) -> String? {
        guard let factor = factor(traffic) else { return nil }
        if traffic.bytesIn == 0 { return String(localized: "Sends without receiving anything") }
        return String(localized: "Sends \(Format.factor(min(factor, 999))) more than it receives")
    }
}
