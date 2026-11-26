import Foundation

/// Something ⌘K can find: an entity of the history, whatever the window, or an action.
nonisolated struct SearchItem: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable {
        case action, app, domain, organization, place, country, tracker, network

        var label: String {
            switch self {
            case .action: String(localized: "Action")
            case .app: String(localized: "App")
            case .domain: String(localized: "Domain")
            case .organization: String(localized: "Organization")
            case .place: String(localized: "Place")
            case .country: String(localized: "Country")
            case .tracker: String(localized: "Tracker")
            case .network: String(localized: "Network")
            }
        }
    }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    /// More text that matches, but less than the title (hostnames, countries…).
    var keywords: [String] = []
    /// Bytes over the last week: busier first among equal matches.
    var weight: Double = 0
    var lastSeen: Int?
    /// What choosing it does, read by the palette: « app:<id> », « host:<id> », « site:<id> », « action:<name> »…
    var payload: String
}

/// Ranks items for a query: title prefix, then word prefix, then anywhere, accents and case ignored.
nonisolated enum SearchIndex {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    /// Higher is better; nil when it does not match.
    static func score(_ query: String, _ item: SearchItem) -> Int? {
        let title = fold(item.title)
        if title == query { return 100 }
        // « tiktok » names tiktok.com more than tiktokcdn.com.
        if title.hasPrefix(query), let next = title.dropFirst(query.count).first, next == "." || next == " " { return 90 }
        if title.hasPrefix(query) { return 80 }
        let separators = CharacterSet(charactersIn: " .-_·/()")
        if title.components(separatedBy: separators).contains(where: { $0.hasPrefix(query) }) { return 60 }
        if title.contains(query) { return 40 }
        for keyword in item.keywords {
            let folded = fold(keyword)
            if folded.hasPrefix(query) { return 30 }
            if folded.contains(query) { return 20 }
        }
        return nil
    }

    static func rank(_ query: String, in items: [SearchItem], limit: Int = 12) -> [SearchItem] {
        let query = fold(query.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else { return Array(items.prefix(limit)) }
        // Actions only when asked by name; entities first among equals, the busiest leading.
        return items.compactMap { item in score(query, item).map { (item, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.weight != rhs.0.weight { return lhs.0.weight > rhs.0.weight }
                return lhs.0.title.count < rhs.0.title.count
            }
            .prefix(limit)
            .map(\.0)
    }
}
