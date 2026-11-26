import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What to export and how; the file goes where the save panel says.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scope: ExportScope = .window
    @State private var level: ExportLevel = .apps
    @State private var format: ExportFormat = .csv
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SymbolIcon(symbol: "square.and.arrow.up", size: 40, colors: [Theme.download.opacity(0.85), Theme.download])
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export").font(.system(size: 20, weight: .bold))
                    Text("Orbite's volumes in a file, for a spreadsheet or a script")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Form {
                Picker("Period", selection: $scope) {
                    ForEach(ExportScope.allCases) { Text($0.label(model.store)).tag($0) }
                }
                Picker("Content", selection: $level) {
                    ForEach(ExportLevel.allCases) { Text($0.label).tag($0) }
                }
                if level != .everything {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func export() {
        let store = model.store
        let data: Data
        let fileExtension: String
        do {
            if level == .everything {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                data = try encoder.encode(store.snapshot())
                fileExtension = "json"
            } else {
                let table = ExportBuilder.table(level, window: scope.window(store), store: store, trackers: true)
                data = format == .csv ? Data(Exporter.csv(table).utf8) : try Exporter.json(table)
                fileExtension = format.fileExtension
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Orbite-\(level.fileName)-\(day).\(fileExtension)"
        panel.allowedContentTypes = [fileExtension == "csv" ? .commaSeparatedText : .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum ExportScope: String, CaseIterable, Identifiable {
    case window, day, week
    var id: Self { self }

    @MainActor func label(_ store: TrafficStore) -> String {
        switch self {
        case .window: String(localized: "Period shown (\(store.window.isLive ? store.window.span.longLabel : Format.window(store.window, now: store.now)))")
        case .day: String(localized: "Last 24 hours")
        case .week: String(localized: "Last 7 days")
        }
    }

    @MainActor func window(_ store: TrafficStore) -> TimeWindow {
        switch self {
        case .window: store.window
        case .day: TimeWindow(span: .day, end: nil)
        case .week: TimeWindow(span: .week, end: nil)
        }
    }
}

enum ExportLevel: String, CaseIterable, Identifiable {
    case apps, domains, places, hourly, everything
    var id: Self { self }

    var label: String {
        switch self {
        case .apps: String(localized: "Total per app")
        case .domains: String(localized: "Total per domain and per app")
        case .places: String(localized: "Total per place")
        case .hourly: String(localized: "Series per hour and per app")
        case .everything: String(localized: "Full history (raw JSON)")
        }
    }

    var fileName: String {
        switch self {
        case .apps: "apps"
        case .domains: "domains"
        case .places: "places"
        case .hourly: "hours"
        case .everything: "history"
        }
    }
}

/// Reads the store into export tables. Totals come from the buckets, so exporting never disturbs
/// what the window shows.
enum ExportBuilder {
    static func table(_ level: ExportLevel, window: TimeWindow, store: TrafficStore, trackers: Bool) -> ExportTable {
        let now = store.now
        let (start, end) = window.range(now: now)
        func total(_ stats: ActivityStats) -> Traffic { stats.buckets.sum(from: start, to: end, now: now) }
        func numbers(_ traffic: Traffic) -> [String] { ["\(traffic.bytesIn)", "\(traffic.bytesOut)", "\(traffic.total)"] }

        switch level {
        case .apps:
            let rows = store.apps.values.map { ($0, total($0.stats)) }.filter { !$0.1.isZero }
                .sorted { $0.1.total > $1.1.total }
                .map { app, traffic in
                    [app.identity.name, app.identity.kind.rawValue, app.identity.bundlePath ?? app.identity.executablePath ?? ""]
                        + numbers(traffic) + [Exporter.iso(app.lastSeen)]
                }
            return ExportTable(columns: ["app", "kind", "path", "bytes_in", "bytes_out", "bytes_total", "last_seen"], rows: rows)

        case .domains:
            var rows: [(UInt64, [String])] = []
            for app in store.apps.values {
                for host in app.hosts.values {
                    let traffic = total(host.stats)
                    guard !traffic.isZero else { continue }
                    let row = [app.identity.name, host.label, host.kind.rawValue, host.organization.map(HostLabel.cleanOrganization) ?? "",
                               host.hostnames.sorted().prefix(10).joined(separator: " ")]
                        + numbers(traffic)
                        + [host.tracker?.owner ?? "", host.tracker?.category.label ?? "",
                           host.plaintext.sorted().map(\.label).joined(separator: " "), Exporter.iso(host.lastSeen)]
                    rows.append((traffic.total, row))
                }
            }
            return ExportTable(columns: ["app", "domain", "kind", "organization", "hostnames", "bytes_in", "bytes_out", "bytes_total",
                                         "tracker_owner", "tracker_category", "plaintext", "last_seen"],
                               rows: rows.sorted { $0.0 > $1.0 }.map(\.1))

        case .places:
            let rows = store.sites.values.map { ($0, total($0.stats)) }.filter { !$0.1.isZero }
                .sorted { $0.1.total > $1.1.total }
                .map { site, traffic in
                    [site.place.city ?? "", site.place.region ?? "", site.place.country ?? "", site.place.countryCode ?? "",
                     String(format: "%.4f", site.place.latitude), String(format: "%.4f", site.place.longitude),
                     site.organizations.sorted().joined(separator: " / ")]
                        + numbers(traffic) + [Exporter.iso(site.lastSeen)]
                }
            return ExportTable(columns: ["city", "region", "country", "country_code", "latitude", "longitude", "organizations",
                                         "bytes_in", "bytes_out", "bytes_total", "last_seen"], rows: rows)

        case .hourly, .everything:
            var rows: [[String]] = []
            let firstHour = start / 3600, lastHour = (end - 1) / 3600
            for app in store.apps.values {
                for (hour, traffic) in app.stats.buckets.hours where Int(hour) >= firstHour && Int(hour) <= lastHour {
                    guard !traffic.isZero else { continue }
                    rows.append([Exporter.iso(Int(hour) * 3600), app.identity.name] + numbers(traffic))
                }
            }
            rows.sort { ($0[0], $0[1]) < ($1[0], $1[1]) }
            return ExportTable(columns: ["hour", "app", "bytes_in", "bytes_out", "bytes_total"], rows: rows)
        }
    }
}
