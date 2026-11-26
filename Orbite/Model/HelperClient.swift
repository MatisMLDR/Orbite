import Foundation
import Observation
import ServiceManagement
import os

nonisolated private let log = Logger(subsystem: "app.matis.Orbite", category: "helper")

/// Installs, watches and talks to the privileged DNS helper.
@Observable
final class HelperClient {
    enum State: Equatable {
        case notInstalled
        case needsApproval
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .notInstalled: String(localized: "Off")
            case .needsApproval: String(localized: "Waiting for approval")
            case .starting: String(localized: "Starting…")
            case .running: String(localized: "On")
            case .failed(let message): String(localized: "Error: \(message)")
            }
        }
    }

    private(set) var state: State = .notInstalled
    private(set) var interfaces: [String] = []
    private(set) var captureError: String?

    @ObservationIgnored var onMappings: ([DNSMapping]) -> Void = { _ in }
    @ObservationIgnored private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var versionChecked = false
    @ObservationIgnored private var restartAttempts = 0
    /// Counts DNS polls: the capture status (shown in Réglages only) is asked one time in ten.
    @ObservationIgnored private var pollCount = 0

    @ObservationIgnored private lazy var bundledVersion: String = {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "OrbiteHelper") else { return "" }
        return HelperConstants.digest(ofFileAt: url.path)
    }()

    func start() {
        refreshStatus()
        // Stays at 1 s: a flow takes its name when it is first seen, so DNS answers must be early.
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
        timer.tolerance = 0.2
        self.timer = timer
    }

    var isEnabled: Bool { state == .running || state == .starting }

    func enable() {
        do {
            try service.register()
            log.info("helper registered")
        } catch {
            log.error("register failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func disable() {
        connection?.invalidate()
        connection = nil
        Task {
            do { try await service.unregister() } catch {
                log.error("unregister failed: \(error.localizedDescription, privacy: .public)")
            }
            refreshStatus()
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func heartbeat() {
        if connection == nil || state != .running { refreshStatus() }
        poll()
    }

    func refreshStatus() {
        switch service.status {
        case .enabled:
            if connection == nil { connect() }
        case .requiresApproval:
            state = .needsApproval
        case .notRegistered, .notFound:
            state = .notInstalled
        @unknown default:
            state = .notInstalled
        }
    }

    private func connect() {
        state = .starting
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: OrbiteHelperProtocol.self)
        connection.setCodeSigningRequirement(HelperConstants.helperRequirement)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connectionLost() }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connectionLost() }
        }
        connection.resume()
        self.connection = connection
        versionChecked = false
        sequence = 0
        pollCount = 0
    }

    private func connectionLost() {
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
        polling = false
        if service.status == .enabled { state = .starting }
    }

    private func proxy() -> OrbiteHelperProtocol? {
        // Called on an XPC queue: @Sendable keeps it off the main actor (an isolated closure traps there).
        connection?.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            log.error("xpc: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor in self?.connectionLost() }
        } as? OrbiteHelperProtocol
    }

    private func poll() {
        guard let helper = proxy(), !polling else { return }
        polling = true
        if !versionChecked {
            let expected = bundledVersion
            helper.helperVersion { [weak self] version in
                Task { @MainActor in
                    guard let self else { return }
                    self.polling = false
                    if version != expected, !expected.isEmpty, self.restartAttempts < 3 {
                        // Rebuilt app: launchd restarts the daemon from the new binary.
                        log.notice("helper out of date, restarting it")
                        self.restartAttempts += 1
                        self.proxy()?.exitForUpdate()
                        self.connectionLost()
                        return
                    }
                    self.versionChecked = true
                    self.restartAttempts = 0
                    self.state = .running
                }
            }
            return
        }
        let after = sequence
        helper.dnsMappings(after: after) { [weak self] data, latest in
            let mappings = (try? PropertyListDecoder().decode([DNSMapping].self, from: data)) ?? []
            Task { @MainActor in
                guard let self else { return }
                self.polling = false
                self.sequence = latest
                if self.state != .running { self.state = .running }
                self.onMappings(mappings)
            }
        }
        pollCount += 1
        guard pollCount % 10 == 1 else { return }
        helper.captureStatus { [weak self] interfaces, error in
            Task { @MainActor in
                guard let self else { return }
                if self.interfaces != interfaces { self.interfaces = interfaces }
                if self.captureError != error { self.captureError = error }
            }
        }
    }
}
