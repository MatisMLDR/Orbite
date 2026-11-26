import Foundation
import Observation
import os

nonisolated private let log = Logger(subsystem: "app.matis.Orbite", category: "geoip")

/// Downloads DB-IP City Lite and ASN Lite (CC BY 4.0) and keeps them a month fresh.
@Observable
final class GeoDBUpdater {
    enum Phase: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .missing
    /// « 2026-11 »
    private(set) var month: String?
    @ObservationIgnored var onDatabase: (GeoDatabase) -> Void = { _ in }

    static var directory: URL { HistoryStore.directory.appendingPathComponent("GeoIP", isDirectory: true) }
    static var cityFile: URL { directory.appendingPathComponent("city.mmdb") }
    static var asnFile: URL { directory.appendingPathComponent("asn.mmdb") }
    private static let monthKey = "geoDatabaseMonth"

    var isReady: Bool { phase == .ready }
    var isDownloading: Bool { if case .downloading = phase { true } else { false } }

    /// Opens the databases already on disk, then refreshes them in the background if a new month is out.
    func start() {
        month = UserDefaults.standard.string(forKey: Self.monthKey)
        if FileManager.default.fileExists(atPath: Self.cityFile.path) {
            let database = GeoDatabase(cityPath: Self.cityFile.path, asnPath: Self.asnFile.path)
            if database.isUsable {
                phase = .ready
                onDatabase(database)
                let day = Calendar.current.component(.day, from: Date())
                var refresh = month != Self.monthString(Date()) && day >= 3
                #if DEBUG
                // Screenshot mode reads a copy: no download.
                if Demo.isActive { refresh = false }
                #endif
                if refresh {
                    Task { await download(silently: true) }
                }
                return
            }
        }
        phase = .missing
    }

    func download(silently: Bool = false) async {
        guard !isDownloading else { return }
        if !silently || phase != .ready { phase = .downloading(0) }
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            var lastError: Error?
            for monthsBack in 0...1 {
                let date = Calendar.current.date(byAdding: .month, value: -monthsBack, to: Date()) ?? Date()
                let tag = Self.monthString(date)
                do {
                    try await fetch(tag: tag, silently: silently)
                    UserDefaults.standard.set(tag, forKey: Self.monthKey)
                    month = tag
                    let database = GeoDatabase(cityPath: Self.cityFile.path, asnPath: Self.asnFile.path)
                    guard database.isUsable else { throw DownloadError.invalid }
                    phase = .ready
                    onDatabase(database)
                    log.info("GeoIP databases \(tag, privacy: .public) installed")
                    return
                } catch DownloadError.notPublished {
                    lastError = DownloadError.notPublished
                    continue
                }
            }
            throw lastError ?? DownloadError.notPublished
        } catch {
            log.error("GeoIP download failed: \(error.localizedDescription, privacy: .public)")
            if !silently || phase != .ready { phase = .failed(error.localizedDescription) }
        }
    }

    enum DownloadError: LocalizedError {
        case notPublished, invalid, gunzip

        var errorDescription: String? {
            switch self {
            case .notPublished: String(localized: "This month's DB-IP database is not published yet.")
            case .invalid: String(localized: "The downloaded file cannot be read.")
            case .gunzip: String(localized: "Decompressing failed.")
            }
        }
    }

    private func fetch(tag: String, silently: Bool) async throws {
        let parts: [(name: String, target: URL, weight: Double, offset: Double)] = [
            ("dbip-city-lite-\(tag).mmdb.gz", Self.cityFile, 0.92, 0),
            ("dbip-asn-lite-\(tag).mmdb.gz", Self.asnFile, 0.08, 0.92),
        ]
        for part in parts {
            let url = URL(string: "https://download.db-ip.com/free/\(part.name)")!
            let compressed: URL
            do {
                compressed = try await Downloader.fetch(url) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, !silently || self.phase != .ready else { return }
                        self.phase = .downloading(part.offset + fraction * part.weight)
                    }
                }
            } catch Downloader.Failure.notFound {
                throw DownloadError.notPublished
            }
            defer { try? FileManager.default.removeItem(at: compressed) }
            let temporary = part.target.appendingPathExtension("new")
            try await Self.gunzip(compressed, to: temporary)
            _ = try FileManager.default.replaceItemAt(part.target, withItemAt: temporary)
        }
    }

    private nonisolated static func gunzip(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            process.arguments = ["-c", source.path]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw DownloadError.gunzip }
        }.value
    }

    static func monthString(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 2026, components.month ?? 1)
    }
}
