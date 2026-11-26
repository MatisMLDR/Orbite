import AppKit
import MapKit
import QuartzCore
import SwiftUI

struct FlowLine: Identifiable {
    let id: String
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D
    /// Bytes per second leaving the Mac / arriving.
    let up: Double
    let down: Double
    let emphasized: Bool
}

/// Screen-space polylines of the flows, computed once per camera position:
/// converting coordinates through MapKit is far too slow to do per frame.
@MainActor
final class FlowPathCache {
    private var paths: [String: [CGPoint]] = [:]
    private var epoch = -1

    func points(for flow: FlowLine, epoch current: Int, path: (FlowLine) -> [CGPoint]) -> [CGPoint] {
        if current != epoch {
            paths.removeAll(keepingCapacity: true)
            epoch = current
        }
        if let cached = paths[flow.id] { return cached }
        let points = path(flow)
        paths[flow.id] = points
        return points
    }

    /// The great circle on a flat map: `project` gives a coordinate's point in the view, nil where it cannot be seen.
    static func surfacePath(_ flow: FlowLine, project: (CLLocationCoordinate2D) -> CGPoint?) -> [CGPoint] {
        let samples = max(12, min(48, Int(GeoMath.distanceKm(flow.from, flow.to) / 250)))
        var points: [CGPoint] = []
        for index in 0...samples {
            let coordinate = GeoMath.interpolate(flow.from, flow.to, fraction: Double(index) / Double(samples))
            guard let point = project(coordinate) else { break }
            // A jump means the arc crosses the map's edge: keep the part next to the Mac.
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) > 600 { break }
            points.append(point)
        }
        return points
    }
}

/// One direction of one arc, as Core Animation will draw it.
struct FlowSpec: Equatable {
    let id: String
    let points: [CGPoint]
    let outbound: Bool
    let particles: Int
    let emphasized: Bool

    static func particles(for rate: Double) -> Int {
        guard rate > 0 else { return 0 }
        return min(5, max(1, Int(log10(rate) - 1.5)))
    }
}

/// Flows over the map: screen paths from the cache (recomputed per camera position), one comet
/// group per direction, handed to Core Animation.
struct FlowLayer: View {
    let flows: [FlowLine]
    let cameraEpoch: Int
    /// Screen path of a flow, from the Mac towards the server; empty when it cannot be seen.
    let path: (FlowLine) -> [CGPoint]
    @State private var cache = FlowPathCache()

    var body: some View {
        FlowOverlay(specs: specs)
    }

    private var specs: [FlowSpec] {
        flows.flatMap { flow -> [FlowSpec] in
            let points = cache.points(for: flow, epoch: cameraEpoch, path: path)
            return [
                FlowSpec(id: flow.id, points: points, outbound: true,
                         particles: FlowSpec.particles(for: flow.up), emphasized: flow.emphasized),
                FlowSpec(id: flow.id, points: points, outbound: false,
                         particles: FlowSpec.particles(for: flow.down), emphasized: flow.emphasized),
            ]
        }
    }
}

/// Comets travelling along the great circles: pink from the Mac to the server, blue back.
/// Their number follows the rate and they move at the same speed on screen whatever the distance.
/// Core Animation runs them in the render server: no work in the app between two samples.
struct FlowOverlay: NSViewRepresentable {
    let specs: [FlowSpec]

    func makeNSView(context: Context) -> FlowOverlayView { FlowOverlayView() }

    func updateNSView(_ view: FlowOverlayView, context: Context) {
        view.update(specs)
    }
}

final class FlowOverlayView: NSView {
    private static let speed: CGFloat = 150 // points per second
    private var groups: [String: (spec: FlowSpec, layer: CALayer)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ specs: [FlowSpec]) {
        guard let root = layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        var keep = Set<String>()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for spec in specs where spec.particles > 0 && spec.points.count > 1 {
            let key = "\(spec.id)|\(spec.outbound)"
            keep.insert(key)
            if let existing = groups[key], existing.spec == spec { continue }
            groups[key]?.layer.removeFromSuperlayer()
            let group = makeGroup(spec, scale: scale)
            root.addSublayer(group)
            groups[key] = (spec, group)
        }
        for (key, entry) in groups where !keep.contains(key) {
            entry.layer.removeFromSuperlayer()
            groups[key] = nil
        }
        CATransaction.commit()
    }

    private func makeGroup(_ spec: FlowSpec, scale: CGFloat) -> CALayer {
        let container = CALayer()
        container.frame = bounds
        container.opacity = spec.emphasized ? 1 : 0.25

        let points = spec.outbound ? spec.points : spec.points.reversed()
        let path = CGMutablePath()
        path.addLines(between: points)
        var length: CGFloat = 0
        for index in points.indices.dropFirst() {
            length += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        guard length > 8 else { return container }
        let duration = CFTimeInterval(length / Self.speed) + 0.4
        let image = CometImage.image(outbound: spec.outbound, scale: scale)
        let seed = CFTimeInterval(abs(spec.id.hashValue % 1000)) / 1000

        for index in 0..<spec.particles {
            let comet = CALayer()
            comet.contents = image
            comet.contentsScale = scale
            comet.bounds = CGRect(x: 0, y: 0, width: CometImage.size.width, height: CometImage.size.height)
            comet.opacity = 0

            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            move.rotationMode = .rotateAuto

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.1, 0.88, 1]

            let animation = CAAnimationGroup()
            animation.animations = [move, fade]
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            let phase = (seed + Double(index) / Double(spec.particles)).truncatingRemainder(dividingBy: 1)
            animation.timeOffset = phase * duration
            comet.add(animation, forKey: "flow")
            container.addSublayer(comet)
        }
        return container
    }

    override func layout() {
        super.layout()
        for entry in groups.values { entry.layer.frame = bounds }
    }
}

/// A small comet, head to the right (Core Animation turns it along the path), drawn once per color.
enum CometImage {
    static let size = CGSize(width: 30, height: 14)
    private static var cache: [String: CGImage] = [:]

    static func image(outbound: Bool, scale: CGFloat) -> CGImage? {
        let key = "\(outbound)|\(scale)"
        if let cached = cache[key] { return cached }
        let color = NSColor(outbound ? Theme.upload : Theme.download).usingColorSpace(.sRGB) ?? .white
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let head = CGPoint(x: size.width - 7, y: size.height / 2)

        // Tail: a tapering gradient behind the head.
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: 1, y: head.y))
        tail.addLine(to: CGPoint(x: head.x, y: head.y - 2.2))
        tail.addLine(to: CGPoint(x: head.x, y: head.y + 2.2))
        tail.closeSubpath()
        context.saveGState()
        context.addPath(tail)
        context.clip()
        let tailGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      colors: [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.75).cgColor] as CFArray,
                                      locations: [0, 1])!
        context.drawLinearGradient(tailGradient, start: CGPoint(x: 1, y: head.y), end: head, options: [])
        context.restoreGState()

        // Glow, core, white spark.
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color.withAlphaComponent(0.45).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: head, startRadius: 0, endCenter: head, endRadius: 6.5, options: [])
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: head.x - 2.6, y: head.y - 2.6, width: 5.2, height: 5.2))
        context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.fillEllipse(in: CGRect(x: head.x - 0.9, y: head.y - 0.9, width: 1.8, height: 1.8))

        let image = context.makeImage()
        cache[key] = image
        return image
    }
}
