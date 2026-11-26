import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ui = model.ui
        let store = model.store
        let _ = store.tick
        let apps = store.sortedApps(filter: ui.filter, sort: ui.sort, search: ui.search)

        VStack(spacing: 0) {
            // Above the list, not inset into it: rows stop at the filters instead of sliding under them.
            FilterBar()
            List(selection: $ui.selection) {
                if apps.isEmpty {
                    EmptySidebar(waiting: store.lastSampleDate == nil, searching: !ui.search.isEmpty)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                }
                ForEach(apps) { app in
                    AppGroup(app: app)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // Scrolled to the end, the last row sits above the blur.
            .contentMargins(.bottom, Theme.edgeBlur, for: .scrollContent)
            .clipped()
            .edgeBlur(bottom: Theme.edgeBlur)
            TrafficFooter()
        }
        .searchable(text: $ui.search, placement: .sidebar, prompt: "App, domain or address")
    }
}

private struct FilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ui = model.ui
        HStack(spacing: 8) {
            Picker("Filter", selection: $ui.filter) {
                ForEach(AppFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Menu {
                Picker("Sort By", selection: $ui.sort) {
                    ForEach(AppSort.allCases) { sort in
                        Text(sort.label).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

private struct EmptySidebar: View {
    let waiting: Bool
    let searching: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: waiting ? "antenna.radiowaves.left.and.right" : (searching ? "magnifyingglass" : "moon.zzz"))
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolEffect(.variableColor.iterative, isActive: waiting)
            Text(waiting ? "Listening to the network…" : (searching ? "No results" : "Nothing over this period"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// One app and, unfolded, its domains (or its processes for macOS).
private struct AppGroup: View {
    @Environment(AppModel.self) private var model
    let app: AppActivity

    var body: some View {
        let ui = model.ui
        let expanded = Binding(
            get: { ui.expanded.contains(app.id) || (!ui.search.isEmpty && app.identity.kind != .system) },
            set: { open in
                if open { ui.expanded.insert(app.id) } else { ui.expanded.remove(app.id) }
            })

        DisclosureGroup(isExpanded: expanded) {
            if expanded.wrappedValue {
                children
            }
        } label: {
            AppRow(app: app)
        }
        .tag(Selection.app(app.id))
    }

    @ViewBuilder
    private var children: some View {
        let store = model.store
        let showAll = model.ui.showAll.contains(app.id)
        if app.identity.kind == .system {
            let processes = store.sortedProcesses(of: app)
            ForEach(showAll ? processes : Array(processes.prefix(8))) { process in
                ProcessRow(process: process)
                    .tag(Selection.process(process.id))
            }
            moreRow(hidden: processes.count - 8, showAll: showAll)
        } else {
            let hosts = store.sortedHosts(of: app, search: model.ui.search)
            ForEach(showAll ? hosts : Array(hosts.prefix(8))) { host in
                HostRow(host: host)
                    .tag(Selection.host(host.id))
            }
            moreRow(hidden: hosts.count - 8, showAll: showAll)
        }
    }

    @ViewBuilder
    private func moreRow(hidden: Int, showAll: Bool) -> some View {
        if hidden > 0 {
            Button {
                withAnimation(.snappy) {
                    if showAll { model.ui.showAll.remove(app.id) } else { model.ui.showAll.insert(app.id) }
                }
            } label: {
                Text(showAll ? "Less" : "\(hidden) more…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
            .buttonStyle(.plain)
            .selectionDisabled()
        }
    }
}

struct AppRow: View {
    let app: AppActivity

    var body: some View {
        HStack(spacing: 9) {
            AppIconView(identity: app.identity, size: 22)
            HStack(spacing: 5) {
                Text(app.identity.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if app.identity.kind == .tool { Tag(text: "CLI") }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            VolumeLabel(traffic: app.window, active: app.rate.isActive)
            TrafficMeter(values: app.meter)
                .frame(width: 38, height: 22)
        }
        .padding(.vertical, 3)
        .help(app.rate.isActive ? String(localized: "Right now: ↑ \(Format.rate(app.rate.outPerSecond)) · ↓ \(Format.rate(app.rate.inPerSecond))") : app.identity.name)
    }
}

struct HostRow: View {
    let host: HostActivity

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(host.kind))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(host.label)
                .font(.system(size: 12.5, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let tracker = host.tracker {
                Tag(text: tracker.category.tag, tint: Theme.tracker)
                    .help("\(tracker.category.label) · \(tracker.owner)")
            }
            if host.hasRiskyPlaintext {
                Tag(text: String(localized: "CLEAR TEXT"), tint: Theme.plaintext)
                    .help(String(localized: "Not encrypted: \(host.plaintext.sorted().map(\.label).joined(separator: ", "))"))
            }
            Spacer(minLength: 4)
            VolumeLabel(traffic: host.window, active: host.rate.isActive, small: true)
            TrafficMeter(values: host.meter)
                .frame(width: 30, height: 17)
        }
        .padding(.vertical, 1)
        .help(host.hostnames.sorted().prefix(6).joined(separator: "\n"))
    }

    static func symbol(_ kind: HostLabelKind) -> String {
        switch kind {
        case .domain: "globe"
        case .organization: "building.2"
        case .address: "number"
        case .local: "house"
        }
    }
}

struct ProcessRow: View {
    let process: ProcessActivity

    var body: some View {
        HStack(spacing: 8) {
            ProcessIconView(path: process.path, size: 17)
            Text(process.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            VolumeLabel(traffic: process.window, active: process.rate.isActive, small: true)
            TrafficMeter(values: process.meter)
                .frame(width: 30, height: 17)
        }
        .padding(.vertical, 1)
    }
}

/// Volume over the window; a green dot marks live traffic.
private struct VolumeLabel: View {
    let traffic: Traffic
    let active: Bool
    var small = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.live)
                .frame(width: 5, height: 5)
                .opacity(active ? 1 : 0)
            Text(traffic.isZero ? "—" : Format.bytes(traffic.total))
                .font(.system(size: small ? 10.5 : 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(active ? .primary : .secondary)
        }
        .fixedSize()
    }
}
