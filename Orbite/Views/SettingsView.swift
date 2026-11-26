import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        @Bindable var ui = model.ui
        TabView {
            Form {
                Picker("Map Style", selection: $ui.mapLook) {
                    ForEach(MapLook.allCases) { look in
                        Label(look.label, systemImage: look.symbol).tag(look)
                    }
                }
                Toggle("Day and night on the globe", isOn: $ui.globeDayNight)
                    .disabled(ui.mapLook != .globe)
                    .help("Lights the globe from the sun's real position")
                Toggle("Animated flows on the map", isOn: $ui.showFlows)
                LabeledContent("Mac's location") {
                    HStack {
                        Text(model.home.source.label).foregroundStyle(.secondary)
                        if !model.home.isAuthorized {
                            Button("Allow Location") { model.home.requestAccess() }
                        }
                    }
                }
                Button("Show the Welcome Again") { model.ui.showOnboarding = true }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    Toggle("Show Orbite in the menu bar", isOn: $ui.menuBarEnabled)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if ui.menuBarEnabled && ui.menuBarItemHidden {
                            Label("macOS hides Orbite: there is not enough room left in the menu bar (next to the notch). Pick a narrower style or remove other icons.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text("With its window closed, Orbite keeps measuring in the background: it stays in the menu bar and leaves the Dock. To quit it, open its panel and choose Quit.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                }
                Section("Display") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(MenuBarStyle.allCases) { style in
                            MenuBarStyleCard(style: style, selected: ui.menuBarStyle == style) {
                                ui.menuBarStyle = style
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .disabled(!ui.menuBarEnabled)
            }
            .formStyle(.grouped)
            .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }

            Form {
                Section {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.helper.state == .running ? Theme.live : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(model.helper.state.label)
                        }
                    }
                    if !model.helper.interfaces.isEmpty {
                        LabeledContent("Interfaces listened to", value: model.helper.interfaces.joined(separator: ", "))
                    }
                    if let error = model.helper.captureError {
                        LabeledContent("Last error", value: error)
                    }
                    LabeledContent("Known names", value: Format.count(model.names.dnsCount))
                    HStack {
                        if model.helper.state == .notInstalled {
                            Button("Turn On the Service") { model.helper.enable() }
                        } else {
                            Button("Turn Off the Service", role: .destructive) { model.helper.disable() }
                        }
                        if model.helper.state == .needsApproval {
                            Button("Open System Settings") { model.helper.openLoginItems() }
                        }
                    }
                } footer: {
                    Text("The service runs as root and only listens to DNS answers (port 53), to match each address with the domain that was asked for. It keeps everything in memory, writes nothing to disk and answers only Orbite. Encrypted DNS (browsers' DNS over HTTPS, iCloud Private Relay) escapes it: those connections show the organization's name.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Domain Names", systemImage: "text.magnifyingglass") }

            Form {
                Section {
                    LabeledContent("Database", value: model.geo.month.map { "DB-IP Lite · \($0)" } ?? String(localized: "Missing"))
                    LabeledContent("Status") {
                        switch model.geo.phase {
                        case .ready: Text("Ready")
                        case .missing: Text("Not downloaded")
                        case .downloading(let fraction): ProgressView(value: fraction).frame(width: 140)
                        case .failed(let message): Text(message).foregroundStyle(.orange)
                        }
                    }
                    Button("Update Now") { Task { await model.geo.download() } }
                        .disabled(model.geo.isDownloading)
                } footer: {
                    Text("IP Geolocation by DB-IP (db-ip.com), CC BY 4.0 license. The database is downloaded to this Mac: no address is sent out to be located.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Geolocation", systemImage: "globe") }

            Form {
                Section {
                    LabeledContent("Tracker list") {
                        switch model.trackers.phase {
                        case .ready(let count): Text("\(Format.count(count)) domains")
                        case .missing: Text("Not downloaded")
                        case .downloading: ProgressView().controlSize(.small)
                        case .failed(let message): Text(message).foregroundStyle(.orange)
                        }
                    }
                    if let updated = model.trackers.updatedAt {
                        LabeledContent("Updated", value: Format.moment(updated))
                    }
                    Button("Update Now") { Task { await model.trackers.download() } }
                        .disabled(model.trackers.isDownloading)
                } footer: {
                    Text("DuckDuckGo's lists (Tracker Radar and App Tracking Protection), CC BY-NC-SA 4.0 license, refreshed every week. The matching happens on this Mac: no domain name is sent out.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Clear text", value: String(localized: "HTTP, FTP, Telnet, POP3, IMAP, public DNS"))
                } footer: {
                    Text("These protocols travel unencrypted: on an open Wi-Fi, anyone nearby can read them. Certificate checks (OCSP) over HTTP are harmless and stay gray.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }

            NetworksSettings()
                .tabItem { Label("Networks", systemImage: "wifi") }

            Form {
                Section {
                    LabeledContent("History", value: String(localized: "7 days, on this Mac"))
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("Volumes per minute over 24 hours and per hour over 7 days, per app, domain and place, and the journal of first times over 30 days. Stored in ~/Library/Application Support/Orbite.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Data", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 600, height: 460)
        .confirmationDialog("Clear all of Orbite's history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.clearHistory() }
        } message: {
            Text("The recorded volumes are deleted. Live measuring goes on.")
        }
    }
}

/// Data plan and the networks Orbite knows.
private struct NetworksSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var networks = model.networks
        Form {
            Section {
                Toggle("Track a mobile data plan", isOn: Binding(
                    get: { networks.quotaGB > 0 }, set: { networks.quotaGB = $0 ? max(networks.quotaGB, 20) : 0 }))
                if networks.quotaGB > 0 {
                    LabeledContent("Plan") {
                        HStack(spacing: 6) {
                            TextField("", value: $networks.quotaGB, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Text("GB")
                        }
                    }
                }
                Picker("Resets on day", selection: $networks.resetDay) {
                    ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                }
            } footer: {
                Text("Counts what goes through the iPhone's Personal Hotspot, a cellular network, or any network marked “mobile” below. Nothing is cut off: Orbite only shows where you stand.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Known networks") {
                let list = networks.networks
                if list.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(list) { network in
                    HStack {
                        Image(systemName: NetworkSymbols.symbol(network)).foregroundStyle(.secondary).frame(width: 18)
                        Text(network.name).lineLimit(1)
                        Spacer()
                        Toggle("Mobile", isOn: Binding(get: { network.isMobile }, set: { value in
                            let automatic = network.expensive || network.medium == .cellular
                            networks.setMobile(value == automatic ? nil : value, for: network.id)
                        }))
                        .toggleStyle(.checkbox)
                        Button {
                            networks.forget(network.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this network")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One menu bar style, previewed live on a light and a dark menu bar.
private struct MenuBarStyleCard: View {
    let style: MenuBarStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                VStack(spacing: 4) {
                    strip(.light, background: Color(white: 0.93))
                    strip(.dark, background: Color(white: 0.17))
                }
                Text(style.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.sectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func strip(_ scheme: ColorScheme, background: Color) -> some View {
        MenuBarLabel(style: style)
            .padding(.horizontal, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .environment(\.colorScheme, scheme)
    }
}
