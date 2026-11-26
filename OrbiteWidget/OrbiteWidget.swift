import SwiftUI
import WidgetKit

@main
struct OrbiteWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrafficWidget()
    }
}

/// Today's traffic on the desktop: the total, the day's curve, the busiest apps, mobile data.
struct TrafficWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: SnapshotProvider()) { entry in
            TrafficWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "orbite://open"))
        }
        .configurationDisplayName("Today's Traffic")
        .description("What your Mac has exchanged today, according to Orbite.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
}

/// Orbite writes the snapshot and asks for a reload; the timeline also looks again every 15 minutes.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? .placeholder : WidgetSnapshot.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct TrafficWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private static let upload = Color(red: 0.89, green: 0.39, blue: 0.95)
    private static let download = Color(red: 0.09, green: 0.53, blue: 1.0)

    var body: some View {
        if let snapshot = entry.snapshot {
            HStack(alignment: .top, spacing: 16) {
                summary(snapshot)
                if family == .systemMedium {
                    details(snapshot)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Orbite", systemImage: "globe")
                    .font(.system(size: 13, weight: .semibold))
                Text("Open Orbite to see your traffic here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(WidgetFormat.bytes(snapshot.todayTotal))
                .font(.system(size: 24, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            HStack(spacing: 8) {
                Label(WidgetFormat.bytes(snapshot.todayOut), systemImage: "arrow.up")
                    .foregroundStyle(Self.upload)
                Label(WidgetFormat.bytes(snapshot.todayIn), systemImage: "arrow.down")
                    .foregroundStyle(Self.download)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .labelStyle(CompactLabel())
            Spacer(minLength: 0)
            HourBars(hours: snapshot.hours, color: Self.download)
                .frame(height: 30)
        }
    }

    private func details(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(snapshot.topApps.prefix(3).enumerated()), id: \.offset) { _, app in
                HStack {
                    Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(WidgetFormat.bytes(app.bytes))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let used = snapshot.mobileUsed {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.mobileQuota.map { String(localized: "Mobile: \(WidgetFormat.bytes(used)) / \(WidgetFormat.bytes($0))") }
                         ?? String(localized: "Mobile: \(WidgetFormat.bytes(used))"))
                        .font(.system(size: 11, weight: .medium))
                    if let quota = snapshot.mobileQuota, quota > 0 {
                        let fraction = min(1, Double(used) / Double(quota))
                        ProgressView(value: fraction)
                            .tint(fraction >= 1 ? .red : (fraction >= 0.8 ? .orange : .green))
                    }
                }
            } else if let event = snapshot.lastEvent {
                Text(event)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

/// The last 24 hours, one bar an hour.
private struct HourBars: View {
    let hours: [UInt64]
    let color: Color

    var body: some View {
        let top = Double(max(hours.max() ?? 0, 1))
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(hours.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color.opacity(value == 0 ? 0.18 : 0.85))
                        .frame(height: max(2, geometry.size.height * Double(value) / top))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
