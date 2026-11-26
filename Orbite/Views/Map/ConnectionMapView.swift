import AppKit
import MapKit
import SwiftUI

/// What the map draws, reduced to values: the Map is only rebuilt when one of them changes,
/// not on every nettop sample (MapKit rasterizes annotations on the CPU).
struct MapScene: Equatable {
    struct Line: Equatable, Identifiable {
        let id: String
        let latitude: Double
        let longitude: Double
        let width: CGFloat
        let emphasized: Bool
        let glowing: Bool
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    struct Marker: Equatable, Identifiable {
        let id: String
        let title: String
        let latitude: Double
        let longitude: Double
        let active: Bool
        let dimmed: Bool
        let selected: Bool
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    var homeLatitude: Double
    var homeLongitude: Double
    var homeActive: Bool
    var lines: [Line]
    var markers: [Marker]
    var look: MapLook
    /// Changes when labels must be placed again (places, selection, highlight).
    var layoutKey: String
    /// Traffic weights for label priority; not part of equality (they move every second).
    var weights: [String: Double]

    var home: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: homeLatitude, longitude: homeLongitude) }

    static func == (lhs: MapScene, rhs: MapScene) -> Bool {
        lhs.homeLatitude == rhs.homeLatitude && lhs.homeLongitude == rhs.homeLongitude
            && lhs.homeActive == rhs.homeActive && lhs.lines == rhs.lines && lhs.markers == rhs.markers
            && lhs.look == rhs.look && lhs.layoutKey == rhs.layoutKey
    }

    static let maxPlaces = 260

    @MainActor
    static func make(store: TrafficStore, selection: Selection?, home: CLLocationCoordinate2D, look: MapLook) -> MapScene {
        let now = store.now
        var weights: [String: Double] = [:]
        let sites = store.visibleSites
        for site in sites {
            weights[site.id] = Double(site.window.total) + site.rate.total * 120 + Double(site.connections) * 2000
        }
        let kept = sites.sorted { weights[$0.id, default: 0] > weights[$1.id, default: 0] }.prefix(maxPlaces)
        let highlighted = store.siteIDs(for: selection)
        let selected: String? = if case .site(let id) = selection { id } else { nil }

        var lines: [Line] = []
        var markers: [Marker] = []
        var anyActive = false
        for site in kept.sorted(by: { $0.id < $1.id }) {
            // Active = bytes in the last 3 seconds, so the flag does not flicker between samples.
            let active = now - site.lastSeen <= 3 && store.window.isLive
            anyActive = anyActive || active
            let emphasized = highlighted?.contains(site.id) ?? true
            lines.append(Line(id: site.id, latitude: site.place.latitude, longitude: site.place.longitude,
                              width: lineWidth(site.window.total), emphasized: emphasized, glowing: active && emphasized))
            // A Private Relay ingress is not where the bytes end up: say so on the label.
            let relayOnly = site.labels.count == 1 && site.labels.contains(SpecialHosts.privateRelayLabel)
            markers.append(Marker(id: site.id, title: relayOnly ? String(localized: "Relay · \(site.title)") : site.title,
                                  latitude: site.place.latitude,
                                  longitude: site.place.longitude, active: active, dimmed: !emphasized,
                                  selected: site.id == selected))
        }
        let layoutKey = markers.map(\.id).joined(separator: ",") + "|\(selected ?? "")|\(highlighted.map { $0.sorted().joined(separator: ",") } ?? "*")"
        return MapScene(homeLatitude: home.latitude, homeLongitude: home.longitude, homeActive: anyActive,
                        lines: lines, markers: markers, look: look, layoutKey: layoutKey, weights: weights)
    }

    /// The map at one moment of the replayed day: the places of the last 15 minutes, glowing where bytes flow.
    @MainActor
    static func make(replay: ReplayController, store: TrafficStore, selection: Selection?, home: CLLocationCoordinate2D,
                     look: MapLook) -> MapScene {
        let places = replay.timeline.places(at: replay.slot)
        var weights: [String: Double] = [:]
        for place in places { weights[place.id] = Double(place.trail.total) }
        let kept = places.sorted { $0.trail.total > $1.trail.total }.prefix(maxPlaces)
        let highlighted = store.siteIDs(for: selection)
        let selected: String? = if case .site(let id) = selection { id } else { nil }
        var lines: [Line] = []
        var markers: [Marker] = []
        for place in kept.sorted(by: { $0.id < $1.id }) {
            guard let site = store.sites[place.id] else { continue }
            let active = !place.now.isZero
            let emphasized = highlighted?.contains(site.id) ?? true
            lines.append(Line(id: site.id, latitude: site.place.latitude, longitude: site.place.longitude,
                              width: lineWidth(place.trail.total), emphasized: emphasized, glowing: active && emphasized))
            markers.append(Marker(id: site.id, title: site.title, latitude: site.place.latitude,
                                  longitude: site.place.longitude, active: active, dimmed: !emphasized,
                                  selected: site.id == selected))
        }
        let layoutKey = markers.map(\.id).joined(separator: ",") + "|\(selected ?? "")"
        return MapScene(homeLatitude: home.latitude, homeLongitude: home.longitude,
                        homeActive: !(replay.timeline.global[safe: replay.slot]?.isZero ?? true),
                        lines: lines, markers: markers, look: look, layoutKey: layoutKey, weights: weights)
    }

    /// Quantized to half points: MapKit rebuilds an overlay whenever its style changes.
    static func lineWidth(_ bytes: UInt64) -> CGFloat {
        let total = Double(max(bytes, 1))
        let width = 2.2 + 3.6 * CGFloat(min(1, max(0, (log10(total) - 3) / 6)))
        return (width * 2).rounded() / 2
    }
}

struct ConnectionMapView: View {
    @Environment(AppModel.self) private var model
    /// Moves the globe sideways, gliding to the middle of the part the side panels leave free. The flat maps
    /// ignore it.
    var globeGlide = Glide(resting: 0)
    /// The glide still runs: the globe is drawn on every frame.
    var globeGliding = false

    @State private var position: MapCameraPosition = .automatic
    @State private var cameraVersion = 0
    @State private var isMoving = false
    @State private var didFrame = false
    @State private var cameraEpoch = 0

    var body: some View {
        let store = model.store
        let _ = store.tick
        let ui = model.ui
        let replay = model.replay
        let scene = replay.map { MapScene.make(replay: $0, store: store, selection: ui.selection, home: model.home.coordinate,
                                               look: ui.mapLook) }
            ?? MapScene.make(store: store, selection: ui.selection, home: model.home.coordinate, look: ui.mapLook)
        let highlighted = store.siteIDs(for: ui.selection)
        let flowLines: [FlowLine] = if !ui.showFlows {
            []
        } else if let replay {
            replayFlows(replay, home: scene.home, highlighted: highlighted)
        } else if store.window.isLive {
            flows(home: scene.home, highlighted: highlighted)
        } else {
            []
        }

        if ui.mapLook == .globe {
            GlobeMapView(glide: globeGlide, gliding: globeGliding, scene: scene, flows: flowLines,
                         focus: highlighted, recenterRequest: ui.recenterRequest,
                         dayNight: ui.globeDayNight, sunDate: replay?.date, onSelect: select, onHome: clearSelection)
        } else {
            flatMap(scene, flows: flowLines)
        }
    }

    /// Comets of the replayed moment, at the slot's average rates.
    private func replayFlows(_ replay: ReplayController, home: CLLocationCoordinate2D, highlighted: Set<String>?) -> [FlowLine] {
        let seconds = Double(ReplayTimeline.slotSeconds)
        return replay.timeline.places(at: replay.slot)
            .filter { !$0.now.isZero }
            .sorted { $0.now.total > $1.now.total }
            .prefix(40)
            .compactMap { place in
                guard let site = model.store.sites[place.id] else { return nil }
                return FlowLine(id: site.id, from: home, to: site.coordinate,
                                up: Double(place.now.bytesOut) / seconds, down: Double(place.now.bytesIn) / seconds,
                                emphasized: highlighted?.contains(site.id) ?? true)
            }
    }

    private func flatMap(_ scene: MapScene, flows flowLines: [FlowLine]) -> some View {
        let store = model.store
        let ui = model.ui
        return MapReader { proxy in
            MapSceneView(scene: scene, proxy: proxy, cameraVersion: cameraVersion,
                         position: $position, isMoving: $isMoving, cameraEpoch: $cameraEpoch,
                         onSelect: select, onHome: clearSelection)
                .equatable()
                .overlay {
                    if !flowLines.isEmpty && !isMoving {
                        FlowLayer(flows: flowLines, cameraEpoch: cameraEpoch) { flow in
                            FlowPathCache.surfacePath(flow) { proxy.convert($0, to: .local) }
                        }
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: isMoving)
        }
        .onAppear {
            if !didFrame {
                setCamera(.region(MKCoordinateRegion(center: scene.home, span: MKCoordinateSpan(latitudeDelta: 38, longitudeDelta: 60))))
            }
        }
        .onChange(of: scene.markers.isEmpty, initial: true) {
            if !didFrame, !scene.markers.isEmpty {
                didFrame = true
                frame(scene, only: nil, animated: false)
            }
        }
        .onChange(of: ui.recenterRequest) {
            frame(scene, only: store.siteIDs(for: ui.selection), animated: true)
        }
    }

    /// A click on the Mac: the overview, in the inspector.
    private func clearSelection() {
        withAnimation(Theme.selection) {
            model.ui.selection = nil
            model.ui.showInspector = true
        }
    }

    private func select(_ id: String) {
        withAnimation(Theme.selection) {
            model.ui.selection = model.ui.selection == .site(id) ? nil : .site(id)
            model.ui.showInspector = true
        }
    }

    private func setCamera(_ camera: MapCameraPosition, animated: Bool = false) {
        cameraVersion += 1
        if animated {
            withAnimation(.smooth(duration: 0.9)) { position = camera }
        } else {
            position = camera
        }
    }

    private func flows(home: CLLocationCoordinate2D, highlighted: Set<String>?) -> [FlowLine] {
        model.store.visibleSites
            .filter(\.rate.isActive)
            .sorted { $0.rate.total > $1.rate.total }
            .prefix(40)
            .map { site in
                FlowLine(id: site.id, from: home, to: site.coordinate,
                         up: site.rate.outPerSecond, down: site.rate.inPerSecond,
                         emphasized: highlighted?.contains(site.id) ?? true)
            }
    }

    /// Fits the Mac and the places (those of the selection when there is one).
    private func frame(_ scene: MapScene, only ids: Set<String>?, animated: Bool) {
        var markers = scene.markers
        if let ids {
            let focused = markers.filter { ids.contains($0.id) }
            if !focused.isEmpty { markers = focused }
        }
        markers.sort { scene.weights[$0.id, default: 0] > scene.weights[$1.id, default: 0] }
        var rect = MKMapRect(origin: MKMapPoint(scene.home), size: MKMapSize(width: 0, height: 0))
        for marker in markers.prefix(80) {
            rect = rect.union(MKMapRect(origin: MKMapPoint(marker.coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        let minimum = MKMapPointsPerMeterAtLatitude(scene.homeLatitude) * 1_400_000
        if rect.size.width < minimum {
            rect = rect.insetBy(dx: -(minimum - rect.size.width) / 2, dy: 0)
        }
        if rect.size.height < minimum * 0.6 {
            rect = rect.insetBy(dx: 0, dy: -(minimum * 0.6 - rect.size.height) / 2)
        }
        rect = rect.insetBy(dx: -rect.size.width * 0.16, dy: -rect.size.height * 0.22)
        setCamera(.rect(rect), animated: animated)
    }
}

/// The MapKit map itself. Equatable on the scene: SwiftUI skips it while nothing visible changed.
private struct MapSceneView: View, Equatable {
    @Environment(\.colorScheme) private var scheme
    let scene: MapScene
    let proxy: MapProxy
    let cameraVersion: Int
    @Binding var position: MapCameraPosition
    @Binding var isMoving: Bool
    @Binding var cameraEpoch: Int
    let onSelect: (String) -> Void
    let onHome: () -> Void

    @State private var placements: [String: Declutter.Placement] = [:]
    @State private var moveSettle: Task<Void, Never>?
    @State private var mapSize: CGSize = .zero

    nonisolated static func == (lhs: MapSceneView, rhs: MapSceneView) -> Bool {
        MainActor.assumeIsolated { lhs.scene == rhs.scene && lhs.cameraVersion == rhs.cameraVersion }
    }

    var body: some View {
        let lineColor = Theme.line(scheme, look: scene.look)
        let glowColor = Theme.lineGlow(scheme, look: scene.look)
        let home = scene.home

        Map(position: $position, interactionModes: .all) {
            ForEach(scene.lines) { line in
                if line.glowing {
                    MapPolyline(coordinates: [home, line.coordinate], contourStyle: .geodesic)
                        .stroke(glowColor.opacity(0.22), style: StrokeStyle(lineWidth: line.width + 6, lineCap: .round))
                }
                MapPolyline(coordinates: [home, line.coordinate], contourStyle: .geodesic)
                    .stroke(lineColor.opacity(line.emphasized ? 0.82 : 0.1),
                            style: StrokeStyle(lineWidth: line.width, lineCap: .round))
            }

            ForEach(scene.markers) { marker in
                if placements[marker.id] == .dot || placements[marker.id] == nil {
                    Annotation(marker.title, coordinate: marker.coordinate, anchor: .center) {
                        SiteDot(active: marker.active, dimmed: marker.dimmed)
                            .onTapGesture { onSelect(marker.id) }
                            .help(marker.title)
                    }
                    .annotationTitles(.hidden)
                }
            }

            ForEach(scene.markers) { marker in
                if case .pill(let extra) = placements[marker.id] {
                    Annotation(marker.title, coordinate: marker.coordinate, anchor: .center) {
                        CityPill(title: marker.title, extra: extra, active: marker.active,
                                 selected: marker.selected, dimmed: marker.dimmed)
                            .onTapGesture { onSelect(marker.id) }
                    }
                    .annotationTitles(.hidden)
                }
            }

            Annotation("This Mac", coordinate: home, anchor: .center) {
                HomePin(active: scene.homeActive)
                    .onTapGesture(perform: onHome)
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(mapStyle(scene.look))
        .mapControls {
            MapCompass()
            MapScaleView()
            MapZoomStepper()
        }
        .onMapCameraChange(frequency: .continuous) { _ in
            if !isMoving { isMoving = true }
            moveSettle?.cancel()
            moveSettle = Task {
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                isMoving = false
            }
        }
        .onMapCameraChange(frequency: .onEnd) { _ in
            cameraEpoch += 1
            relayout()
        }
        .onChange(of: scene.layoutKey, initial: true) { relayout() }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            mapSize = size
            cameraEpoch += 1
            relayout()
        }
    }

    private func mapStyle(_ look: MapLook) -> MapStyle {
        switch look {
        // The globe is not a MapKit map (GlobeMapView): MapKit only makes globes of satellite imagery.
        case .standard, .globe: .standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false)
        case .muted: .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false)
        case .satellite: .imagery(elevation: .flat)
        case .hybrid: .hybrid(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false)
        }
    }

    /// Places labels in screen space: the heaviest places get pills, the others dots.
    private func relayout() {
        let result = Declutter.layout(scene, size: mapSize) { proxy.convert($0, to: .local) }
        if result != placements {
            withAnimation(.easeInOut(duration: 0.2)) { placements = result }
        }
    }
}

extension Declutter {
    /// Labels for a map of `size`: `project` gives a place's point in the view, nil when it cannot be seen.
    @MainActor
    static func layout(_ scene: MapScene, size: CGSize,
                       project: (CLLocationCoordinate2D) -> CGPoint?) -> [String: Placement] {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
        var items: [Item] = []
        var offscreen: [String] = []
        for marker in scene.markers {
            guard let point = project(marker.coordinate) else { continue }
            guard size == .zero || bounds.contains(point) else {
                offscreen.append(marker.id)
                continue
            }
            var weight = scene.weights[marker.id, default: 0]
            if marker.selected { weight = .infinity } else if !marker.dimmed { weight *= 1000 }
            items.append(Item(id: marker.id, point: point,
                              labelWidth: LabelMetrics.width(marker.title) + (marker.active ? 33 : 24),
                              weight: weight))
        }
        var obstacles: [CGRect] = []
        if let center = project(scene.home) {
            obstacles.append(CGRect(x: center.x - 27, y: center.y - 27, width: 54, height: 54))
        }
        var result = place(items, obstacles: obstacles)
        for id in offscreen { result[id] = .dot }
        return result
    }
}

/// Width of a city label in the pill font, cached.
enum LabelMetrics {
    private static var cache: [String: CGFloat] = [:]
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)

    static func width(_ text: String) -> CGFloat {
        if let cached = cache[text] { return cached }
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        cache[text] = width
        return width
    }
}
