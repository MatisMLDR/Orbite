import Foundation

/// What the desktop widget shows, written by Orbite into the shared app group container.
nonisolated struct WidgetSnapshot: Codable, Sendable, Equatable {
    struct App: Codable, Sendable, Equatable {
        var name: String
        var bytes: UInt64
    }

    var date: Date
    var todayIn: UInt64
    var todayOut: UInt64
    /// Bytes per hour over the last 24 hours, oldest first.
    var hours: [UInt64]
    var topApps: [App]
    var mobileUsed: UInt64?
    var mobileQuota: UInt64?
    var lastEvent: String?

    var todayTotal: UInt64 { todayIn + todayOut }

    /// Prefixed with the signing team, read from the Info.plist of the app and of the widget.
    static let groupIdentifier = "\(Bundle.main.object(forInfoDictionaryKey: "OrbiteTeamID") as? String ?? "").app.matis.Orbite"
    static let widgetKind = "OrbiteTraffic"

    static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appendingPathComponent("widget.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static let placeholder = WidgetSnapshot(
        date: Date(), todayIn: 1_840_000_000, todayOut: 212_000_000,
        hours: [3, 2, 1, 1, 0, 0, 1, 4, 9, 12, 8, 7, 10, 14, 9, 6, 8, 11, 15, 18, 12, 9, 6, 4].map { $0 * 20_000_000 },
        topApps: [App(name: "Safari", bytes: 920_000_000), App(name: "Spotify", bytes: 410_000_000),
                  App(name: "Mail", bytes: 96_000_000)],
        mobileUsed: nil, mobileQuota: nil, lastEvent: nil)
}

/// The widget runs without Orbite's formatters: the same sizes, kept short, in the widget's language.
nonisolated enum WidgetFormat {
    static func bytes(_ value: UInt64) -> String {
        let french = Bundle.main.preferredLocalizations.first == "fr"
        let units = french ? ["o", "Ko", "Mo", "Go", "To"] : ["B", "KB", "MB", "GB", "TB"]
        var scaled = Double(value)
        var unit = 0
        while scaled >= 999.5, unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        if unit == 0 { return "\(value) \(units[0])" }
        let digits = scaled >= 99.95 ? 0 : (scaled >= 9.995 ? 1 : 2)
        let separator = Locale.current.decimalSeparator ?? "."
        return String(format: "%.\(digits)f", scaled).replacingOccurrences(of: ".", with: separator) + " \(units[unit])"
    }
}
