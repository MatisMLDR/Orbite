import CoreGraphics
import CoreLocation
import Foundation

nonisolated enum GeoMath {
    static let earthRadiusKm = 6371.0

    /// Unit vector from the centre of the Earth to the point.
    static func vector(_ c: CLLocationCoordinate2D) -> (Double, Double, Double) {
        let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
        return (cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    }

    private static func coordinate(_ x: Double, _ y: Double, _ z: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi, longitude: atan2(y, x) * 180 / .pi)
    }

    /// Middle of the points on the sphere (mean of their vectors): where the globe faces to show them all.
    static func centroid(_ points: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard let first = points.first else { return nil }
        var x = 0.0, y = 0.0, z = 0.0
        for point in points {
            let v = vector(point)
            x += v.0; y += v.1; z += v.2
        }
        // Points spread evenly around the Earth have no middle.
        guard x * x + y * y + z * z > 1e-12 else { return first }
        return coordinate(x, y, z)
    }

    /// Central angle between two points, in radians.
    static func angle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * atan2(sqrt(h), sqrt(max(0, 1 - h)))
    }

    static func distanceKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        angle(a, b) * earthRadiusKm
    }

    /// Point at `fraction` along the great circle from `a` to `b` (the path MapKit draws as geodesic).
    static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, fraction t: Double) -> CLLocationCoordinate2D {
        let d = angle(a, b)
        guard d > 1e-9 else { return a }
        let va = vector(a), vb = vector(b)
        let sa = sin((1 - t) * d) / sin(d), sb = sin(t * d) / sin(d)
        return coordinate(sa * va.0 + sb * vb.0, sa * va.1 + sb * vb.1, sa * va.2 + sb * vb.2)
    }

    /// Where the sun stands overhead at `date` (NOAA's low-precision formulas, about 0.1° off).
    static func subsolarPoint(at date: Date) -> CLLocationCoordinate2D {
        let days = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0
        let radians = Double.pi / 180
        let meanLongitude = 280.460 + 0.9856474 * days
        let meanAnomaly = (357.528 + 0.9856003 * days) * radians
        let eclipticLongitude = (meanLongitude + 1.915 * sin(meanAnomaly) + 0.020 * sin(2 * meanAnomaly)) * radians
        let obliquity = (23.439 - 0.0000004 * days) * radians
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        let siderealTime = 280.46061837 + 360.98564736629 * days
        var longitude = (rightAscension / radians - siderealTime).truncatingRemainder(dividingBy: 360)
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        return CLLocationCoordinate2D(latitude: declination / radians, longitude: longitude)
    }

    static func greatCircle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, points: Int) -> [CLLocationCoordinate2D] {
        guard points > 1 else { return [a, b] }
        return (0...points).map { interpolate(a, b, fraction: Double($0) / Double(points)) }
    }
}

/// Where the globe looks: the point at the middle of the view and the size of the Earth on screen.
nonisolated struct GlobeCamera: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Radius of the globe on screen, in points.
    var radius: Double

    /// Turns the globe under the pointer: the surface follows a drag of `dx`, `dy` points.
    mutating func rotate(dx: Double, dy: Double) {
        latitude = min(80, max(-80, latitude + dy / radius * 180 / .pi))
        longitude -= dx / radius * 180 / .pi
        longitude = (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    /// Step `t` (0…1) of the flight from `self` to `target`: the short way round, zoom on a log scale.
    func interpolated(to target: GlobeCamera, _ t: Double) -> GlobeCamera {
        var deltaLongitude = (target.longitude - longitude).truncatingRemainder(dividingBy: 360)
        if deltaLongitude > 180 { deltaLongitude -= 360 }
        if deltaLongitude < -180 { deltaLongitude += 360 }
        var longitude = self.longitude + deltaLongitude * t
        longitude = (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        return GlobeCamera(latitude: latitude + (target.latitude - latitude) * t, longitude: longitude,
                           radius: exp(log(radius) + (log(target.radius) - log(radius)) * t))
    }

    /// Faces `center` (the middle of the points when nil) and zooms until the farthest point sits `fit`
    /// points from the centre of the view.
    static func framing(_ points: [CLLocationCoordinate2D], around center: CLLocationCoordinate2D? = nil,
                        fit: Double, maxRadius: Double) -> GlobeCamera? {
        guard let center = center ?? GeoMath.centroid(points) else { return nil }
        let spread = points.map { GeoMath.angle(center, $0) }.max() ?? 0
        // At least ~1 400 km across, like the flat map; past a quarter turn the whole hemisphere shows.
        let reach = sin(min(.pi / 2, max(0.11, spread * 1.12)))
        return GlobeCamera(latitude: min(80, max(-80, center.latitude)), longitude: center.longitude,
                           radius: min(maxRadius, max(fit, fit / reach)))
    }

    /// How far the globe follows the side panels, 0…1, in a view of `size`. All the way while the whole
    /// Earth fits in the view's height: an object, centred in the part the panels leave free. Not at all
    /// once it covers the whole view: a map, which the panels cover like the flat maps, without moving
    /// what is under the pointer. In between, zooming carries it smoothly from one to the other.
    func panelFollow(in size: CGSize) -> Double {
        guard size.width > 0, size.height > 0, radius > 0 else { return 1 }
        let whole = Double(min(size.width, size.height)) / 2
        let covered = Double(hypot(size.width, size.height)) / 2
        // On the zoom's own scale: each step of the wheel or the pinch does its share.
        let t = min(1, max(0, log(radius / whole) / log(covered / whole)))
        return 1 - t * t * (3 - 2 * t)
    }
}

/// A glide to `target` through two critically damped springs in a row, the second following the first:
/// it sets off gently, speeds up and slows down along an S, and lands softly without overshooting.
/// Its place, speed and acceleration never jump, so what follows its speed (the globe's sway) rises and
/// settles smoothly too. Aimed again on the way, both springs keep where they are and how fast they go,
/// so following a target that moves frame by frame makes one smooth motion that trails it.
/// Worked out for any moment, to be drawn frame by frame.
nonisolated struct Glide: Equatable, Sendable {
    /// Seconds each spring takes to cover most of the way, like a SwiftUI spring's response: about 1.4 s
    /// from one place to the next.
    static let response = 0.7
    private static let w = 2 * .pi / response

    private(set) var target: Double
    /// Seconds on the clock of `Date.timeIntervalSinceReferenceDate`.
    private(set) var start: TimeInterval
    /// When it lands, a twentieth of a point from the target: from then on it rests there.
    private(set) var end: TimeInterval
    /// The gap to the target is (a + b t + c t² + d t³) e^(-ωt), t seconds after `start`: the response
    /// of two springs of the same ω in a row.
    private var a = 0.0, b = 0.0, c = 0.0, d = 0.0

    init(resting value: Double, at time: TimeInterval = 0) {
        target = value
        start = time
        end = time
    }

    func value(at time: TimeInterval) -> Double { target + gap(at: time).0 }

    /// Units a second, towards higher values.
    func speed(at time: TimeInterval) -> Double { gap(at: time).1 }

    /// The same motion heading for `target` from `time` on.
    func aimed(at target: Double, at time: TimeInterval) -> Glide {
        let w = Self.w
        // Moving the target moves both springs' gaps alike: only the gap itself changes, not its
        // derivatives, which hold the springs' speeds and the first spring's lead.
        let (f0, f1, f2, f3) = gap(at: time)
        var next = Glide(resting: target, at: time)
        next.a = f0 + self.target - target
        next.b = f1 + w * next.a
        next.c = (f2 + 2 * w * next.b - w * w * next.a) / 2
        next.d = (f3 + 6 * w * next.c - 3 * w * w * next.b + w * w * w * next.a) / 6
        next.end = time + next.settling
        return next
    }

    /// The gap to the target and its first three derivatives at `time`.
    private func gap(at time: TimeInterval) -> (Double, Double, Double, Double) {
        guard time < end else { return (0, 0, 0, 0) }
        let w = Self.w, t = max(0, time - start), e = exp(-w * t)
        let p = a + t * (b + t * (c + t * d))
        let p1 = b + t * (2 * c + 3 * d * t)
        let p2 = 2 * c + 6 * d * t
        let p3 = 6 * d
        return (p * e,
                (p1 - w * p) * e,
                (p2 - 2 * w * p1 + w * w * p) * e,
                (p3 - 3 * w * p2 + 3 * w * w * p1 - w * w * w * p) * e)
    }

    /// Seconds until the gap stays under a twentieth of a point and the speed under half a point a
    /// second, too little to see: bounds that only shrink past the peak of t³ e^(-ωt).
    private var settling: TimeInterval {
        let w = Self.w
        var t = 3 / w
        while t < 10 {
            let e = exp(-w * t)
            let size = abs(a) + t * (abs(b) + t * (abs(c) + t * abs(d)))
            let slope = abs(b) + t * (2 * abs(c) + 3 * abs(d) * t)
            if size * e < 0.05, (slope + w * size) * e < 0.5 { return t }
            t += 1.0 / 60
        }
        return t
    }
}

/// Orthographic view of the globe: the same math as Globe.metal, for what is drawn over it.
nonisolated struct GlobeProjection: Sendable {
    let camera: GlobeCamera
    /// Centre of the globe in the view.
    let center: CGPoint
    private let east: SIMD3<Double>
    private let north: SIMD3<Double>
    private let out: SIMD3<Double>

    /// `shift` moves the globe sideways from the middle of the view, towards the part no side panel covers.
    init(camera: GlobeCamera, size: CGSize, shift: CGFloat = 0) {
        self.camera = camera
        center = CGPoint(x: size.width / 2 + shift, y: size.height / 2)
        let lat = camera.latitude * .pi / 180, lon = camera.longitude * .pi / 180
        out = SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        east = SIMD3(-sin(lon), cos(lon), 0)
        north = SIMD3(-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat))
    }

    static func unit(_ c: CLLocationCoordinate2D) -> SIMD3<Double> {
        let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
        return SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    }

    /// The globe's light when it does not follow the sun: from the upper left of the view, slightly in
    /// front (as in Globe.metal), as an Earth-fixed unit vector.
    var viewLight: SIMD3<Double> {
        let light = east * -0.45 + north * 0.55 + out * 0.70
        return light / (light * light).sum().squareRoot()
    }

    /// How far the point faces the viewer: 1 in the middle, 0 on the rim, negative behind the Earth.
    func depth(_ v: SIMD3<Double>) -> Double { (v * out).sum() }

    /// Screen point of a unit vector, wherever it is (the far side lands inside the disc too).
    func point(_ v: SIMD3<Double>) -> CGPoint {
        CGPoint(x: center.x + camera.radius * (v * east).sum(), y: center.y - camera.radius * (v * north).sum())
    }

    /// Screen point of a place, nil when the Earth hides it.
    func project(_ c: CLLocationCoordinate2D) -> CGPoint? {
        let v = Self.unit(c)
        return depth(v) > 0.02 ? point(v) : nil
    }

    /// Screen paths of a great-circle arc sampled as `samples`: one run per stretch in front of the Earth,
    /// each cut exactly at the rim.
    func visibleRuns(_ samples: [SIMD3<Double>]) -> [[CGPoint]] {
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        var previous: (v: SIMD3<Double>, depth: Double)?
        for v in samples {
            let d = depth(v)
            if let previous, (previous.depth > 0) != (d > 0) {
                let t = previous.depth / (previous.depth - d)
                let rim = previous.v + (v - previous.v) * t
                current.append(point(rim / (rim * rim).sum().squareRoot()))
                if d <= 0 {
                    runs.append(current)
                    current = []
                }
            }
            if d > 0 { current.append(point(v)) }
            previous = (v, d)
        }
        if current.count > 1 { runs.append(current) }
        return runs.filter { $0.count > 1 }
    }

    // MARK: Paths above the surface

    /// Where a point in space stands for the viewer.
    enum Side: Equatable, Sendable {
        /// On the viewer's side of the Earth's centre: always visible.
        case front
        /// Behind the centre but past the rim: visible beside the globe.
        case behind
        /// Behind the Earth.
        case hidden
    }

    /// `p` in Earth radii from the centre of the Earth.
    func side(_ p: SIMD3<Double>) -> Side {
        // In front of the centre, a point above the surface is in front of the surface too.
        if (p * out).sum() >= 0 { return .front }
        let x = (p * east).sum(), y = (p * north).sum()
        return x * x + y * y >= 1 ? .behind : .hidden
    }

    /// Screen runs of a path in space, cut where the Earth hides it, each run ending exactly at the edge.
    /// With `splitBehind`, the stretches behind the globe's rim come apart from the front ones (`front` false).
    func runs(_ path: [SIMD3<Double>], splitBehind: Bool = true) -> [(points: [CGPoint], front: Bool)] {
        func kind(_ p: SIMD3<Double>) -> Side {
            let side = side(p)
            return splitBehind || side == .hidden ? side : .front
        }
        var runs: [(points: [CGPoint], front: Bool)] = []
        var current: [CGPoint] = []
        var previous: (p: SIMD3<Double>, side: Side)?
        for p in path {
            let side = kind(p)
            if let previous, previous.side != side {
                // The edge between two samples, found by halving the segment.
                var low = 0.0, high = 1.0
                for _ in 0..<12 {
                    let middle = (low + high) / 2
                    if kind(previous.p + (p - previous.p) * middle) == previous.side { low = middle } else { high = middle }
                }
                let edge = point(previous.p + (p - previous.p) * ((low + high) / 2))
                if previous.side != .hidden {
                    current.append(edge)
                    runs.append((current, previous.side == .front))
                }
                current = side == .hidden ? [] : [edge]
            }
            if side != .hidden { current.append(point(p)) }
            previous = (p, side)
        }
        if let previous, previous.side != .hidden { runs.append((current, previous.side == .front)) }
        return runs.filter { $0.points.count > 1 }
    }

    /// Screen path of a flow along its arc, from the Mac to the first place the Earth hides it.
    /// Empty when the Mac itself is out of sight.
    func flightPath(_ path: [SIMD3<Double>]) -> [CGPoint] {
        guard let start = path.first, side(start) != .hidden else { return [] }
        return runs(path, splitBehind: false).first?.points ?? []
    }

    /// Shadow of an arc on the ground, cast by the sun (`sun`: unit vector towards it, as in Globe.metal):
    /// each point falls away from the sun by its height, so the higher the arc, the further its shadow.
    /// None on the night side.
    func shadowRuns(_ flight: [SIMD3<Double>], sun: SIMD3<Double>) -> [[CGPoint]] {
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for p in flight {
            let length = (p * p).sum().squareRoot()
            let ground = p / length
            let elevation = (sun * ground).sum()
            guard depth(ground) > 0, elevation > 0.05 else {
                if current.count > 1 { runs.append(current) }
                current = []
                continue
            }
            // Along the ground, away from the sun; longer when it is low. Half the true length: a shadow
            // that strays far from its arc reads as a second line.
            let along = sun - ground * elevation
            let shadow = ground - along * (0.5 * (length - 1) / max(elevation, 0.35))
            current.append(point(shadow / (shadow * shadow).sum().squareRoot()))
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }

    /// The arc of a connection: the great circle from `a` to `b`, lifted off the ground, higher for
    /// longer trips (in Earth radii from the centre).
    static func flightArc(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> [SIMD3<Double>] {
        let angle = GeoMath.angle(a, b)
        // ~70 km for a neighbouring city, ~900 km across the Atlantic, at most ~1 400 km.
        let height = min(0.22, 0.01 + 0.15 * angle)
        let count = max(16, min(96, Int(angle * GeoMath.earthRadiusKm / 150)))
        return (0...count).map { index in
            let t = Double(index) / Double(count)
            return unit(GeoMath.interpolate(a, b, fraction: t)) * (1 + height * sin(.pi * t))
        }
    }
}

/// Screen-space label placement: biggest places get a pill, the ones that would overlap become
/// dots, and the dots that would still overlap are folded into the nearest pill's count.
nonisolated enum Declutter {
    struct Item: Sendable {
        var id: String
        var point: CGPoint
        var labelWidth: CGFloat
        var weight: Double
    }

    enum Placement: Equatable, Sendable {
        case pill(extra: Int)
        case dot
        case hidden
    }

    static func place(_ items: [Item], obstacles: [CGRect] = [], pillHeight: CGFloat = 30,
                      dotSize: CGFloat = 20, maxPills: Int = 28) -> [String: Placement] {
        var pills: [(id: String, rect: CGRect)] = []
        var dots: [CGRect] = []
        var result: [String: Placement] = [:]
        var extra: [String: Int] = [:]
        let blocked = obstacles

        for item in items.sorted(by: { $0.weight > $1.weight }) {
            let pillRect = CGRect(x: item.point.x - item.labelWidth / 2, y: item.point.y - pillHeight / 2,
                                  width: item.labelWidth, height: pillHeight).insetBy(dx: -3, dy: -2)
            let free = !pills.contains { $0.rect.intersects(pillRect) }
                && !dots.contains { $0.intersects(pillRect) }
                && !blocked.contains { $0.intersects(pillRect) }
            if free && pills.count < maxPills {
                pills.append((item.id, pillRect))
                result[item.id] = .pill(extra: 0)
                continue
            }
            let dotRect = CGRect(x: item.point.x - dotSize / 2, y: item.point.y - dotSize / 2, width: dotSize, height: dotSize)
            let dotFree = !pills.contains { $0.rect.intersects(dotRect) }
                && !dots.contains { $0.intersects(dotRect.insetBy(dx: 2, dy: 2)) }
                && !blocked.contains { $0.intersects(dotRect) }
            if dotFree {
                dots.append(dotRect)
                result[item.id] = .dot
            } else {
                result[item.id] = .hidden
                if let nearest = pills.min(by: { distance($0.rect, item.point) < distance($1.rect, item.point) }) {
                    extra[nearest.id, default: 0] += 1
                }
            }
        }
        for (id, count) in extra { result[id] = .pill(extra: count) }
        return result
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(rect.midX - point.x, rect.midY - point.y)
    }
}
