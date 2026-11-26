import SwiftUI

/// Orbite's visual language in one place: pink for what leaves the Mac, blue for what comes in,
/// slate lines on the map, white pills, soft shadows.
enum Theme {
    static let upload = Color(red: 0.89, green: 0.39, blue: 0.95)
    static let download = Color(red: 0.09, green: 0.53, blue: 1.0)
    static let live = Color(red: 0.20, green: 0.84, blue: 0.55)

    static func uploadFill(_ scheme: ColorScheme) -> Color { upload.opacity(scheme == .dark ? 0.24 : 0.16) }
    static func downloadFill(_ scheme: ColorScheme) -> Color { download.opacity(scheme == .dark ? 0.24 : 0.15) }

    /// Connection lines: deep slate on the plan, luminous cyan on dark and satellite maps.
    static func line(_ scheme: ColorScheme, look: MapLook) -> Color {
        if look == .satellite || look == .hybrid { return Color(red: 0.55, green: 0.90, blue: 1.0) }
        if scheme == .dark { return Color(red: 0.42, green: 0.78, blue: 0.98) }
        return Color(red: 0.15, green: 0.37, blue: 0.46)
    }

    static func lineGlow(_ scheme: ColorScheme, look: MapLook) -> Color {
        if look == .satellite || look == .hybrid || scheme == .dark { return Color(red: 0.45, green: 0.85, blue: 1.0) }
        return Color(red: 0.20, green: 0.62, blue: 0.95)
    }

    static func pillBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.16) : .white
    }

    static func pillText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.95) : Color(white: 0.08)
    }

    /// Tags for trackers and for unencrypted traffic.
    static let tracker = Color.orange
    static let plaintext = Color.red

    /// Height of the blur where a scrolling panel meets a bottom edge.
    static let edgeBlur: CGFloat = 70

    static let track = Color.primary.opacity(0.07)
    static let sectionFill = Color.primary.opacity(0.05)

    static let selection = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let data = Animation.smooth(duration: 0.55)

    /// 0…1 level of a byte count on a log scale, for meters (≈100 o → 0.1, ≈100 Mo → 1).
    static func level(_ bytes: UInt64, ceiling: Double = 8) -> CGFloat {
        guard bytes > 0 else { return 0 }
        let value = (log10(Double(bytes)) - 1.5) / (ceiling - 1.5)
        return CGFloat(min(1, max(0.1, value)))
    }
}

enum Direction {
    case up, down

    var color: Color { self == .up ? Theme.upload : Theme.download }
    var symbol: String { self == .up ? "arrow.up" : "arrow.down" }
    var caption: String { self == .up ? String(localized: "sent") : String(localized: "received") }
}
