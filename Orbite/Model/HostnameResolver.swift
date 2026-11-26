import Darwin
import Foundation
import Observation

/// Names behind addresses: DNS answers seen by the helper, and reverse DNS on demand.
@Observable
final class HostnameResolver {
    @ObservationIgnored private var dns: [String: String] = [:]
    @ObservationIgnored private var reverse: [String: String] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    /// Bumped when reverse names arrive, so the inspector refreshes.
    private(set) var revision = 0
    private(set) var dnsCount = 0

    func hostname(for address: String) -> String? { dns[address] }

    func ingest(_ mappings: [DNSMapping]) {
        guard !mappings.isEmpty else { return }
        for mapping in mappings {
            let address = IPAddress.normalize(mapping.address) ?? mapping.address
            dns[address] = mapping.hostname
        }
        if dns.count > 150_000 { dns.removeAll(keepingCapacity: true) }
        dnsCount = dns.count
    }

    /// Cached reverse name, or nil while the lookup runs ("" once it failed).
    func reverseName(for address: String) -> String? {
        if let known = reverse[address] { return known }
        guard !pending.contains(address), pending.count < 32 else { return nil }
        pending.insert(address)
        Task.detached(priority: .utility) {
            let name = Self.lookup(address) ?? ""
            await MainActor.run {
                self.reverse[address] = name
                self.pending.remove(address)
                self.revision += 1
            }
        }
        return nil
    }

    nonisolated static func lookup(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else {
            return nil
        }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
