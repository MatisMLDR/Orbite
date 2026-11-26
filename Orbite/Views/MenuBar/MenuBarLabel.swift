import AppKit
import Observation
import SwiftUI

/// What the menu bar item shows, already formatted. Each value is set only when it changes, so the
/// item redraws only when its pixels would. Window closed, it moves every 2 seconds (2-second average).
@Observable
final class MenuBarFeed {
    private(set) var upText = Format.rate(0)
    private(set) var downText = Format.rate(0)
    private(set) var sending = false
    private(set) var receiving = false
    /// The last 30 seconds in 15 two-second columns, oldest first.
    private(set) var columns = Array(repeating: Traffic.zero, count: 15)

    @ObservationIgnored private var everySecond = true
    /// 2-second mode: one sample came in since the last update.
    @ObservationIgnored private var holding = false

    /// Called after each sample.
    func update(from store: TrafficStore) {
        if !everySecond {
            holding.toggle()
            if holding { return }
        }
        publish(store)
    }

    /// Every second while the window is open, every 2 seconds otherwise.
    func setEverySecond(_ value: Bool, store: TrafficStore) {
        guard value != everySecond else { return }
        everySecond = value
        holding = false
        publish(store)
    }

    private func publish(_ store: TrafficStore) {
        let recent = store.recentRates.suffix(everySecond ? 1 : 2)
        let count = Double(max(recent.count, 1))
        let up = recent.reduce(0) { $0 + $1.outPerSecond } / count
        let down = recent.reduce(0) { $0 + $1.inPerSecond } / count
        set(\.upText, Format.rate(up))
        set(\.downText, Format.rate(down))
        set(\.sending, up > 0)
        set(\.receiving, down > 0)
        set(\.columns, Self.columns(store.recentRates))
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<MenuBarFeed, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private static func columns(_ rates: [Rate]) -> [Traffic] {
        let recent = Array(rates.suffix(30))
        let padded = Array(repeating: Rate.zero, count: 30 - recent.count) + recent
        return stride(from: 0, to: 30, by: 2).map { index in
            let pair = padded[index..<index + 2]
            return Traffic(bytesIn: UInt64(pair.reduce(0) { $0 + $1.inPerSecond }),
                           bytesOut: UInt64(pair.reduce(0) { $0 + $1.outPerSecond }))
        }
    }
}

/// What the menu bar item draws, always live (the window may be showing a past period).
/// Every style has a fixed width, so the menu bar never moves when the numbers change.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    let style: MenuBarStyle

    var body: some View {
        let feed = model.menuBarFeed

        HStack(spacing: 4) {
            switch style {
            case .icon:
                OrbitGlyph(sending: feed.sending, receiving: feed.receiving)
                    .frame(width: 17, height: 17)
            case .rates:
                StackedRates(up: feed.upText, down: feed.downText)
            case .graph:
                MenuBarGraph(columns: feed.columns)
            case .graphAndRates:
                MenuBarGraph(columns: feed.columns)
                StackedRates(up: feed.upText, down: feed.downText)
            }
        }
        .frame(width: style.width, height: NSStatusBar.system.thickness)
    }
}

/// ↑ and ↓ rates on two tight lines.
private struct StackedRates: View {
    let up: String
    let down: String

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            line(.up, up)
            line(.down, down)
        }
        .frame(width: 58, alignment: .leading)
    }

    private func line(_ direction: Direction, _ text: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: direction.symbol)
                .font(.system(size: 7.5, weight: .heavy))
                .foregroundStyle(direction.color)
                .frame(width: 7)
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

/// The last 30 seconds in 15 two-second columns: sent up in pink, received down in blue.
private struct MenuBarGraph: View {
    let columns: [Traffic]

    var body: some View {
        TrafficMeter(values: columns, gap: 1, showsTrack: false)
            .frame(width: 34, height: 16)
            .background(alignment: .center) {
                Rectangle().fill(.primary.opacity(0.25)).frame(height: 0.5)
            }
    }
}

/// Orbite's mark: a planet with a tilted orbit and two satellites that light up with traffic.
struct OrbitGlyph: View {
    let sending: Bool
    let receiving: Bool

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let ink = GraphicsContext.Shading.style(.primary)

            let planet = side * 0.36
            context.fill(Path(ellipseIn: CGRect(x: center.x - planet / 2, y: center.y - planet / 2,
                                                width: planet, height: planet)), with: ink)

            var orbit = context
            orbit.translateBy(x: center.x, y: center.y)
            orbit.rotate(by: .degrees(-24))
            let ring = CGRect(x: -side * 0.48, y: -side * 0.2, width: side * 0.96, height: side * 0.4)
            orbit.stroke(Path(ellipseIn: ring), with: ink, lineWidth: max(1, side * 0.075))

            // Satellites at both ends of the ring, drawn in the rotated frame. A transparent gap
            // around each one cuts the ring (the menu bar behind can be any colour).
            let dot = side * 0.24
            for (x, lit, color) in [(ring.maxX - dot * 0.2, sending, Theme.upload),
                                    (ring.minX + dot * 0.2, receiving, Theme.download)] {
                let rect = CGRect(x: x - dot / 2, y: -dot / 2, width: dot, height: dot)
                var cut = orbit
                cut.blendMode = .destinationOut
                cut.fill(Path(ellipseIn: rect.insetBy(dx: -1.2, dy: -1.2)), with: .color(.black))
                orbit.fill(Path(ellipseIn: rect), with: lit ? .color(color) : ink)
            }
        }
        .accessibilityHidden(true)
    }
}
