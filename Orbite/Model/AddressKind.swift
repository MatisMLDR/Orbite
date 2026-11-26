import Darwin
import Foundation

/// Where an address lives: on the Internet (it gets a place on the map) or around the Mac.
nonisolated enum AddressScope: Sendable, Equatable {
    case internet
    case localNetwork
    case loopback
    case multicast
    case unspecified

    var isOnMap: Bool { self == .internet }
}

nonisolated enum IPAddress {
    /// Raw bytes (4 or 16), without any `%scope` suffix. IPv4-mapped IPv6 becomes IPv4.
    static func bytes(_ text: String) -> [UInt8]? {
        let clean = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var v4 = in_addr()
        if inet_pton(AF_INET, clean, &v4) == 1 {
            return withUnsafeBytes(of: v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, clean, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return Array(bytes[12..<16])
            }
            return bytes
        }
        return nil
    }

    /// Canonical text (what `inet_ntop` prints), so nettop and DNS answers compare equal.
    static func normalize(_ text: String) -> String? {
        bytes(text).flatMap(IPText.format)
    }

    static func scope(_ text: String) -> AddressScope {
        guard let b = bytes(text) else { return .unspecified }
        if b.count == 4 {
            switch (b[0], b[1]) {
            case (0, _): return .unspecified
            case (127, _): return .loopback
            case (10, _), (192, 168), (169, 254): return .localNetwork
            case (172, 16...31): return .localNetwork
            case (100, 64...127): return .localNetwork // carrier-grade NAT
            case (224...239, _): return .multicast
            case (255, 255): return .multicast
            default: return .internet
            }
        }
        if b.allSatisfy({ $0 == 0 }) { return .unspecified }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .loopback }
        if b[0] == 0xFF { return .multicast }
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return .localNetwork } // link-local
        if b[0] & 0xFE == 0xFC { return .localNetwork } // unique local
        return .internet
    }
}
