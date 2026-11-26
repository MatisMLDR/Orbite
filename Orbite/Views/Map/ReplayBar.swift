import SwiftUI

/// Replaces the HUD while the day replays: play, speed, the day's histogram to scrub, the time on screen.
struct ReplayBar: View {
    @Environment(AppModel.self) private var model
    let replay: ReplayController
    /// Narrow map: a shorter scrubber and an icon for « Voir cette heure ».
    var compact = false

    private static let barCount = 96

    var body: some View {
        let timeline = replay.timeline
        let group = ReplayTimeline.slotCount / Self.barCount
        let bins = (0..<Self.barCount).map { index in
            timeline.global[(index * group)..<((index + 1) * group)].reduce(Traffic.zero, +)
        }
        HStack(spacing: 14) {
            Button {
                replay.toggle()
            } label: {
                Image(systemName: replay.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(replay.playing ? "Pause" : "Play")

            Text(Format.time(replay.date))
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .frame(width: 46, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    MirrorHistogram(bins: bins, binWidth: ReplayTimeline.slotSeconds * group, showsTooltip: false)
                        .allowsHitTesting(false)
                    let x = geometry.size.width * CGFloat(replay.slot) / CGFloat(ReplayTimeline.slotCount - 1)
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 2.5, height: geometry.size.height + 6)
                        .offset(x: x - 1.25)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let fraction = min(1, max(0, value.location.x / max(geometry.size.width, 1)))
                    replay.seek(Int(fraction * CGFloat(ReplayTimeline.slotCount - 1)))
                })
            }
            .frame(width: compact ? 180 : 360, height: 26)

            Menu {
                Picker("Speed", selection: Binding(get: { replay.speed }, set: { replay.speed = $0 })) {
                    Text("1× · the day in 1 min").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }
                .pickerStyle(.inline)
            } label: {
                Text("\(Int(replay.speed))×")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Speed")

            Divider().frame(height: 16)

            Button {
                let second = Int(replay.date.timeIntervalSince1970)
                let end = TimeNavigation.align(second, span: .hour) + 3600
                let now = model.store.now
                model.stopReplay()
                model.store.window = TimeWindow(span: .hour, end: end >= now ? nil : end)
            } label: {
                if compact {
                    Image(systemName: "clock.arrow.circlepath")
                } else {
                    Text("See This Hour")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.download)
            .help("See This Hour")

            Button {
                model.stopReplay()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Leave the replay")
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .fixedSize()
    }
}
