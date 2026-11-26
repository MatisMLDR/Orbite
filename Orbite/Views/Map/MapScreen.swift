import SwiftUI

/// The map with its floating glass HUD, status banners and the welcome card.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    /// How the stage glides to where it belongs; nil before the first layout.
    @State private var motion: Motion?
    /// The glide still runs: the globe and the bar are drawn on every frame until it lands.
    @State private var gliding = false
    @State private var landing: Task<Void, Never>?
    /// When the map was first laid out: while the window opens, the panels land in big steps that are not moves.
    @State private var laidOut: Date?
    /// Ideal widths of the bottom bar's wider variants, measured once each.
    @State private var barWidths: [BarWidth: CGFloat] = [:]

    /// Where the globe and the bottom bar are centred: `shift` points right of the middle of the whole map.
    private struct Stage: Equatable {
        var look: MapLook
        var shift: CGFloat
    }

    /// The stage's glide, on one look: a change of look puts it in place at once.
    private struct Motion {
        var look: MapLook
        var glide: Glide
    }

    private enum BarWidth: Hashable {
        case hud(MapHUD.Level, live: Bool)
        case replay
    }

    var body: some View {
        // The map runs under the floating sidebar, the inspector and the toolbar. On the globe, the Earth and
        // the bottom bar sit in the middle of the part the panels leave free; on the flat maps the bar sits at
        // the middle of the window. Either way the bar only takes the width that fits on both sides of its
        // centre without reaching a panel. Both glide there, trailing the panels a little as they slide.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let width = proxy.size.width + insets.leading + insets.trailing
            let target = stageTarget(proxy)
            let (glide, running) = shownGlide(target)
            ZStack(alignment: .bottom) {
                ConnectionMapView(globeGlide: glide, globeGliding: running)
                // Drawn frame by frame on its own: the map's other layers stay as they are.
                TimelineView(.animation(paused: !running)) { context in
                    let shift = CGFloat(running ? glide.value(at: context.date.timeIntervalSinceReferenceDate) : glide.target)
                    let center = width / 2 + shift
                    let room = max(0, 2 * (min(center - insets.leading, width - insets.trailing - center) - 14))
                    bottomBar(room: room)
                        .frame(width: room)
                        .offset(x: shift)
                }
                .padding(.bottom, insets.bottom + 18)
            }
            .ignoresSafeArea()
            .onChange(of: target, initial: true) { follow(target) }
        }
        .overlay(alignment: .top) {
            StatusBanner()
                .padding(.horizontal, 14)
                .padding(.top, 12)
        }
        .overlay {
            if model.ui.showOnboarding {
                WelcomeCard()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.smooth(duration: 0.4), value: model.ui.showOnboarding)
    }
}

extension MapScreen {
    /// Where the stage belongs for this layout: `proxy` is the visible part of the map, its insets the
    /// panels and the toolbar over the rest.
    private func stageTarget(_ proxy: GeometryProxy) -> Stage {
        let look = model.ui.mapLook
        let insets = proxy.safeAreaInsets
        if look == .globe {
            return Stage(look: look, shift: (insets.leading - insets.trailing) / 2)
        }
        let visible = proxy.frame(in: .global)
        let middle = (visible.minX - insets.leading + visible.maxX + insets.trailing) / 2
        let window = model.ui.windowWidth
        return Stage(look: look, shift: window > 0 ? window / 2 - middle : 0)
    }

    /// The glide to draw for this layout, and whether it runs. A new target shows the glide as it was
    /// until `follow` aims it, so the stage never jumps there first.
    private func shownGlide(_ target: Stage) -> (Glide, Bool) {
        guard let motion, motion.look == target.look, !opening else {
            return (Glide(resting: Double(target.shift)), false)
        }
        return (motion.glide, gliding)
    }

    /// The window is still opening: the stage takes its place without gliding.
    private var opening: Bool {
        laidOut.map { Date.now.timeIntervalSince($0) < 1 } ?? true
    }

    /// Aims the glide at `target`. The panels slide frame by frame: aimed again on every step, the glide
    /// keeps its speed, trails them a little and lands softly once they stop. A panel that appears at once
    /// gives one long glide.
    private func follow(_ target: Stage) {
        if laidOut == nil { laidOut = .now }
        let now = Date.now.timeIntervalSinceReferenceDate
        guard let current = motion, current.look == target.look, !opening else {
            motion = Motion(look: target.look, glide: Glide(resting: Double(target.shift), at: now))
            landing?.cancel()
            gliding = false
            return
        }
        guard Double(target.shift) != current.glide.target else { return }
        let glide = current.glide.aimed(at: Double(target.shift), at: now)
        motion?.glide = glide
        if !gliding { gliding = true }
        landing?.cancel()
        landing = Task {
            try? await Task.sleep(for: .seconds(glide.end - now))
            guard !Task.isCancelled else { return }
            gliding = false
        }
    }

    /// The HUD, or the replay bar while the day replays, at the widest variant `room` holds. The change
    /// from one variant to another animates: the capsule grows or shrinks, what it adds or drops fades.
    @ViewBuilder fileprivate func bottomBar(room: CGFloat) -> some View {
        if let replay = model.replay {
            let compact = (barWidths[.replay] ?? 0) > room
            ReplayBar(replay: replay, compact: compact)
                .animation(.smooth(duration: 0.3), value: compact)
                .background { probe(.replay) { ReplayBar(replay: replay) } }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if !(ProcessInfo.processInfo.environment["ORBITE_HIDE"] ?? "").contains("hud") {
            let live = model.store.window.isLive
            let level: MapHUD.Level = if (barWidths[.hud(.full, live: live)] ?? 0) <= room {
                .full
            } else if (barWidths[.hud(.compact, live: live)] ?? 0) <= room {
                .compact
            } else {
                .minimal
            }
            MapHUD(level: level)
                .animation(.smooth(duration: 0.3), value: level)
                .background {
                    ZStack {
                        probe(.hud(.full, live: live)) { MapHUD(level: .full) }
                        probe(.hud(.compact, live: live)) { MapHUD(level: .compact) }
                    }
                }
        }
    }

    /// A hidden, inert copy of a variant whose width is not known yet, gone once measured. The width
    /// lands without animation: the first pick of a variant is not a change to show.
    @ViewBuilder private func probe<Variant: View>(_ key: BarWidth, @ViewBuilder _ variant: () -> Variant) -> some View {
        if barWidths[key] == nil {
            variant()
                .hidden()
                .disabled(true)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { barWidths[key] = width }
                }
        }
    }
}

/// Live totals floating over the map. Every field has a fixed width: a HUD that changes size
/// every second makes AppKit lay out the whole window again. Narrower levels drop the sparkline,
/// then the words, then the counts, as the side panels leave less room.
struct MapHUD: View {
    enum Level { case full, compact, minimal }

    @Environment(AppModel.self) private var model
    var level: Level = .full

    var body: some View {
        let store = model.store
        let _ = store.tick
        let rate = store.totalRate
        let live = store.window.isLive

        HStack(spacing: level == .full ? 14 : 11) {
            Button {
                model.startReplay()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Replay the day on the map")
            if live {
                hudRate(.up, rate.outPerSecond)
                hudRate(.down, rate.inPerSecond)
                if level == .full {
                    RateSparkline(rates: store.recentRates)
                        .frame(width: 64, height: 22)
                        .drawingGroup()
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                    Text(Format.window(store.window, now: store.now))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: level == .full ? 230 : 180, alignment: .leading)
            }
            if level != .minimal {
                Divider().frame(height: 16)
                if level == .full {
                    // English words run longer: « places », « countries ».
                    let french = Format.isFrench
                    stat(Format.plural(store.activeConnections, "connection", "connections"),
                         symbol: "point.3.connected.trianglepath.dotted", width: french ? 112 : 124)
                        .opacity(live ? 1 : 0.5)
                    stat(Format.plural(store.visibleSites.count, "place", "places"), symbol: "mappin.and.ellipse",
                         width: french ? 72 : 84)
                    stat(Format.plural(store.countryCount, "country", "countries"), symbol: "flag", width: french ? 64 : 100)
                } else {
                    stat(Format.count(store.activeConnections), symbol: "point.3.connected.trianglepath.dotted", width: 46)
                        .opacity(live ? 1 : 0.5)
                        .help(Format.plural(store.activeConnections, "connection", "connections"))
                    stat(Format.count(store.visibleSites.count), symbol: "mappin.and.ellipse", width: 40)
                        .help(Format.plural(store.visibleSites.count, "place", "places"))
                    stat(Format.count(store.countryCount), symbol: "flag", width: 36)
                        .help(Format.plural(store.countryCount, "country", "countries"))
                }
            }
        }
        .font(.system(size: 12.5, weight: .semibold))
        .monospacedDigit()
        .padding(.horizontal, level == .full ? 18 : 14)
        .frame(height: 40)
        // A material, not Liquid Glass: glass over a live map is re-rendered on the CPU.
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .fixedSize()
    }

    private func hudRate(_ direction: Direction, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: direction.symbol)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(direction.color)
            Text(Format.rate(value))
                .lineLimit(1)
        }
        .frame(width: 92, alignment: .leading)
    }

    private func stat(_ text: String, symbol: String, width: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Glass banner for what needs attention: no GeoIP database, download progress, capture errors.
private struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let error = model.store.streamError {
                banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error)
            } else if !model.ui.showOnboarding {
                switch model.geo.phase {
                case .missing:
                    banner(symbol: "globe.badge.chevron.backward", tint: .accentColor,
                           text: String(localized: "Places will show once the geolocation database is installed.")) {
                        Button("Download") { Task { await model.geo.download() } }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                    }
                case .downloading(let fraction):
                    banner(symbol: "arrow.down.circle", tint: .accentColor,
                           text: String(localized: "Geolocation database: \(Format.percent(fraction))")) {
                        ProgressView(value: fraction).frame(width: 90)
                    }
                case .failed(let message):
                    banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: message) {
                        Button("Try Again") { Task { await model.geo.download() } }
                            .controlSize(.small)
                    }
                case .ready:
                    if let warning = openNetworkWarning() {
                        banner(symbol: "lock.open.fill", tint: Theme.plaintext, text: warning)
                    }
                }
            }
        }
        .animation(.smooth, value: model.geo.phase)
    }

    /// On an open (or WEP) Wi-Fi, anyone nearby can read what travels unencrypted: say who does.
    private func openNetworkWarning() -> String? {
        guard let security = model.network.wifi?.security, NetworkInfo.isWeak(security) else { return nil }
        let store = model.store
        let _ = store.tick
        let since = store.now - 300
        let apps = store.apps.values.filter { app in
            app.hosts.values.contains { $0.hasRiskyPlaintext && ($0.plaintextLastSeen ?? 0) >= since }
        }
        guard !apps.isEmpty else { return nil }
        let names = apps.map(\.identity.name).sorted().prefix(3).joined(separator: ", ")
        let kind = security == "WEP" ? String(localized: "Poorly protected Wi-Fi") : String(localized: "Open Wi-Fi")
        return String(localized: "\(kind): \(Format.plural(apps.count, "app talks", "apps talk")) in clear text (\(names))")
    }

    private func banner(symbol: String, tint: Color, text: String) -> some View {
        banner(symbol: symbol, tint: tint, text: text) { EmptyView() }
    }

    private func banner<Accessory: View>(symbol: String, tint: Color, text: String,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 14, weight: .semibold))
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(2)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
