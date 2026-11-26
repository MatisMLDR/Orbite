import Darwin
import Foundation
import os

private let log = Logger(subsystem: HelperConstants.helperIdentifier, category: "dns")

/// Listens to DNS over UDP on every active interface and remembers, in memory only, which hostname
/// each address was returned for. Only responses to queries this Mac sent count (DNSQueryTracker).
final class DNSSniffer: @unchecked Sendable {
    private let lock = NSLock()
    /// address → (hostname, last time it was appended to the log)
    private var latest: [String: (hostname: String, logged: Date)] = [:]
    private var journal: [(sequence: UInt64, mapping: DNSMapping)] = []
    private var sequence: UInt64 = 0
    private var captures: [String: Capture] = [:]
    private var lastError: String?
    private let maxEntries = 50_000
    private let maxJournal = 20_000

    func start() {
        rescan()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.rescan() }
    }

    /// Mappings after `after`. Sequence 0 (a new client) or a gap gets the whole table.
    func mappings(after: UInt64) -> ([DNSMapping], UInt64) {
        lock.lock(); defer { lock.unlock() }
        let oldest = journal.first?.sequence ?? sequence + 1
        if after == 0 || after + 1 < oldest {
            let all = latest.map { DNSMapping(address: $0.key, hostname: $0.value.hostname, seenAt: $0.value.logged) }
            return (all, sequence)
        }
        let fresh = journal.drop { $0.sequence <= after }.map(\.mapping)
        return (Array(fresh), sequence)
    }

    func status() -> ([String], String?) {
        lock.lock(); defer { lock.unlock() }
        return (captures.keys.sorted(), lastError)
    }

    // MARK: - Recording

    fileprivate func record(_ answers: [DNSMessage.Answer]) {
        guard !answers.isEmpty else { return }
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        for answer in answers {
            if let known = latest[answer.address], known.hostname == answer.hostname,
               now.timeIntervalSince(known.logged) < 300 {
                continue
            }
            latest[answer.address] = (answer.hostname, now)
            sequence += 1
            journal.append((sequence, DNSMapping(address: answer.address, hostname: answer.hostname, seenAt: now)))
        }
        if journal.count > maxJournal { journal.removeFirst(journal.count - maxJournal) }
        if latest.count > maxEntries {
            let excess = latest.sorted { $0.value.logged < $1.value.logged }.prefix(latest.count - maxEntries + 5_000)
            for entry in excess { latest[entry.key] = nil }
        }
    }

    // MARK: - Interfaces

    private func rescan() {
        let wanted = Self.activeInterfaces()
        lock.lock()
        let current = captures
        lock.unlock()

        for (name, capture) in current where !wanted.contains(name) || !capture.isRunning {
            capture.stop()
            lock.lock(); captures[name] = nil; lock.unlock()
        }
        for name in wanted {
            lock.lock(); let exists = captures[name] != nil; lock.unlock()
            if exists { continue }
            do {
                let capture = try Capture(interface: name) { [weak self] answers in self?.record(answers) }
                lock.lock(); captures[name] = capture; lastError = nil; lock.unlock()
                log.info("capturing DNS on \(name, privacy: .public)")
            } catch {
                lock.lock(); lastError = "\(name): \(error.localizedDescription)"; lock.unlock()
                log.error("cannot capture on \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Up interfaces that carry routable traffic, plus lo0 for local DNS proxies.
    static func activeInterfaces() -> Set<String> {
        var result: Set<String> = ["lo0"]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for entry in Swift.sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("ap") { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                result.insert(name)
            case AF_INET6:
                // Interfaces with only a link-local IPv6 address (idle utun) carry no DNS.
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                }
                if !(bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) { result.insert(name) }
            default:
                break
            }
        }
        return result
    }

    /// The interface's own IPv4 and IPv6 addresses, as they appear in packet headers.
    static func localAddresses(of interface: String) -> Set<[UInt8]> {
        var result: Set<[UInt8]> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for entry in Swift.sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: entry.pointee.ifa_name) == interface, let address = entry.pointee.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }
                }
                result.insert(bytes)
            case AF_INET6:
                var bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                }
                // The kernel embeds the scope in bytes 2-3 of link-local addresses; packets carry zeros.
                if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { bytes[2] = 0; bytes[3] = 0 }
                result.insert(bytes)
            default:
                break
            }
        }
        return result
    }
}

private struct CaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One libpcap handle read on its own thread.
private final class Capture: @unchecked Sendable {
    let interface: String
    private let handle: OpaquePointer
    private let linkType: Int32
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let finished = OSAllocatedUnfairLock(initialState: false)

    var isRunning: Bool { !finished.withLock { $0 } }

    init(interface: String, onAnswers: @escaping @Sendable ([DNSMessage.Answer]) -> Void) throws {
        self.interface = interface
        var errorBuffer = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))
        guard let handle = pcap_create(interface, &errorBuffer) else {
            throw CaptureError(message: String(decoding: errorBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        pcap_set_snaplen(handle, 65_535)
        pcap_set_promisc(handle, 0)
        pcap_set_timeout(handle, 250)
        pcap_set_immediate_mode(handle, 1)
        guard pcap_activate(handle) >= 0 else {
            let message = String(cString: pcap_geterr(handle))
            pcap_close(handle)
            throw CaptureError(message: message)
        }
        var program = bpf_program()
        // Queries too: a response only counts if it answers one of them.
        guard pcap_compile(handle, &program, "udp port 53", 1, PCAP_NETMASK_UNKNOWN) == 0,
              pcap_setfilter(handle, &program) == 0 else {
            let message = String(cString: pcap_geterr(handle))
            pcap_freecode(&program)
            pcap_close(handle)
            throw CaptureError(message: message)
        }
        pcap_freecode(&program)
        self.handle = handle
        self.linkType = pcap_datalink(handle)

        let thread = Thread { [self] in self.run(onAnswers) }
        thread.name = "dns-\(interface)"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() { stopped.withLock { $0 = true } }

    private func run(_ onAnswers: @escaping @Sendable ([DNSMessage.Answer]) -> Void) {
        var header: UnsafeMutablePointer<pcap_pkthdr>?
        var data: UnsafePointer<UInt8>?
        var tracker = DNSQueryTracker()
        var localAddresses = DNSSniffer.localAddresses(of: interface)
        var addressesRead = ProcessInfo.processInfo.systemUptime
        while !stopped.withLock({ $0 }) {
            let status = pcap_next_ex(handle, &header, &data)
            if status == 0 { continue } // timeout
            guard status == 1, let header, let data else { break } // interface gone or error
            let frame = UnsafeRawBufferPointer(start: data, count: Int(header.pointee.caplen))
            guard let datagram = PacketDecoder.udpDatagram(linkType: linkType, frame: frame) else { continue }
            let now = ProcessInfo.processInfo.systemUptime
            if now - addressesRead > 10 { // DHCP renewals, new IPv6 privacy addresses
                localAddresses = DNSSniffer.localAddresses(of: interface)
                addressesRead = now
            }
            let answers = tracker.handle(datagram, localAddresses: localAddresses, now: now)
            if !answers.isEmpty { onAnswers(answers) }
        }
        pcap_close(handle)
        finished.withLock { $0 = true }
    }
}
