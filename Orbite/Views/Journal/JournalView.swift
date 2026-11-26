import SwiftUI

/// The journal of firsts, grouped by day, newest first; a click shows the moment in the window.
struct JournalView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter: JournalFilter = .all
    /// Events newer than this are marked: captured on open, because closing marks everything seen.
    @State private var seenBefore = Int.max

    var body: some View {
        let groups = JournalRules.group(model.journal.events.filter { filter.includes($0.kind) })
        let days = Dictionary(grouping: groups) { group in
            Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(group.date)))
        }.sorted { $0.key > $1.key }

        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Journal").font(.system(size: 20, weight: .bold))
                    Text("Every first time of your Mac on the network")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Filter", selection: $filter) {
                    ForEach(JournalFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            if groups.isEmpty {
                ContentUnavailableView {
                    Label("Nothing yet", systemImage: "sparkles")
                } description: {
                    Text("Orbite notes every first time here: an app that connects, a new domain, a new country, an unusual volume.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(days, id: \.key) { day, groups in
                        Section(Format.dayHeader(day)) {
                            ForEach(groups) { group in
                                Button {
                                    JournalNavigator.open(group, model: model)
                                    dismiss()
                                } label: {
                                    JournalRow(group: group, unseen: group.date > seenBefore)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()

            HStack {
                Text("Kept 30 days, on this Mac only")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 580, height: 640)
        .scrollIndicators(.never)
        .onAppear { seenBefore = model.journal.lastVisit }
        .onDisappear { model.journal.markSeen() }
    }
}

enum JournalFilter: String, CaseIterable, Identifiable {
    case all, apps, domains, countries, unusual
    var id: Self { self }

    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .apps: String(localized: "Apps")
        case .domains: String(localized: "Domains")
        case .countries: String(localized: "Countries")
        case .unusual: String(localized: "Unusual")
        }
    }

    func includes(_ kind: JournalEvent.Kind) -> Bool {
        switch self {
        case .all: true
        case .apps: kind == .newApp
        case .domains: kind == .newDomain
        case .countries: kind == .newCountry
        case .unusual: kind == .unusual || kind == .whileAway
        }
    }
}

/// One journal line: the app's icon with a badge for the kind, the sentence, the time.
struct JournalRow: View {
    @Environment(AppModel.self) private var model
    let group: JournalGroup
    var unseen = false
    var compact = false

    var body: some View {
        let size: CGFloat = compact ? 24 : 30
        HStack(alignment: .center, spacing: 10) {
            icon(size: size)
                .overlay(alignment: .bottomTrailing) {
                    if group.latest.appID != nil, group.kind != .newApp {
                        Image(systemName: Self.symbol(group))
                            .font(.system(size: size * 0.28, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: size * 0.5, height: size * 0.5)
                            .background(Self.color(group).gradient, in: Circle())
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                            .offset(x: 4, y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = group.subtitle {
                    Text(subtitle)
                        .font(.system(size: compact ? 10.5 : 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(compact ? Format.ago(Date(timeIntervalSince1970: TimeInterval(group.date)))
                     : Format.time(Date(timeIntervalSince1970: TimeInterval(group.date))))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if unseen {
                    Circle().fill(Theme.download).frame(width: 7, height: 7)
                }
            }
        }
        .padding(.vertical, compact ? 2 : 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func icon(size: CGFloat) -> some View {
        if let id = group.latest.appID, let app = model.store.apps[id] {
            AppIconView(identity: app.identity, size: size)
        } else {
            SymbolIcon(symbol: Self.symbol(group), size: size, colors: [Self.color(group).opacity(0.85), Self.color(group)])
        }
    }

    static func symbol(_ group: JournalGroup) -> String {
        switch group.kind {
        case .newApp: "sparkles"
        case .newDomain: "globe"
        case .newCountry: "flag.fill"
        case .unusual: group.latest.subject == "up" ? "arrow.up" : "arrow.down"
        case .whileAway: "moon.zzz.fill"
        case .recapReady: "chart.bar.fill"
        }
    }

    static func color(_ group: JournalGroup) -> Color {
        switch group.kind {
        case .newApp: .orange
        case .newDomain: Theme.download
        case .newCountry: .green
        case .unusual: group.latest.subject == "up" ? Theme.upload : Theme.download
        case .whileAway: .indigo
        case .recapReady: .purple
        }
    }
}

/// Shows what an event is about: selects its app or domain and moves the window to its hour.
enum JournalNavigator {
    static func open(_ group: JournalGroup, model: AppModel) {
        let store = model.store
        let event = group.latest
        if event.kind == .recapReady {
            withAnimation(.smooth(duration: 0.4)) { model.ui.showRecap = true }
            return
        }
        if let appID = event.appID, store.apps[appID] != nil {
            var selection = Selection.app(appID)
            if event.kind == .newDomain, group.events.count == 1, let domain = event.subject,
               store.apps[appID]?.hosts[domain] != nil {
                selection = .host("\(appID)|\(domain)")
            }
            withAnimation(Theme.selection) {
                model.ui.selection = selection
                model.ui.expanded.insert(appID)
            }
        } else {
            model.ui.selection = nil
        }
        if let window = window(for: event, now: store.now) { store.window = window }
    }

    /// The hour (or the day, for a long absence) of the event; nil when the history no longer covers it.
    static func window(for event: JournalEvent, now: Int) -> TimeWindow? {
        let earliest = now - TrafficBuckets.hourHorizon + 86_400
        guard event.date >= earliest else { return nil }
        let span: WindowSpan = (event.duration ?? 0) > 3600 ? .day : .hour
        let end = TimeNavigation.align(event.date, span: span) + span.seconds
        return TimeWindow(span: span, end: end >= now ? nil : end)
    }
}

/// « Quoi de neuf » at the top of the overview: what happened since the window was last closed.
struct WhatsNewSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let unseen = model.journal.unseen
        if !unseen.isEmpty {
            let groups = JournalRules.group(unseen)
            InspectorSection("What's new since your last visit") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups.prefix(4)) { group in
                        Button {
                            JournalNavigator.open(group, model: model)
                        } label: {
                            JournalRow(group: group, compact: true)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(groups.count > 4 ? "See All (\(groups.count))" : "Open the Journal") {
                        model.ui.showJournal = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.download)
                }
            }
        }
    }
}
