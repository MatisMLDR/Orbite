import Darwin
import Foundation
import os

// Orbite's privileged helper: a launchd daemon (SMAppService) that reads DNS responses so the app
// can show the hostname behind each connection. It keeps everything in memory, writes nothing
// to disk, makes no network request and only answers the Orbite app signed by our team.

private let log = Logger(subsystem: HelperConstants.helperIdentifier, category: "service")

final class HelperService: NSObject, NSXPCListenerDelegate, OrbiteHelperProtocol, @unchecked Sendable {
    private let sniffer: DNSSniffer
    private let version: String

    init(sniffer: DNSSniffer, version: String) {
        self.sniffer = sniffer
        self.version = version
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: OrbiteHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func helperVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(version)
    }

    func dnsMappings(after sequence: UInt64, reply: @escaping @Sendable (Data, UInt64) -> Void) {
        let (mappings, latest) = sniffer.mappings(after: sequence)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        reply((try? encoder.encode(mappings)) ?? Data(), latest)
    }

    func captureStatus(reply: @escaping @Sendable ([String], String?) -> Void) {
        let (interfaces, error) = sniffer.status()
        reply(interfaces, error)
    }

    func exitForUpdate() {
        log.info("exiting so launchd restarts the updated helper")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }
}

private func executablePath() -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return CommandLine.arguments[0] }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

let sniffer = DNSSniffer()
sniffer.start()

let service = HelperService(sniffer: sniffer, version: HelperConstants.digest(ofFileAt: executablePath()))
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.setConnectionCodeSigningRequirement(HelperConstants.appRequirement)
listener.delegate = service
listener.resume()
log.info("helper started")
RunLoop.main.run()
