import Foundation

nonisolated enum TransportKind: String, Codable, Sendable, Hashable {
    case tcp, udp, quic, other

    var label: String {
        switch self {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .quic: "QUIC"
        case .other: String(localized: "Other")
        }
    }
}

nonisolated struct SocketEndpoint: Equatable, Sendable {
    /// Address without `%scope`, or "*" when unbound.
    var address: String
    var port: Int?

    var isWildcard: Bool { address == "*" || address.isEmpty }
}

nonisolated struct NetTopFlow: Equatable, Sendable {
    var transport: TransportKind
    var isIPv6: Bool
    var local: SocketEndpoint
    var remote: SocketEndpoint
    var interface: String
    var state: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    var retransmitted: UInt64
    /// Average round-trip time in milliseconds (TCP only).
    var rtt: Double?
}

nonisolated struct NetTopProcess: Equatable, Sendable {
    /// Kernel name, truncated by nettop (« com.apple.Safar »).
    var name: String
    var pid: Int32
    /// Cumulative bytes of every socket nettop saw for this process, including closed ones.
    var bytesIn: UInt64
    var bytesOut: UInt64
    var flows: [NetTopFlow] = []
}

nonisolated struct NetTopSample: Sendable {
    var date: Date
    var processes: [NetTopProcess]
}

/// Parses `nettop -L 0 -n -x -J interface,state,bytes_in,bytes_out,re-tx,rtt_avg`.
/// Each sample starts with a header line, then one line per process followed by its flows.
nonisolated struct NetTopParser {
    private var columns: [String: Int] = [:]
    private var processes: [NetTopProcess] = []
    private var started = false

    /// Feeds one line. Returns the previous sample when a header starts a new one.
    mutating func consume(_ rawLine: Substring, now: Date = Date()) -> NetTopSample? {
        let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
        guard !line.isEmpty else { return nil }
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)

        if Self.isHeader(fields) {
            var finished: NetTopSample?
            if started { finished = NetTopSample(date: now, processes: processes) }
            columns = [:]
            for (index, name) in fields.enumerated() where !name.isEmpty {
                columns[String(name)] = index
            }
            processes = []
            started = true
            return finished
        }
        guard started, let first = fields.first else { return nil }

        if let flow = parseFlow(first, fields) {
            if !processes.isEmpty { processes[processes.count - 1].flows.append(flow) }
        } else if let process = parseProcess(first, fields) {
            processes.append(process)
        }
        return nil
    }

    /// Ends the current sample (the stream paused after a burst).
    mutating func flush(now: Date = Date()) -> NetTopSample? {
        guard started, !processes.isEmpty else { return nil }
        let sample = NetTopSample(date: now, processes: processes)
        processes = []
        started = false
        return sample
    }

    private static func isHeader(_ fields: [Substring]) -> Bool {
        fields.contains("bytes_in") && (fields.first == "" || fields.first == "time")
    }

    private func field(_ name: String, _ fields: [Substring]) -> Substring? {
        guard let index = columns[name], index < fields.count else { return nil }
        let value = fields[index]
        return value.isEmpty ? nil : value
    }

    private func number(_ name: String, _ fields: [Substring]) -> UInt64 {
        field(name, fields).flatMap { UInt64($0) } ?? 0
    }

    private func parseProcess(_ first: Substring, _ fields: [Substring]) -> NetTopProcess? {
        let text = String(first)
        var name = text
        var pid: Int32 = 0
        if let dot = text.lastIndex(of: "."), let value = Int32(text[text.index(after: dot)...]) {
            name = String(text[..<dot])
            pid = value
        }
        return NetTopProcess(name: name, pid: pid,
                             bytesIn: number("bytes_in", fields), bytesOut: number("bytes_out", fields))
    }

    private func parseFlow(_ first: Substring, _ fields: [Substring]) -> NetTopFlow? {
        guard let space = first.firstIndex(of: " ") else { return nil }
        let proto = first[..<space]
        let rest = first[first.index(after: space)...]
        guard let arrow = rest.range(of: "<->") else { return nil }
        let isIPv6 = proto.hasSuffix("6")
        let transport: TransportKind
        if proto.hasPrefix("tcp") { transport = .tcp }
        else if proto.hasPrefix("udp") { transport = .udp }
        else if proto.hasPrefix("quic") { transport = .quic }
        else { transport = .other }

        let rtt = field("rtt_avg", fields).flatMap { value -> Double? in
            Double(value.split(separator: " ").first ?? "")
        }
        return NetTopFlow(
            transport: transport,
            isIPv6: isIPv6,
            local: Self.endpoint(rest[..<arrow.lowerBound], ipv6: isIPv6),
            remote: Self.endpoint(rest[arrow.upperBound...], ipv6: isIPv6),
            interface: field("interface", fields).map(String.init) ?? "",
            state: field("state", fields).map(String.init) ?? "",
            bytesIn: number("bytes_in", fields),
            bytesOut: number("bytes_out", fields),
            retransmitted: number("re-tx", fields),
            rtt: rtt)
    }

    /// IPv4 separates the port with ":", IPv6 with "." (`fe80::1%en0.5353`, `*.*`).
    static func endpoint(_ text: Substring, ipv6: Bool) -> SocketEndpoint {
        let separator: Character = ipv6 ? "." : ":"
        guard let index = text.lastIndex(of: separator) else {
            return SocketEndpoint(address: String(text), port: nil)
        }
        var address = String(text[..<index])
        if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
        let port = Int(text[text.index(after: index)...])
        return SocketEndpoint(address: address, port: port)
    }
}
