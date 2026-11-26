import Darwin
import Foundation

/// Round trips of a few pings to one address.
nonisolated struct PingStats: Sendable, Equatable {
    var sent: Int
    var received: Int
    /// Median round trip in milliseconds.
    var median: Double?

    var loss: Double { sent == 0 ? 0 : Double(sent - received) / Double(sent) }
    /// Nothing came back: the host may simply ignore pings.
    var silent: Bool { received == 0 }
}

/// ICMP echo without privileges (a datagram ICMP socket), IPv4 only. Used only while a diagnosis runs.
nonisolated enum Pinger {
    private static let magic: [UInt8] = Array("ORBITEpg".utf8)

    static func ping(_ address: String, count: Int = 10, interval: TimeInterval = 0.2,
                     timeout: TimeInterval = 1) async -> PingStats? {
        await Task.detached(priority: .userInitiated) {
            run(address, count: count, interval: interval, timeout: timeout)
        }.value
    }

    private static func run(_ address: String, count: Int, interval: TimeInterval, timeout: TimeInterval) -> PingStats? {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else { return nil }
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }

        let identifier = UInt16.random(in: 1...UInt16.max)
        var rtts: [Double] = []
        var buffer = [UInt8](repeating: 0, count: 1500)
        for sequence in 0..<count {
            let packet = echoRequest(identifier: identifier, sequence: UInt16(sequence))
            let start = DispatchTime.now().uptimeNanoseconds
            let sent = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socketFD, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent >= 0 {
                let deadline = start + UInt64(timeout * 1e9)
                while true {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { break }
                    let remaining = deadline - now
                    var wait = timeval(tv_sec: Int(remaining / 1_000_000_000),
                                       tv_usec: Int32((remaining % 1_000_000_000) / 1000))
                    setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
                    let received = recv(socketFD, &buffer, buffer.count, 0)
                    guard received > 0 else { break }
                    if isReply(buffer[0..<received], sequence: UInt16(sequence)) {
                        rtts.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                        break
                    }
                }
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if sequence < count - 1, elapsed < interval { usleep(useconds_t((interval - elapsed) * 1e6)) }
        }
        let sorted = rtts.sorted()
        let median = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        return PingStats(sent: count, received: rtts.count, median: median)
    }

    static func echoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0, UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                               UInt8(sequence >> 8), UInt8(sequence & 0xFF)] + magic
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    /// An echo reply for `sequence` carrying our payload. macOS hands datagram ICMP sockets the IP header too.
    static func isReply(_ data: ArraySlice<UInt8>, sequence: UInt16) -> Bool {
        let bytes = Array(data)
        var offset = 0
        if let first = bytes.first, first >> 4 == 4 { offset = Int(first & 0x0F) * 4 }
        guard bytes.count >= offset + 8 + magic.count, bytes[offset] == 0 else { return false }
        let replySequence = UInt16(bytes[offset + 6]) << 8 | UInt16(bytes[offset + 7])
        return replySequence == sequence && Array(bytes[(offset + 8)..<(offset + 8 + magic.count)]) == magic
    }

    /// RFC 1071 Internet checksum.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
