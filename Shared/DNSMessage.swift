import Darwin
import Foundation

/// Minimal DNS response parser: keeps the name that was asked for and every A/AAAA address
/// in the answer section, following CNAME chains implicitly (all answers map to the question).
nonisolated enum DNSMessage {
    struct Answer: Equatable, Sendable {
        var address: String
        var hostname: String
    }

    /// Transaction ID, direction and first question of a query or a response.
    struct Question: Equatable, Sendable {
        var id: UInt16
        var isResponse: Bool
        var name: String
    }

    static func question(in message: [UInt8]) -> Question? {
        guard message.count >= 12 else { return nil }
        let id = UInt16(message[0]) << 8 | UInt16(message[1])
        let isResponse = message[2] & 0x80 != 0
        let questions = Int(UInt16(message[4]) << 8 | UInt16(message[5]))
        guard questions >= 1, let (name, _) = readName(message, at: 12) else { return nil }
        return Question(id: id, isResponse: isResponse, name: name)
    }

    static func answers(in message: [UInt8]) -> [Answer] {
        guard message.count >= 12 else { return [] }
        let flags = UInt16(message[2]) << 8 | UInt16(message[3])
        let isResponse = flags & 0x8000 != 0
        let rcode = flags & 0x000F
        let questions = Int(UInt16(message[4]) << 8 | UInt16(message[5]))
        let answerCount = Int(UInt16(message[6]) << 8 | UInt16(message[7]))
        guard isResponse, rcode == 0, questions >= 1, answerCount >= 1 else { return [] }

        var offset = 12
        var questionName: String?
        for _ in 0..<questions {
            guard let (name, next) = readName(message, at: offset), next + 4 <= message.count else { return [] }
            if questionName == nil { questionName = name }
            offset = next + 4 // QTYPE + QCLASS
        }
        guard let asked = questionName, !asked.isEmpty, !asked.hasSuffix(".arpa") else { return [] }

        var result: [Answer] = []
        for _ in 0..<answerCount {
            guard let (_, next) = readName(message, at: offset), next + 10 <= message.count else { break }
            let type = UInt16(message[next]) << 8 | UInt16(message[next + 1])
            let length = Int(UInt16(message[next + 8]) << 8 | UInt16(message[next + 9]))
            let dataStart = next + 10
            guard dataStart + length <= message.count else { break }
            let data = Array(message[dataStart..<dataStart + length])
            if type == 1, length == 4, let text = IPText.format(data) {
                result.append(Answer(address: text, hostname: asked))
            } else if type == 28, length == 16, let text = IPText.format(data) {
                result.append(Answer(address: text, hostname: asked))
            }
            offset = dataStart + length
        }
        return result
    }

    /// Reads a possibly compressed name. Returns the lowercased name without the final dot,
    /// and the offset just after the name in the original position.
    static func readName(_ message: [UInt8], at start: Int) -> (String, Int)? {
        var labels: [String] = []
        var offset = start
        var end: Int?
        var jumps = 0
        while true {
            guard offset < message.count else { return nil }
            let length = Int(message[offset])
            if length == 0 {
                if end == nil { end = offset + 1 }
                break
            }
            if length & 0xC0 == 0xC0 {
                guard offset + 1 < message.count, jumps < 16 else { return nil }
                if end == nil { end = offset + 2 }
                offset = (length & 0x3F) << 8 | Int(message[offset + 1])
                jumps += 1
                continue
            }
            guard length <= 63, offset + 1 + length <= message.count else { return nil }
            labels.append(String(decoding: message[(offset + 1)...(offset + length)], as: UTF8.self))
            offset += 1 + length
            guard labels.count < 128 else { return nil }
        }
        return (labels.joined(separator: ".").lowercased(), end ?? offset)
    }
}

/// Canonical text form of IP addresses (the same as `inet_ntop`, which nettop uses too).
nonisolated enum IPText {
    static func format(_ bytes: [UInt8]) -> String? {
        switch bytes.count {
        case 4:
            return bytes.map(String.init).joined(separator: ".")
        case 16:
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let ok = bytes.withUnsafeBytes { raw in
                inet_ntop(AF_INET6, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil
            }
            guard ok else { return nil }
            let text = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            // IPv4-mapped (::ffff:a.b.c.d) is the IPv4 address for our purposes.
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return format(Array(bytes[12..<16]))
            }
            return text
        default:
            return nil
        }
    }
}

/// Extracts UDP payloads from captured frames (Ethernet, BSD loopback/utun, raw IP).
nonisolated enum PacketDecoder {
    struct Datagram: Equatable {
        var sourcePort: UInt16
        var destinationPort: UInt16
        var payload: [UInt8]
        /// IP addresses as raw bytes (4 or 16).
        var source: [UInt8] = []
        var destination: [UInt8] = []
    }

    /// `linkType` is the pcap DLT value: 0 NULL, 1 EN10MB, 12/101 RAW, 108 LOOP.
    static func udpDatagram(linkType: Int32, frame: UnsafeRawBufferPointer) -> Datagram? {
        var offset: Int
        switch linkType {
        case 1: // Ethernet
            guard frame.count >= 14 else { return nil }
            var etherType = UInt16(frame[12]) << 8 | UInt16(frame[13])
            offset = 14
            while etherType == 0x8100 || etherType == 0x88A8 { // VLAN tags
                guard frame.count >= offset + 4 else { return nil }
                etherType = UInt16(frame[offset + 2]) << 8 | UInt16(frame[offset + 3])
                offset += 4
            }
            guard etherType == 0x0800 || etherType == 0x86DD else { return nil }
        case 0, 108: // 4-byte address family header, host or network order
            offset = 4
        case 12, 14, 101:
            offset = 0
        default:
            return nil
        }
        guard frame.count > offset else { return nil }
        let version = frame[offset] >> 4
        if version == 4 { return ipv4(frame, at: offset) }
        if version == 6 { return ipv6(frame, at: offset) }
        return nil
    }

    private static func ipv4(_ frame: UnsafeRawBufferPointer, at start: Int) -> Datagram? {
        guard frame.count >= start + 20 else { return nil }
        let headerLength = Int(frame[start] & 0x0F) * 4
        let fragment = (UInt16(frame[start + 6]) << 8 | UInt16(frame[start + 7])) & 0x1FFF
        guard frame[start + 9] == 17, fragment == 0, headerLength >= 20 else { return nil }
        return udp(frame, at: start + headerLength, source: Array(frame[(start + 12)..<(start + 16)]),
                   destination: Array(frame[(start + 16)..<(start + 20)]))
    }

    private static func ipv6(_ frame: UnsafeRawBufferPointer, at start: Int) -> Datagram? {
        guard frame.count >= start + 40 else { return nil }
        var next = frame[start + 6]
        var offset = start + 40
        // Skip hop-by-hop, routing and destination options headers.
        var hops = 0
        while [0, 43, 60].contains(next), hops < 8 {
            guard frame.count >= offset + 2 else { return nil }
            next = frame[offset]
            offset += (Int(frame[offset + 1]) + 1) * 8
            hops += 1
        }
        guard next == 17 else { return nil }
        return udp(frame, at: offset, source: Array(frame[(start + 8)..<(start + 24)]),
                   destination: Array(frame[(start + 24)..<(start + 40)]))
    }

    private static func udp(_ frame: UnsafeRawBufferPointer, at start: Int, source: [UInt8], destination: [UInt8]) -> Datagram? {
        guard frame.count >= start + 8 else { return nil }
        let sourcePort = UInt16(frame[start]) << 8 | UInt16(frame[start + 1])
        let destinationPort = UInt16(frame[start + 2]) << 8 | UInt16(frame[start + 3])
        let length = Int(UInt16(frame[start + 4]) << 8 | UInt16(frame[start + 5]))
        let end = min(frame.count, start + max(length, 8))
        guard end > start + 8 else { return nil }
        return Datagram(sourcePort: sourcePort, destinationPort: destinationPort, payload: Array(frame[(start + 8)..<end]),
                        source: source, destination: destination)
    }
}

/// Believes a DNS response only when it answers a query this Mac sent: the query left from one of
/// the Mac's addresses, and the response comes back from the same server to the same port, with the
/// same transaction ID and question, within a few seconds. Unsolicited responses are dropped.
nonisolated struct DNSQueryTracker {
    private struct Key: Hashable {
        var client: [UInt8]
        var clientPort: UInt16
        var server: [UInt8]
        var id: UInt16
        var name: String
    }

    static let lifetime: TimeInterval = 10
    static let capacity = 4096

    private var pending: [Key: TimeInterval] = [:]

    /// Records a query sent from `localAddresses`; for a matching response, returns its answers.
    mutating func handle(_ datagram: PacketDecoder.Datagram, localAddresses: Set<[UInt8]>, now: TimeInterval) -> [DNSMessage.Answer] {
        guard let question = DNSMessage.question(in: datagram.payload) else { return [] }
        if !question.isResponse {
            guard datagram.destinationPort == 53, localAddresses.contains(datagram.source) else { return [] }
            if pending.count >= Self.capacity { pending = pending.filter { now - $0.value < Self.lifetime } }
            guard pending.count < Self.capacity else { return [] }
            let key = Key(client: datagram.source, clientPort: datagram.sourcePort, server: datagram.destination,
                          id: question.id, name: question.name)
            pending[key] = now
            return []
        }
        guard datagram.sourcePort == 53 else { return [] }
        let key = Key(client: datagram.destination, clientPort: datagram.destinationPort, server: datagram.source,
                      id: question.id, name: question.name)
        guard let sent = pending.removeValue(forKey: key), now - sent < Self.lifetime else { return [] }
        return DNSMessage.answers(in: datagram.payload)
    }
}
