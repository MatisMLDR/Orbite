import AppIntents
import Foundation

/// Shortcuts and Spotlight actions. They run inside Orbite, which launches if needed.
nonisolated enum OrbiteIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource { "Orbite is still starting: try again in a moment." }
}

nonisolated struct CurrentRateIntent: AppIntent {
    static let title: LocalizedStringResource = "Current Rate"
    static let description = IntentDescription("What your Mac sends and receives right now.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let model = AppModel.current else { throw OrbiteIntentError.notReady }
        let rate = model.store.totalRate
        let text = "↑ \(Format.rate(rate.outPerSecond)) · ↓ \(Format.rate(rate.inPerSecond))"
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

nonisolated struct TodayTrafficIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Traffic"
    static let description = IntentDescription("Everything your Mac has sent and received since midnight.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let model = AppModel.current else { throw OrbiteIntentError.notReady }
        let total = model.store.total(from: Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970))
        let text = String(localized: "Today: \(Format.bytes(total.total)) (↑ \(Format.bytes(total.bytesOut)) · ↓ \(Format.bytes(total.bytesIn)))")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

nonisolated struct TopAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Most Active App Today"
    static let description = IntentDescription("The app that has exchanged the most since midnight.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let model = AppModel.current else { throw OrbiteIntentError.notReady }
        let store = model.store
        let now = store.now
        let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let top = store.apps.values
            .map { ($0, $0.stats.buckets.sum(from: start, to: now + 1, now: now).total) }
            .max { $0.1 < $1.1 }
        let text = top.map { String(localized: "\($0.0.identity.name): \(Format.bytes($0.1)) today") } ?? String(localized: "No traffic today")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

nonisolated struct MobileDataIntent: AppIntent {
    static let title: LocalizedStringResource = "Mobile Data This Month"
    static let description = IntentDescription("What went through Personal Hotspot or cellular since the plan reset.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let model = AppModel.current else { throw OrbiteIntentError.notReady }
        let networks = model.networks
        let used = networks.mobileUsage().total.total
        let quota = networks.quotaGB * 1_000_000_000
        let text = quota > 0
            ? String(localized: "Mobile data: \(Format.bytes(used)) of \(Format.bytes(quota)) (\(Format.percent(Double(used) / quota)))")
            : String(localized: "Mobile data: \(Format.bytes(used)) since the start of the cycle")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

nonisolated struct RunDiagnosisIntent: AppIntent {
    static let title: LocalizedStringResource = "Why Is It Slow?"
    static let description = IntentDescription("Measures the router and the internet for a few seconds, then tells where the slowness comes from.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let model = AppModel.current else { throw OrbiteIntentError.notReady }
        await model.diagnosis.run(model: model)
        let verdict = model.diagnosis.result?.verdict
        let text = verdict.map { "\($0.title). \($0.detail)" } ?? String(localized: "The diagnosis did not complete.")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// An app Orbite has seen, for « Open Orbite on an App ».
nonisolated struct OrbiteAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static let defaultQuery = OrbiteAppQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct OrbiteAppQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [OrbiteAppEntity] {
        guard let store = AppModel.current?.store else { return [] }
        return identifiers.compactMap { id in store.apps[id].map { OrbiteAppEntity(id: $0.id, name: $0.identity.name) } }
    }

    @MainActor
    func entities(matching string: String) async throws -> [OrbiteAppEntity] {
        let query = SearchIndex.fold(string)
        return try await suggestedEntities().filter { SearchIndex.fold($0.name).contains(query) }
    }

    @MainActor
    func suggestedEntities() async throws -> [OrbiteAppEntity] {
        guard let store = AppModel.current?.store else { return [] }
        return store.apps.values
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(50)
            .map { OrbiteAppEntity(id: $0.id, name: $0.identity.name) }
    }
}

/// Not `nonisolated` as a whole: its `@Parameter` storage cannot be.
struct OpenAppInOrbiteIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Open Orbite on an App"
    nonisolated static let description = IntentDescription("Opens Orbite's window on an app: its domains, its places, its traffic.")
    nonisolated static let openAppWhenRun = true

    @Parameter(title: "App")
    var app: OrbiteAppEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.current else { throw OrbiteIntentError.notReady }
        model.open(selecting: .app(app.id))
        return .result()
    }
}

nonisolated struct OrbiteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CurrentRateIntent(), phrases: ["Current rate in \(.applicationName)",
                                                           "What is my rate with \(.applicationName)"],
                    shortTitle: "Current Rate", systemImageName: "arrow.up.arrow.down")
        AppShortcut(intent: TodayTrafficIntent(), phrases: ["Today's traffic in \(.applicationName)"],
                    shortTitle: "Today's Traffic", systemImageName: "calendar")
        AppShortcut(intent: TopAppIntent(), phrases: ["Most active app in \(.applicationName)"],
                    shortTitle: "Most Active App", systemImageName: "trophy")
        AppShortcut(intent: MobileDataIntent(), phrases: ["Mobile data in \(.applicationName)"],
                    shortTitle: "Mobile Data", systemImageName: "personalhotspot")
        AppShortcut(intent: RunDiagnosisIntent(), phrases: ["Why is it slow with \(.applicationName)",
                                                            "Network diagnosis with \(.applicationName)"],
                    shortTitle: "Why Is It Slow?", systemImageName: "stethoscope")
        AppShortcut(intent: OpenAppInOrbiteIntent(), phrases: ["Open \(.applicationName) on an app"],
                    shortTitle: "Open on an App", systemImageName: "app")
    }
}
