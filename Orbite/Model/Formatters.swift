import Darwin
import Foundation

/// Formatting of sizes, rates, ports and places, in the app's language (« 1,76 Mo », « 1.76 MB »).
nonisolated enum Format {
    /// The language Orbite shows (English or French) with the Mac's region, for numbers and dates.
    nonisolated(unsafe) static var locale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: Locale.current.region.map { "\(language)_\($0.identifier)" } ?? language)
    }()

    static var isFrench: Bool { locale.language.languageCode == .french }

    private static var units: [String] {
        isFrench ? ["o", "Ko", "Mo", "Go", "To", "Po"] : ["B", "KB", "MB", "GB", "TB", "PB"]
    }

    /// Three significant digits: « 512 o », « 1,76 Mo », « 49,7 Mo », « 412 Mo ».
    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    static func bytes(_ value: Double) -> String {
        let (scaled, unit) = scale(value)
        if unit == 0 { return "\(Int(scaled.rounded())) \(units[0])" }
        return "\(decimal(scaled)) \(units[unit])"
    }

    /// The value in its unit, and the unit's rank (0 for bytes, 1 for kilo…).
    private static func scale(_ value: Double) -> (Double, Int) {
        guard value >= 1 else { return (0, 0) }
        var scaled = value
        var unit = 0
        while scaled >= 999.5, unit < 5 {
            scaled /= 1000
            unit += 1
        }
        return (scaled, unit)
    }

    /// « 4,2 Mo/s ». Zero reads « 0 o/s ».
    static func rate(_ bytesPerSecond: Double) -> String {
        "\(bytes(bytesPerSecond))/s"
    }

    /// Compact rate for tight places: « 4,2 M », « 120 K », « 0 ».
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let (scaled, unit) = scale(bytesPerSecond)
        if unit == 0 { return "\(Int(scaled.rounded()))" }
        return "\(decimal(scaled)) \(["", "K", "M", "G", "T", "P"][unit])"
    }

    /// Fixed digits with the region's decimal separator.
    static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }

    private static func decimal(_ value: Double) -> String {
        decimal(value, digits: value >= 99.95 ? 0 : (value >= 9.995 ? 1 : 2))
    }

    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// « 3 connexions », « 1 connection »: French counts 0 and 1 as singular, English only 1.
    static func plural(_ value: Int, _ singular: LocalizedStringResource, _ plural: LocalizedStringResource) -> String {
        let one = isFrench ? value <= 1 : value == 1
        return "\(count(value)) \(String(localized: one ? singular : plural))"
    }

    /// « https (443) », « quic (443) », « 5223 ».
    static func port(_ port: Int, transport: TransportKind) -> String {
        if transport == .quic { return "quic (\(port))" }
        let proto = transport == .udp ? "udp" : "tcp"
        guard let entry = getservbyport(Int32(UInt16(port).bigEndian), proto), let name = entry.pointee.s_name else {
            return "\(port)"
        }
        return "\(String(cString: name)) (\(port))"
    }

    /// Regional indicator emoji for an ISO country code.
    static func flag(_ countryCode: String?) -> String {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return "🌐" }
        let scalars = code.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
        guard scalars.count == 2 else { return "🌐" }
        return String(String.UnicodeScalarView(scalars))
    }

    static func distance(kilometers: Double) -> String {
        if kilometers < 1 { return String(localized: "less than 1 km") }
        return "\(count(Int(kilometers.rounded()))) km"
    }

    static func milliseconds(_ value: Double) -> String {
        value < 10 ? "\(decimal(value, digits: 1)) ms" : "\(Int(value.rounded())) ms"
    }

    /// « 3,2× », « 15× ».
    static func factor(_ value: Double) -> String {
        let text = value < 9.95 ? decimal(value, digits: 1) : "\(Int(value.rounded()))"
        return text + "×"
    }

    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        let text = decimal(value, digits: value < 10 ? 1 : 0)
        return isFrench ? text + " %" : text + "%"
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    /// « Aujourd'hui », « Hier », « Lundi 17 novembre ».
    static func dayHeader(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale)).capitalizedFirstLetter
    }

    /// « aujourd'hui à 14:05 », « hier à 09:12 », « le 17 nov. à 14:05 ».
    static func moment(_ date: Date, calendar: Calendar = .current) -> String {
        let time = time(date)
        if calendar.isDateInToday(date) { return String(localized: "today at \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "yesterday at \(time)") }
        let day = date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        return String(localized: "on \(day) at \(time)")
    }

    /// An hour of the day: « 14 h », « 2 PM ».
    static func hour(_ hour: Int) -> String {
        guard let date = Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: Date()) else { return "\(hour)" }
        if isFrench { return "\(hour) h" }
        return date.formatted(.dateTime.hour().locale(locale))
    }

    /// « 2 h 10 », « 45 min »; « 2h 10m » in English.
    static func duration(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if !isFrench { return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m" }
        return rest == 0 ? "\(hours) h" : String(format: "%d h %02d", hours, rest)
    }

    /// « il y a 3 min », « à l'instant ».
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return String(localized: "just now") }
        if seconds < 60 { return String(localized: "\(seconds) s ago") }
        if seconds < 3600 { return String(localized: "\(seconds / 60) min ago") }
        if seconds < 86_400 { return String(localized: "\(seconds / 3600) h ago") }
        return String(localized: "\(seconds / 86_400) d ago")
    }

    /// Describes a time window: « En direct · 5 dernières minutes », « Aujourd'hui 14:00 – 15:00 ».
    static func window(_ window: TimeWindow, now: Int) -> String {
        guard let end = window.end else { return String(localized: "Live") }
        let start = Date(timeIntervalSince1970: TimeInterval(end - window.span.seconds))
        let stop = Date(timeIntervalSince1970: TimeInterval(end))
        let calendar = Calendar.current
        func day(_ date: Date) -> String {
            if calendar.isDateInToday(date) { return String(localized: "Today") }
            if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)).capitalized
        }
        if window.span == .week {
            return "\(start.formatted(.dateTime.day().month(.abbreviated).locale(locale))) – \(stop.formatted(.dateTime.day().month(.abbreviated).locale(locale)))"
        }
        if calendar.isDate(start, inSameDayAs: stop.addingTimeInterval(-1)) {
            return "\(day(start)) \(time(start)) – \(time(stop))"
        }
        return "\(day(start)) \(time(start)) – \(day(stop)) \(time(stop))"
    }
}

nonisolated extension String {
    /// First letter upper-cased, the rest untouched (« lundi » → « Lundi »).
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
