import AppKit
import CoreLocation
import SwiftUI

/// Orbite's own globe, since MapKit only makes globes of satellite imagery: the Plan map on a sphere
/// (GlobeSurface), with the lines, places and flows of the flat maps drawn over it through GlobeProjection.
/// Drag or scroll to turn it, pinch or use the mouse wheel to zoom.
/// While the globe glides beside a side panel, it is drawn on every frame, so the Earth, the arcs and
/// the places move together.
struct GlobeMapView: View {
    @Environment(\.colorScheme) private var scheme
    /// Points from the middle of the view to the middle of the part the side panels leave free, along x,
    /// gliding there: where the globe's centre goes while the whole Earth shows. Zoomed in, it follows less
    /// and less. The camera sways with the glide's speed.
    var glide = Glide(resting: 0)
    /// The glide still runs.
    var gliding = false
    let scene: MapScene
    let flows: [FlowLine]
    /// Places to frame on « Recentrer » (those of the selection), nil for all.
    let focus: Set<String>?
    let recenterRequest: Int
    /// Light the globe by the real sun; otherwise a fixed light from the upper left and the Plan's colours.
    let dayNight: Bool
    /// The moment the sun is drawn for: the replayed time, or now.
    var sunDate: Date? = nil
    let onSelect: (String) -> Void
    let onHome: () -> Void

    @State private var camera: GlobeCamera?
    @State private var size: CGSize = .zero
    @State private var texture: CGImage?
    @State private var arcs = GlobeArcs()
    @State private var placements: [String: Declutter.Placement] = [:]
    @State private var isMoving = false
    @State private var epoch = 0
    @State private var settle: Task<Void, Never>?
    @State private var flight: Task<Void, Never>?
    @State private var dragged: CGSize = .zero
    @State private var didFrame = false
    /// Where the sun stands overhead, as a unit vector: lights the globe and casts the arcs' shadows.
    @State private var sun = GlobeProjection.unit(GeoMath.subsolarPoint(at: .now))

    var body: some View {
        // Zoomed in, the panels move nothing: nothing to draw again.
        TimelineView(.animation(paused: !gliding || follow == 0)) { context in
            let pose = pose(at: context.date)
            ZStack {
                backdrop(shift: pose.shift)
                if let camera = shownCamera(pose.sway), size.width > 0, size.height > 0 {
                    let projection = GlobeProjection(camera: camera, size: size, shift: pose.shift)
                    GlobeSurface(camera: camera, texture: texture, dark: scheme == .dark,
                                 light: dayNight ? sun : projection.viewLight, dayNight: dayNight, shift: pose.shift)
                        .allowsHitTesting(false)
                    lines(projection)
                    Group {
                        if !flows.isEmpty && !hidesFlows {
                            FlowLayer(flows: flows, cameraEpoch: epoch) { flow in
                                projection.flightPath(arcs.arc(flow.id, from: flow.from, to: flow.to).flight)
                            }
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: hidesFlows)
                    markers(projection)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(drag)
        .background { GlobeEventCatcher(onScroll: scroll, onMagnify: zoom) }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
        .onChange(of: scene.markers.isEmpty, initial: true) { frameFirstTime() }
        .onChange(of: recenterRequest) { frame(animated: true) }
        .onChange(of: scene.layoutKey) { relayout() }
        // Like a camera move: the flows hide while the globe glides, the labels settle once it lands.
        .onChange(of: gliding) {
            if gliding {
                if follow > 0 { isMoving = true }
            } else if isMoving {
                moved()
            }
        }
        .task {
            // The terminator moves a quarter of a degree a minute.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if sunDate == nil { sun = GlobeProjection.unit(GeoMath.subsolarPoint(at: .now)) }
            }
        }
        .onChange(of: sunDate) {
            sun = GlobeProjection.unit(GeoMath.subsolarPoint(at: sunDate ?? .now))
        }
        .task(id: scheme) {
            if let image = await GlobeTexture.load(dark: scheme == .dark) { texture = image }
        }
        .onDisappear {
            settle?.cancel()
            flight?.cancel()
        }
    }

    // MARK: Drawing

    private func backdrop(shift: CGFloat) -> some View {
        let colors: [Color] = scheme == .dark
            ? [Color(red: 0.08, green: 0.10, blue: 0.17), Color(red: 0.01, green: 0.015, blue: 0.035)]
            : [Color(red: 0.98, green: 0.99, blue: 1.0), Color(red: 0.83, green: 0.87, blue: 0.93)]
        // Centred on the globe, wherever the side panels push it.
        let center = UnitPoint(x: 0.5 + shift / max(size.width, 1), y: 0.5)
        return RadialGradient(colors: colors, center: center, startRadius: 0,
                              endRadius: max(size.width, size.height) * 0.75)
    }

    private struct ArcStroke {
        let line: MapScene.Line
        let front: Path
        let behind: Path
        let shadow: Path
        /// Where the arc lands, when that side of the Earth faces the viewer.
        let end: CGPoint?
    }

    /// Connection arcs flying above the globe: hidden behind the Earth, fainter where they pass behind
    /// its rim, with a faint shadow cast by the light (the sun, on its day side), further away as they climb.
    /// Each lands on a small dot, seen even when its place has no pill or dot of its own.
    private func lines(_ projection: GlobeProjection) -> some View {
        let lineColor = Theme.line(scheme, look: .globe)
        let glowColor = Theme.lineGlow(scheme, look: .globe)
        // A soft blue-grey shade rather than black, lighter on the colourful day map.
        let shadowColor = scheme == .dark
            ? Color(red: 0.0, green: 0.03, blue: 0.08).opacity(0.22)
            : Color(red: 0.08, green: 0.16, blue: 0.26).opacity(0.12)
        let strokes = scene.lines.compactMap { line -> ArcStroke? in
            let arc = arcs.arc(line.id, from: scene.home, to: line.coordinate)
            let runs = projection.runs(arc.flight)
            guard !runs.isEmpty else { return nil }
            var front = Path(), behind = Path(), shadow = Path()
            for run in runs {
                if run.front { front.addLines(run.points) } else { behind.addLines(run.points) }
            }
            if line.emphasized {
                for run in projection.shadowRuns(arc.flight, sun: dayNight ? sun : projection.viewLight) {
                    shadow.addLines(run)
                }
            }
            return ArcStroke(line: line, front: front, behind: behind, shadow: shadow,
                             end: projection.project(line.coordinate))
        }
        let radius = projection.camera.radius
        let disc = CGRect(x: projection.center.x - radius, y: projection.center.y - radius, width: radius * 2, height: radius * 2)
        return Canvas { context, _ in
            // Shadows fall on the Earth only.
            context.drawLayer { ground in
                ground.clip(to: Path(ellipseIn: disc))
                for stroke in strokes {
                    ground.stroke(stroke.shadow, with: .color(shadowColor),
                                  style: StrokeStyle(lineWidth: max(1, stroke.line.width * 0.6), lineCap: .round, lineJoin: .round))
                }
            }
            for stroke in strokes {
                let line = stroke.line
                let opacity = line.emphasized ? 0.82 : 0.1
                context.stroke(stroke.behind, with: .color(lineColor.opacity(opacity * 0.4)),
                               style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round))
                if line.glowing {
                    context.stroke(stroke.front, with: .color(glowColor.opacity(0.22)),
                                   style: StrokeStyle(lineWidth: line.width + 6, lineCap: .round, lineJoin: .round))
                }
                context.stroke(stroke.front, with: .color(lineColor.opacity(opacity)),
                               style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round))
            }
            for stroke in strokes {
                guard let end = stroke.end else { continue }
                let fade = stroke.line.emphasized ? 1 : 0.35
                context.fill(Path(ellipseIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)),
                             with: .color(.white.opacity(0.95 * fade)))
                context.fill(Path(ellipseIn: CGRect(x: end.x - 2.75, y: end.y - 2.75, width: 5.5, height: 5.5)),
                             with: .color(lineColor.opacity(fade)))
            }
        }
        .allowsHitTesting(false)
    }

    /// Places on the visible face: dots, then pills on top, then the Mac.
    private func markers(_ projection: GlobeProjection) -> some View {
        ZStack {
            ForEach(scene.markers) { marker in
                if placements[marker.id] == .dot || placements[marker.id] == nil,
                   let point = projection.project(marker.coordinate) {
                    SiteDot(active: marker.active, dimmed: marker.dimmed)
                        .onTapGesture { onSelect(marker.id) }
                        .help(marker.title)
                        .position(point)
                }
            }
            ForEach(scene.markers) { marker in
                if case .pill(let extra) = placements[marker.id], let point = projection.project(marker.coordinate) {
                    CityPill(title: marker.title, extra: extra, active: marker.active,
                             selected: marker.selected, dimmed: marker.dimmed)
                        .onTapGesture { onSelect(marker.id) }
                        .position(point)
                }
            }
            if let point = projection.project(scene.home) {
                HomePin(active: scene.homeActive)
                    .onTapGesture(perform: onHome)
                    .position(point)
            }
        }
        // Flexible, never the measured size: a fixed frame becomes the split view's minimum size,
        // and AppKit loops on its constraints until it throws.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Camera

    /// Radius at which the whole Earth fits, clear of the HUD.
    private var fitRadius: Double { Double(min(size.width, size.height)) * 0.4 }
    /// From a small Earth far away to about a country across the window; past it the map turns blurry.
    private var radiusRange: ClosedRange<Double> {
        let side = Double(min(size.width, size.height))
        return max(40, side * 0.14)...max(1600, fitRadius * 3)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let dx = value.translation.width - dragged.width
                let dy = value.translation.height - dragged.height
                dragged = value.translation
                turn(dx: dx, dy: dy)
            }
            .onEnded { _ in dragged = .zero }
    }

    /// Trackpad: two fingers turn the globe. Mouse wheel: zoom.
    private func scroll(dx: Double, dy: Double, precise: Bool) {
        if precise {
            turn(dx: dx, dy: dy)
        } else {
            zoom(pow(1.12, dy))
        }
    }

    private func turn(dx: Double, dy: Double) {
        guard var current = camera else { return }
        flight?.cancel()
        current.rotate(dx: dx, dy: dy)
        camera = current
        moved()
    }

    private func zoom(_ factor: Double) {
        guard var current = camera else { return }
        flight?.cancel()
        current.radius = min(radiusRange.upperBound, max(radiusRange.lowerBound, current.radius * factor))
        camera = current
        moved()
    }

    /// Hides the flows while the globe moves; labels are placed again once it settles.
    private func moved() {
        if !isMoving { isMoving = true }
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            isMoving = false
            epoch += 1
            relayout()
        }
    }

    private func resized(_ newSize: CGSize) {
        let oldFit = fitRadius
        size = newSize
        if camera == nil, newSize.width > 0, newSize.height > 0 {
            camera = GlobeCamera(latitude: min(80, max(-80, scene.homeLatitude)), longitude: scene.homeLongitude,
                                 radius: fitRadius)
        } else if var current = camera, oldFit > 0, fitRadius > 0, fitRadius != oldFit {
            // The view grew or shrank (a window opening small, Stage Manager, a resize): the globe keeps
            // showing the same part of the Earth instead of its size in points.
            current.radius = min(radiusRange.upperBound, max(radiusRange.lowerBound, current.radius * fitRadius / oldFit))
            camera = current
        }
        frameFirstTime()
        epoch += 1
        relayout()
    }

    private func frameFirstTime() {
        guard !didFrame, !scene.markers.isEmpty, camera != nil else { return }
        didFrame = true
        frame(animated: false)
    }

    /// Turns the globe towards the Mac, in the middle of the view, and zooms to fit the places around it
    /// (those of the selection when there is one).
    private func frame(animated: Bool) {
        guard camera != nil else { return }
        var markers = scene.markers
        if let focus {
            let focused = markers.filter { focus.contains($0.id) }
            if !focused.isEmpty { markers = focused }
        }
        markers.sort { scene.weights[$0.id, default: 0] > scene.weights[$1.id, default: 0] }
        let points = [scene.home] + markers.prefix(80).map(\.coordinate)
        guard let target = GlobeCamera.framing(points, around: scene.home, fit: fitRadius,
                                               maxRadius: radiusRange.upperBound) else { return }
        if animated {
            fly(to: target)
        } else {
            camera = target
            moved()
        }
    }

    private func fly(to target: GlobeCamera) {
        guard let start = camera else { return }
        flight?.cancel()
        flight = Task {
            let clock = ContinuousClock()
            let began = clock.now
            let duration = 0.9
            while !Task.isCancelled {
                let elapsed = began.duration(to: clock.now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let t = min(1, seconds / duration)
                let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
                camera = start.interpolated(to: target, eased)
                moved()
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    /// How far the globe follows the side panels at this zoom, 0…1: see `GlobeCamera.panelFollow`.
    private var follow: Double { camera?.panelFollow(in: size) ?? 1 }

    /// The flows wait for the globe to stop, and to land beside the panels.
    private var hidesFlows: Bool { isMoving || (gliding && follow > 0) }

    /// Where the side panels put the globe at `date`: its shift, and the camera's sway, which grows with
    /// the speed of the glide. Both whole while the Earth fits in the view, none once it covers it.
    private func pose(at date: Date) -> (shift: CGFloat, sway: GlobeSway) {
        let follow = self.follow
        guard gliding else { return (CGFloat(glide.target * follow), GlobeSway(speed: 0)) }
        let now = date.timeIntervalSinceReferenceDate
        return (CGFloat(glide.value(at: now) * follow), GlobeSway(speed: glide.speed(at: now) * follow))
    }

    /// The camera as drawn, with its sway. Turning and zooming change the camera itself.
    private func shownCamera(_ sway: GlobeSway) -> GlobeCamera? {
        guard var shown = camera else { return nil }
        shown.radius *= sway.scale
        shown.longitude -= sway.spin
        return shown
    }

    private func relayout() {
        let pose = pose(at: .now)
        guard let camera = shownCamera(pose.sway), size.width > 0, size.height > 0 else { return }
        let projection = GlobeProjection(camera: camera, size: size, shift: pose.shift)
        let result = Declutter.layout(scene, size: size) { projection.project($0) }
        if result != placements {
            withAnimation(.easeInOut(duration: 0.2)) { placements = result }
        }
    }
}

/// How the camera sways while the globe glides beside a side panel, on top of the camera: never kept.
/// Like a drone shot, the Earth turns the way it travels and the camera pulls back a little.
struct GlobeSway: Equatable {
    /// Share of the radius drawn.
    var scale: Double
    /// Degrees the Earth turns east.
    var spin: Double

    /// Speed of the glide, in points a second, at which the camera sways all the way. Following a panel,
    /// the globe goes at up to ~300: it turns ~7° and pulls back ~2% at the height of the glide.
    static let fullSpeed = 400.0

    /// `speed`: points a second, towards the right when positive. Like the glide, the sway sets off,
    /// peaks and settles smoothly.
    init(speed: Double) {
        let swing = min(1, max(-1, speed / Self.fullSpeed))
        scale = 1 - 0.03 * abs(swing)
        spin = 10 * swing
    }
}

/// The arc from the Mac to each place, kept until either end moves.
@MainActor
final class GlobeArcs {
    struct Arc {
        fileprivate let ends: [Double]
        /// Above the surface, in Earth radii from the centre.
        let flight: [SIMD3<Double>]
    }

    private var cache: [String: Arc] = [:]

    func arc(_ id: String, from home: CLLocationCoordinate2D, to place: CLLocationCoordinate2D) -> Arc {
        let ends = [home.latitude, home.longitude, place.latitude, place.longitude]
        if let arc = cache[id], arc.ends == ends { return arc }
        if cache.count > 800 { cache.removeAll(keepingCapacity: true) }
        let arc = Arc(ends: ends, flight: GlobeProjection.flightArc(home, place))
        cache[id] = arc
        return arc
    }
}

/// Trackpad scrolls and pinches over the globe. SwiftUI has no scroll-wheel gesture: a local event monitor
/// catches them, so the SwiftUI views on top keep their clicks.
struct GlobeEventCatcher: NSViewRepresentable {
    let onScroll: (_ dx: Double, _ dy: Double, _ precise: Bool) -> Void
    let onMagnify: (Double) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stop()
    }

    final class CatcherView: NSView {
        var onScroll: (Double, Double, Bool) -> Void = { _, _, _ in }
        var onMagnify: (Double) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the event was over the globe and turned or zoomed it.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                  bounds.contains(convert(event.locationInWindow, from: nil)), isOverGlobe(event) else { return false }
            if event.type == .magnify {
                onMagnify(1 + Double(event.magnification))
            } else {
                onScroll(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), event.hasPreciseScrollingDeltas)
            }
            return true
        }

        /// The globe reaches under the floating sidebar and inspector: their lists must keep their scrolls.
        /// Only events whose topmost view sits in the globe's own split pane, outside any scroll view, count.
        private func isOverGlobe(_ event: NSEvent) -> Bool {
            guard let frameView = window?.contentView?.superview,
                  let hit = frameView.hitTest(event.locationInWindow) else { return false }
            let pane = splitPane
            var view: NSView? = hit
            while let current = view {
                if current is NSScrollView { return false }
                if let pane, current === pane { return true }
                view = current.superview
            }
            return pane == nil
        }

        /// The split view item holding this view: the map's column, apart from the sidebar's and the inspector's.
        private var splitPane: NSView? {
            var view: NSView = self
            while let parent = view.superview {
                if parent is NSSplitView { return view }
                view = parent
            }
            return nil
        }
    }
}
