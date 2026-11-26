import SwiftUI

/// App, macOS or tool icon from the resolver's cache.
struct AppIconView: View {
    @Environment(AppModel.self) private var model
    let identity: AppIdentity
    var size: CGFloat = 22

    var body: some View {
        if identity.kind == .tool {
            SymbolIcon(symbol: "terminal.fill", size: size, colors: [Color(white: 0.32), Color(white: 0.12)])
        } else {
            Image(nsImage: model.resolver.icon(for: identity))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

/// Processes inside an app show its icon; bare daemons get a gear.
struct ProcessIconView: View {
    @Environment(AppModel.self) private var model
    let path: String
    var size: CGFloat = 18

    var body: some View {
        if AppResolver.outermostBundle(path) != nil {
            Image(nsImage: model.resolver.processIcon(path: path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            SymbolIcon(symbol: "gearshape.fill", size: size, colors: [Color(white: 0.62), Color(white: 0.42)])
        }
    }
}

/// An SF Symbol on a small rounded gradient square, sized like an app icon.
struct SymbolIcon: View {
    let symbol: String
    let size: CGFloat
    let colors: [Color]

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(size * 0.06)
            .frame(width: size, height: size)
    }
}

/// Six 10-second columns: pink grows up from the middle (sent), blue grows down (received).
struct TrafficMeter: View {
    let values: [Traffic]
    var gap: CGFloat = 2
    var showsTrack = true

    var body: some View {
        Canvas { context, size in
            let count = max(values.count, 1)
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let middle = size.height / 2
            let radius = min(width / 2, 2.2)
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * (width + gap)
                if showsTrack {
                    context.fill(Path(roundedRect: CGRect(x: x, y: 0, width: width, height: size.height), cornerRadius: radius),
                                 with: .color(Theme.track))
                }
                let up = Theme.level(value.bytesOut) * (middle - 0.5)
                if up > 0 {
                    let height = max(up, 1.5)
                    context.fill(Path(roundedRect: CGRect(x: x, y: middle - 0.5 - height, width: width, height: height),
                                      cornerRadius: min(radius, height / 2)), with: .color(Theme.upload))
                }
                let down = Theme.level(value.bytesIn) * (middle - 0.5)
                if down > 0 {
                    let height = max(down, 1.5)
                    context.fill(Path(roundedRect: CGRect(x: x, y: middle + 0.5, width: width, height: height),
                                      cornerRadius: min(radius, height / 2)), with: .color(Theme.download))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Tinted capsule with an arrow and a volume or a rate, as in the footer and the inspector.
struct DirectionPill: View {
    @Environment(\.colorScheme) private var scheme
    let direction: Direction
    let value: String
    var caption: String?
    var large = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: direction.symbol)
                .font(.system(size: large ? 17 : 13.5, weight: .heavy))
                .foregroundStyle(direction.color)
            if let caption {
                Text(caption)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(direction.color)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 2)
            Text(value)
                .font(.system(size: large ? 19 : 14.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, large ? 13 : 10)
        .frame(height: large ? 42 : 32)
        .frame(maxWidth: .infinity)
        .background(direction == .up ? Theme.uploadFill(scheme) : Theme.downloadFill(scheme),
                    in: RoundedRectangle(cornerRadius: large ? 12 : 9, style: .continuous))
    }
}

/// « ↑ 12 Ko/s  ↓ 3,4 Mo/s » for live rates.
struct RatePair: View {
    let rate: Rate
    var font: Font = .system(size: 11.5, weight: .semibold)

    var body: some View {
        HStack(spacing: 9) {
            pair(.up, rate.outPerSecond)
            pair(.down, rate.inPerSecond)
        }
        .font(font)
        .monospacedDigit()
    }

    private func pair(_ direction: Direction, _ value: Double) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: direction.symbol)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(direction.color)
            Text(Format.rate(value))
        }
    }
}

/// Mirrored bar chart: sent above the line in pink, received below in blue, on grey tracks.
/// `highlight` draws a subset (the selection) on top of the faded total.
struct MirrorHistogram: View {
    let bins: [Traffic]
    var highlight: [Traffic]?
    var binWidth: Int = 10
    var end: Int = 0
    var showsTooltip = true

    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geometry in
            let count = max(bins.count, 1)
            let gap: CGFloat = count > 36 ? 2.5 : 3.5
            let width = max(2, (geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let scale = max(bins.map { max($0.bytesIn, $0.bytesOut) }.max() ?? 0, 1)
            let half = geometry.size.height / 2 - 1

            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(bins.enumerated()), id: \.offset) { index, bin in
                    let focus = highlight?[safe: index]
                    Bar(value: bin, focus: focus, faded: highlight != nil, scale: scale, half: half,
                        width: width, isHovered: hovered == index)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let index = Int(point.x / (width + gap))
                    hovered = (0..<count).contains(index) ? index : nil
                case .ended:
                    hovered = nil
                }
            }
            .overlay(alignment: .top) {
                if showsTooltip, let hovered, let bin = bins[safe: hovered] {
                    tooltip(index: hovered, bin: highlight?[safe: hovered] ?? bin)
                        .offset(y: -6)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func tooltip(index: Int, bin: Traffic) -> some View {
        let start = end - (bins.count - index) * binWidth
        let date = Date(timeIntervalSince1970: TimeInterval(start))
        return HStack(spacing: 8) {
            Text(Format.time(date)).foregroundStyle(.secondary)
            Label(Format.bytes(bin.bytesOut), systemImage: "arrow.up").foregroundStyle(Theme.upload)
            Label(Format.bytes(bin.bytesIn), systemImage: "arrow.down").foregroundStyle(Theme.download)
        }
        .labelStyle(CompactLabelStyle())
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private struct Bar: View {
        let value: Traffic
        let focus: Traffic?
        let faded: Bool
        let scale: UInt64
        let half: CGFloat
        let width: CGFloat
        let isHovered: Bool

        var body: some View {
            VStack(spacing: 2) {
                ZStack(alignment: .bottom) {
                    Color.clear
                    segment(value.bytesOut, Theme.upload.opacity(faded ? 0.28 : 1), top: true)
                    if let focus { segment(focus.bytesOut, Theme.upload, top: true) }
                }
                .frame(height: half)
                ZStack(alignment: .top) {
                    Color.clear
                    segment(value.bytesIn, Theme.download.opacity(faded ? 0.28 : 1), top: false)
                    if let focus { segment(focus.bytesIn, Theme.download, top: false) }
                }
                .frame(height: half)
            }
            .frame(width: width)
            .background(Capsule().fill(Theme.track.opacity(isHovered ? 2.4 : 1)))
        }

        @ViewBuilder
        private func segment(_ bytes: UInt64, _ color: Color, top: Bool) -> some View {
            let fraction = bytes == 0 ? 0 : max(0.04, sqrt(Double(bytes) / Double(scale)))
            UnevenRoundedRectangle(cornerRadii: top
                                   ? .init(topLeading: width / 2, bottomLeading: 1.5, bottomTrailing: 1.5, topTrailing: width / 2)
                                   : .init(topLeading: 1.5, bottomLeading: width / 2, bottomTrailing: width / 2, topTrailing: 1.5),
                                   style: .continuous)
                .fill(color)
                .frame(height: bytes == 0 ? 0 : max(2, half * fraction))
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2.5) {
            configuration.icon.font(.system(size: 9, weight: .heavy))
            configuration.title
        }
    }
}

/// Small mirrored sparkline of the last minute of rates.
struct RateSparkline: View {
    let rates: [Rate]

    var body: some View {
        Canvas { context, size in
            guard rates.count > 1 else { return }
            let scale = max(rates.map { max($0.inPerSecond, $0.outPerSecond) }.max() ?? 1, 1)
            let middle = size.height / 2
            let step = size.width / CGFloat(max(rates.count - 1, 1))
            func area(_ value: (Rate) -> Double, up: Bool) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: middle))
                for (index, rate) in rates.enumerated() {
                    let height = CGFloat(sqrt(value(rate) / scale)) * (middle - 1)
                    path.addLine(to: CGPoint(x: CGFloat(index) * step, y: up ? middle - height : middle + height))
                }
                path.addLine(to: CGPoint(x: CGFloat(rates.count - 1) * step, y: middle))
                path.closeSubpath()
                return path
            }
            context.fill(area({ $0.outPerSecond }, up: true), with: .color(Theme.upload.opacity(0.85)))
            context.fill(area({ $0.inPerSecond }, up: false), with: .color(Theme.download.opacity(0.85)))
        }
    }
}

/// Collapsible inspector section with a soft header bar; open state remembered per title.
struct InspectorSection<Content: View>: View {
    let title: String
    @AppStorage private var expanded: Bool
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringResource, defaultExpanded: Bool = true, @ViewBuilder content: () -> Content) {
        let title = String(localized: title)
        self.title = title
        _expanded = AppStorage(wrappedValue: defaultExpanded, "section.\(title)")
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.28)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.sectionFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
    }
}

/// Label/value rows aligned on a trailing label column, like Little Snitch's inspector.
struct InfoGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            content
        }
        .font(.system(size: 12.5))
    }
}

struct InfoRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    init(_ label: LocalizedStringResource, @ViewBuilder value: () -> Value) {
        self.label = String(localized: label)
        self.value = value()
    }

    @_disfavoredOverload
    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        GridRow {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
                .lineLimit(1)
                .fixedSize()
            value
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension InfoRow where Value == Text {
    init(_ label: LocalizedStringResource, _ text: String) {
        self.init(label) { Text(text) }
    }

    @_disfavoredOverload
    init(_ label: String, _ text: String) {
        self.init(label) { Text(text) }
    }
}

/// A list of values with « + N de plus » that unfolds.
struct ValueList: View {
    let values: [String]
    var limit = 4
    var monospaced = false
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array((showAll ? values : Array(values.prefix(limit))).enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if values.count > limit {
                Button(showAll ? "Less" : "+ \(values.count - limit) more") {
                    withAnimation(.snappy) { showAll.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }
            if values.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }
}

/// Thin horizontal bar used in the overview's top lists.
struct ShareBar: View {
    let fraction: Double
    var color: Color = Theme.download

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(3, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

/// Small rounded tag (« CLI », « macOS »); tinted for warnings (« PUB », « EN CLAIR »).
struct Tag: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tint.map { $0.opacity(0.7) } ?? Color.secondary.opacity(0.6), lineWidth: 1))
            .fixedSize()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Edge blur

extension View {
    /// Blurs and fades what scrolls under the top and bottom edges, over the given heights (0: sharp edge).
    func edgeBlur(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        modifier(EdgeBlurModifier(top: top, bottom: bottom))
    }
}

private struct EdgeBlurModifier: ViewModifier {
    let top: CGFloat
    let bottom: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                VStack(spacing: 0) {
                    if top > 0 { EdgeBlur(edge: .top).frame(height: top) }
                    Spacer(minLength: 0)
                    if bottom > 0 { EdgeBlur(edge: .bottom).frame(height: bottom) }
                }
                .allowsHitTesting(false)
            }
            .mask {
                VStack(spacing: 0) {
                    if top > 0 {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.5), location: 0.45),
                                               .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: top)
                    }
                    Rectangle()
                    if bottom > 0 {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.5), location: 0.55),
                                               .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: bottom)
                    }
                }
            }
    }
}

/// A material that thins out away from the edge: what scrolls under it goes out of focus.
private struct EdgeBlur: View {
    let edge: VerticalEdge

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask(LinearGradient(colors: [.black, .clear], startPoint: edge == .top ? .top : .bottom,
                                 endPoint: edge == .top ? .bottom : .top))
    }
}
