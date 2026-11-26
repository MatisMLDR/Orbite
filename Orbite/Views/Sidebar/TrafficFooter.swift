import SwiftUI

/// Sent and received totals, the mirrored histogram and the time navigation.
struct TrafficFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let _ = store.tick
        let window = store.window
        let now = store.now
        let total = store.totalWindow
        let selection = model.ui.selection
        let bins = store.histogram(for: nil)
        let focus = selection.map { store.histogram(for: $0) }
        let binWidth = bins.count == 5 ? 60 : window.span.bins.width

        VStack(spacing: 10) {
            HStack(spacing: 8) {
                DirectionPill(direction: .up, value: Format.bytes(total.bytesOut), caption: String(localized: "sent"))
                DirectionPill(direction: .down, value: Format.bytes(total.bytesIn), caption: String(localized: "received"))
            }
            MirrorHistogram(bins: bins, highlight: focus, binWidth: binWidth, end: window.histogramEnd(now: now))
                .frame(height: 88)
            TimeControls()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Divider().opacity(0.5).padding(.horizontal, 12)
        }
    }
}

private struct TimeControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let window = store.window
        let now = store.now
        let earliest = now - TrafficBuckets.hourHorizon + 86_400

        HStack(spacing: 5) {
            FooterButton(symbol: "chevron.left", help: "Previous period") {
                store.window = TimeNavigation.back(window, now: now)
            }
            .disabled(window.range(now: now).start - window.span.seconds < earliest)

            Menu {
                Picker("Length", selection: Binding(get: { window.span }, set: { span in
                    store.window = TimeWindow(span: span, end: window.end.map { TimeNavigation.align($0, span: span) })
                })) {
                    ForEach(WindowSpan.allCases) { span in
                        Text(span.longLabel.capitalizedFirst).tag(span)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(window.span.label)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 34)
            }
            .menuStyle(.button)
            .buttonStyle(FooterButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Length of the period")

            HStack(spacing: 5) {
                if window.isLive {
                    Circle().fill(Theme.live).frame(width: 6, height: 6)
                        .shadow(color: Theme.live.opacity(0.7), radius: 3)
                }
                Text(Format.window(window, now: now))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Theme.track, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            FooterButton(symbol: "chevron.right", help: "Next period") {
                store.window = TimeNavigation.forward(window, now: now)
            }
            .disabled(window.isLive)

            FooterButton(symbol: "forward.end", help: "Back to live") {
                store.window = TimeWindow(span: window.span, end: nil)
            }
            .disabled(window.isLive)
        }
    }
}

private struct FooterButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 18)
        }
        .buttonStyle(FooterButtonStyle())
        .help(help)
    }
}

struct FooterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7)
            .frame(height: 26)
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
}

enum TimeNavigation {
    /// Aligns a window end on a natural boundary (minute, hour, local midnight).
    static func align(_ end: Int, span: WindowSpan) -> Int {
        switch span {
        case .fiveMinutes: return end / 300 * 300
        case .hour: return end / 3600 * 3600
        case .day, .week:
            let date = Date(timeIntervalSince1970: TimeInterval(end))
            return Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        }
    }

    static func back(_ window: TimeWindow, now: Int) -> TimeWindow {
        guard let end = window.end else {
            var aligned = align(now, span: window.span)
            if now - aligned < 60 { aligned -= window.span.seconds }
            return TimeWindow(span: window.span, end: aligned)
        }
        return TimeWindow(span: window.span, end: end - window.span.seconds)
    }

    static func forward(_ window: TimeWindow, now: Int) -> TimeWindow {
        guard let end = window.end else { return window }
        let next = end + window.span.seconds
        return TimeWindow(span: window.span, end: next >= now ? nil : next)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
