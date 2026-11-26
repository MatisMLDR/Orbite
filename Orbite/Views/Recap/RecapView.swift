import AppKit
import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

/// « Bilan de la semaine »: the last seven days in a few cards, and an image of it to share.
struct RecapView: View {
    @Environment(AppModel.self) private var model
    @State private var recap: Recap?
    @State private var shareImage: NSImage?
    @State private var rendering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your week on the network").font(.system(size: 24, weight: .bold))
                        if let recap {
                            Text(RecapText.range(recap))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { close() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 26)
                .padding(.top, 22)
                .padding(.bottom, 14)

                ScrollView {
                    if let recap {
                        RecapCards(recap: recap)
                            .padding(.horizontal, 26)
                            .padding(.bottom, 20)
                    } else {
                        ProgressView().padding(60)
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    Text("Worked out on this Mac, from Orbite's history")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if rendering { ProgressView().controlSize(.small) }
                    Button("Copy Image") { withImage { image in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    } }
                    Button("Save Image…") { withImage(save) }
                    ShareButton(image: shareImage, prepare: prepareImage)
                }
                .disabled(recap == nil)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
            }
            .frame(width: 680, height: 640)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .shadow(color: .black.opacity(0.22), radius: 30, y: 10)
        }
        .task { recap = RecapBuilder.make(model: model) }
    }

    private func close() {
        withAnimation(.smooth(duration: 0.4)) { model.ui.showRecap = false }
    }

    private func withImage(_ use: @escaping (NSImage) -> Void) {
        if let shareImage { use(shareImage); return }
        Task {
            await prepareImage()
            if let shareImage { use(shareImage) }
        }
    }

    private func prepareImage() async {
        guard shareImage == nil, let recap, !rendering else { return }
        rendering = true
        shareImage = await RecapImage.render(recap: recap, model: model)
        rendering = false
    }

    private func save(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Orbite-recap-\(Date().formatted(.iso8601.year().month().day())).png")
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url,
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }
}

/// The share menu, fed once the image is drawn.
private struct ShareButton: View {
    let image: NSImage?
    let prepare: () async -> Void

    var body: some View {
        if let image {
            ShareLink(item: Image(nsImage: image), preview: SharePreview("My week on the network", image: Image(nsImage: image))) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                Task { await prepare() }
            } label: {
                Label("Prepare to Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// The figures as tiles.
struct RecapCards: View {
    @Environment(AppModel.self) private var model
    let recap: Recap

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        VStack(alignment: .leading, spacing: 12) {
            Tile(symbol: "arrow.up.arrow.down", tint: Theme.download, title: "Exchanged") {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Format.bytes(recap.total.total)).font(.system(size: 30, weight: .bold)).monospacedDigit()
                    if let change = recap.change {
                        Text(RecapText.change(change))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(change > 0 ? Theme.upload : Theme.live)
                    }
                }
                Text("↑ \(Format.bytes(recap.total.bytesOut)) sent · ↓ \(Format.bytes(recap.total.bytesIn)) received")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            if !recap.topApps.isEmpty {
                Tile(symbol: "trophy.fill", tint: .orange, title: "Apps of the week") {
                    let top = Double(recap.topApps.first?.bytes ?? 1)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(recap.topApps.enumerated()), id: \.element.id) { index, app in
                            HStack(spacing: 8) {
                                Text("\(index + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).frame(width: 14)
                                if let identity = model.store.apps[app.id]?.identity { AppIconView(identity: identity, size: 20) }
                                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(Format.bytes(app.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ShareBar(fraction: Double(app.bytes) / max(top, 1), color: .orange)
                        }
                    }
                }
            }

            LazyVGrid(columns: columns, spacing: 12) {
                Tile(symbol: "globe.europe.africa.fill", tint: .green, title: "The world") {
                    Text(Format.plural(recap.countryCount, "country", "countries")).font(.system(size: 22, weight: .bold))
                    if let far = recap.farthest {
                        Text("Farthest: \(Format.flag(far.countryCode)) \(far.title), \(Format.distance(kilometers: far.distanceKm)) away")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Tile(symbol: "sparkles", tint: .purple, title: "New") {
                    Text(Format.plural(recap.domainCount, "domain", "domains")).font(.system(size: 22, weight: .bold))
                    Text(RecapText.news(recap)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Tile(symbol: "hand.raised.fill", tint: Theme.tracker, title: "Privacy") {
                    if let share = recap.trackerShare {
                        Text(Format.percent(share)).font(.system(size: 22, weight: .bold))
                        Text(recap.topTrackerOwner.map { String(localized: "of bytes to trackers, mostly \($0)") } ?? String(localized: "of bytes to trackers"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("—").font(.system(size: 22, weight: .bold))
                        Text("Tracker list missing").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Tile(symbol: "clock.fill", tint: Theme.download, title: "The busiest time") {
                    Text(RecapText.busiestDay(recap)).font(.system(size: 18, weight: .bold))
                    if let hour = recap.busiestHour {
                        Text("Peak hour: \(Format.hour(hour)) – \(Format.hour(hour + 1))").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Tile(symbol: "wifi", tint: .teal, title: "Networks") {
                    Text(Format.plural(recap.networks.count, "network", "networks")).font(.system(size: 22, weight: .bold))
                    Text(recap.networks.prefix(3).map(\.name).joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    if recap.mobile > 0 {
                        Text("\(Format.bytes(recap.mobile)) on mobile data").font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }
                Tile(symbol: "moon.stars.fill", tint: .indigo, title: "Night owl") {
                    if let owl = recap.nightOwl {
                        Text(owl.name).font(.system(size: 18, weight: .bold)).lineLimit(1)
                        Text("\(Format.bytes(owl.bytes)) between midnight and 6 AM").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text("Nobody").font(.system(size: 18, weight: .bold))
                        Text("Quiet nights this week").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct Tile<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
            content
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .padding(14)
        .background(Theme.sectionFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Sentences of the recap.
enum RecapText {
    static func range(_ recap: Recap) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(recap.start))
        let end = Date(timeIntervalSince1970: TimeInterval(recap.end - 1))
        let from = start.formatted(.dateTime.day().month(.wide).locale(Format.locale))
        let to = end.formatted(.dateTime.day().month(.wide).locale(Format.locale))
        return String(localized: "From \(from) to \(to)")
    }

    static func change(_ change: Double) -> String {
        let percent = Int((abs(change) * 100).rounded())
        return change >= 0 ? String(localized: "+\(percent)% vs the week before") : String(localized: "−\(percent)% vs the week before")
    }

    static func news(_ recap: Recap) -> String {
        var parts: [String] = []
        if recap.newApps > 0 { parts.append(Format.plural(recap.newApps, "new app", "new apps")) }
        if recap.newDomains > 0 { parts.append(Format.plural(recap.newDomains, "new domain", "new domains")) }
        if recap.newCountries > 0 { parts.append(Format.plural(recap.newCountries, "new country", "new countries")) }
        return parts.isEmpty ? String(localized: "Nothing new in the journal") : parts.joined(separator: ", ")
    }

    static func busiestDay(_ recap: Recap) -> String {
        guard let day = recap.busiestDay else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(day.start))
        let name = date.formatted(.dateTime.weekday(.wide).locale(Format.locale)).capitalizedFirstLetter
        return "\(name) · \(Format.bytes(day.bytes))"
    }
}

/// Gathers the week from the store, the journal, the networks and the tracker summary.
enum RecapBuilder {
    static func make(model: AppModel) -> Recap {
        let store = model.store
        let now = store.now
        let start = now - 7 * 86_400
        let home = model.home.coordinate
        let apps = store.apps.values.map { RecapInput.App(id: $0.id, name: $0.identity.name, hours: $0.stats.buckets.hours) }
        let places = store.sites.values.map { site in
            RecapInput.Place(title: site.title, countryCode: site.place.countryCode, country: site.place.country,
                             distanceKm: GeoMath.distanceKm(home, site.coordinate),
                             bytes: site.stats.buckets.sum(from: start, to: now + 1, now: now).total)
        }
        var domains = Set<String>()
        var trackerItems: [(tracker: TrackerInfo?, bytes: UInt64)] = []
        for app in store.apps.values {
            for host in app.hosts.values {
                let bytes = host.stats.buckets.sum(from: start, to: now + 1, now: now).total
                guard bytes > 0 else { continue }
                if host.kind == .domain { domains.insert(host.label) }
                trackerItems.append((host.tracker, bytes))
            }
        }
        let trackers = TrackerSummary.make(trackerItems)
        let events = model.journal.events.filter { $0.date >= start }
        let ledger = model.networks.ledger
        let today = model.networks.dayIndex(for: now)
        // The week before counts only when the ledger saw all of it.
        let previous: Traffic? = {
            guard let first = ledger.globalDays.keys.min(), first <= today - 13 else { return nil }
            return ledger.globalDays.filter { $0.key >= today - 13 && $0.key <= today - 7 }.values.reduce(.zero, +)
        }()
        let networks = ledger.networks.values.map {
            RecapInput.Network(name: $0.name, bytes: $0.buckets.sum(from: start, to: now + 1, now: now).total)
        }
        let input = RecapInput(
            start: start, end: now + 1, global: store.global.buckets.hours, previousWeek: previous, apps: apps,
            places: places, domainCount: domains.count,
            trackerShare: model.trackers.phase == .missing ? nil : trackers.share,
            topTrackerOwner: trackers.owners.first?.name,
            newApps: events.filter { $0.kind == .newApp }.count,
            newDomains: events.filter { $0.kind == .newDomain }.count,
            newCountries: events.filter { $0.kind == .newCountry }.count,
            networks: networks,
            mobile: ledger.mobileUsage(fromDay: model.networks.dayIndex(for: start), toDay: today).total.total)
        return Recap.make(input)
    }
}

/// The square card to share: the globe with the week's arcs, and the headline figures.
enum RecapImage {
    static let size = CGSize(width: 600, height: 760)

    static func render(recap: Recap, model: AppModel) async -> NSImage? {
        let store = model.store
        let now = store.now
        let home = model.home.coordinate
        let globeSize = CGSize(width: 520, height: 400)
        let camera = GlobeCamera(latitude: min(70, max(-70, home.latitude)), longitude: home.longitude, radius: 190)
        let texture = await GlobeTexture.load(dark: true)
        let sun = GlobeProjection.unit(GeoMath.subsolarPoint(at: .now))
        let globe = await GlobeSnapshot.render(camera: camera, size: globeSize, scale: 2, texture: texture, dark: true,
                                               light: sun, dayNight: false)
        let places = store.sites.values
            .map { ($0, $0.stats.buckets.sum(from: recap.start, to: recap.end, now: now).total) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(60)
            .map(\.0.coordinate)
        let card = RecapShareCard(recap: recap, globe: globe, camera: camera, globeSize: globeSize, home: home,
                                  places: Array(places))
            .environment(model)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card.frame(width: size.width, height: size.height))
        renderer.scale = 2
        return renderer.nsImage
    }
}

private struct RecapShareCard: View {
    let recap: Recap
    let globe: CGImage?
    let camera: GlobeCamera
    let globeSize: CGSize
    let home: CLLocationCoordinate2D
    let places: [CLLocationCoordinate2D]

    var body: some View {
        let projection = GlobeProjection(camera: camera, size: globeSize)
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("My week on the network").font(.system(size: 28, weight: .bold))
                Text(RecapText.range(recap)).font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 34)
            ZStack {
                if let globe {
                    Image(decorative: globe, scale: 2)
                        .resizable()
                        .frame(width: globeSize.width, height: globeSize.height)
                }
                Canvas { context, _ in
                    let line = Color(red: 0.42, green: 0.78, blue: 0.98)
                    for place in places {
                        for run in projection.runs(GlobeProjection.flightArc(home, place)) where run.front {
                            var path = Path()
                            path.addLines(run.points)
                            context.stroke(path, with: .color(line.opacity(0.85)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        }
                        if let end = projection.project(place) {
                            context.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)), with: .color(.white))
                        }
                    }
                    if let point = projection.project(home) {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)), with: .color(Theme.upload))
                        context.stroke(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)), with: .color(.white), lineWidth: 2)
                    }
                }
                .frame(width: globeSize.width, height: globeSize.height)
            }
            HStack(spacing: 0) {
                figure(Format.bytes(recap.total.total), "exchanged")
                figure("\(recap.countryCount)", recap.countryCount == 1 ? "country" : "countries")
                figure("\(recap.domainCount)", "domains")
                if let share = recap.trackerShare { figure(Format.percent(share), "to trackers") }
            }
            if let top = recap.topApps.first {
                Text("No. 1 app: \(top.name) · \(Format.bytes(top.bytes))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 0)
            Text("Orbite · everything stays on my Mac")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.bottom, 22)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.18), Color(red: 0.01, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom))
    }

    private func figure(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 24, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }
}
