import Foundation
import Observation
import os

nonisolated private let log = Logger(subsystem: "app.matis.Orbite", category: "trackers")

/// Downloads DuckDuckGo's tracker lists (CC BY-NC-SA 4.0) and keeps them a week fresh. Matching happens
/// on this Mac: no hostname ever leaves it.
@Observable
final class TrackerListUpdater {
    enum Phase: Equatable {
        case missing
        case downloading
        case ready(Int)
        case failed(String)
    }

    private(set) var phase: Phase = .missing
    private(set) var updatedAt: Date?
    @ObservationIgnored var onList: (TrackerList) -> Void = { _ in }

    nonisolated static var directory: URL { HistoryStore.directory.appendingPathComponent("Trackers", isDirectory: true) }
    nonisolated static var webFile: URL { directory.appendingPathComponent("web-tds.json") }
    nonisolated static var appsFile: URL { directory.appendingPathComponent("apps-tds.json") }
    private static let webURL = URL(string: "https://staticcdn.duckduckgo.com/trackerblocking/v6/current/macos-tds.json")!
    private static let appsURL = URL(string: "https://raw.githubusercontent.com/duckduckgo/tracker-blocklists/main/app/android-tds.json")!
    private static let maxAge: TimeInterval = 7 * 86_400

    var isDownloading: Bool { phase == .downloading }

    /// Opens the lists on disk, then refreshes them in the background when they are a week old.
    func start() {
        let modified = (try? Self.webFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        updatedAt = modified
        guard modified != nil else {
            Task { await download(silently: true) }
            return
        }
        Task {
            if let list = await Self.load() {
                phase = .ready(list.count)
                onList(list)
            }
            if let modified, Date().timeIntervalSince(modified) > Self.maxAge { await download(silently: true) }
        }
    }

    func download(silently: Bool = false) async {
        guard !isDownloading else { return }
        let wasReady = if case .ready = phase { true } else { false }
        if !silently || !wasReady { phase = .downloading }
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            for (url, target) in [(Self.webURL, Self.webFile), (Self.appsURL, Self.appsFile)] {
                let file = try await Downloader.fetch(url)
                defer { try? FileManager.default.removeItem(at: file) }
                // A list that does not parse never replaces a good one.
                try await Task.detached(priority: .utility) {
                    _ = try JSONDecoder().decode(TDSFile.self, from: Data(contentsOf: file))
                }.value
                _ = try FileManager.default.replaceItemAt(target, withItemAt: file)
            }
            guard let list = await Self.load() else { throw CocoaError(.fileReadCorruptFile) }
            updatedAt = Date()
            phase = .ready(list.count)
            onList(list)
            log.info("tracker lists installed: \(list.count) entries")
        } catch {
            log.error("tracker lists download failed: \(error.localizedDescription, privacy: .public)")
            if !silently || !wasReady { phase = .failed(error.localizedDescription) }
        }
    }

    private nonisolated static func load() async -> TrackerList? {
        await Task.detached(priority: .utility) {
            let web = try? Data(contentsOf: webFile)
            let apps = try? Data(contentsOf: appsFile)
            guard web != nil || apps != nil else { return nil }
            return try? TrackerList.parse(web: web, apps: apps)
        }.value
    }
}
