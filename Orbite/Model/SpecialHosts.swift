import Foundation

/// Protocols that cross the network unencrypted.
nonisolated enum PlaintextProtocol: String, Codable, Sendable, CaseIterable, Comparable {
    case http, ftp, telnet, pop3, imap, dns

    var label: String {
        switch self {
        case .http: "HTTP"
        case .ftp: "FTP"
        case .telnet: "Telnet"
        case .pop3: "POP3"
        case .imap: "IMAP"
        case .dns: "DNS"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Hosts and ports Orbite explains rather than just names: plaintext protocols, certificate checks,
/// iCloud Private Relay, encrypted DNS resolvers.
nonisolated enum SpecialHosts {
    static let privateRelayLabel = String(localized: "iCloud Private Relay")
    static let encryptedDNSPrefix = String(localized: "Encrypted DNS")

    /// The plaintext protocol a remote port speaks, for a public address. QUIC is always encrypted.
    static func plaintext(transport: TransportKind, port: Int) -> PlaintextProtocol? {
        switch (transport, port) {
        case (.tcp, 80), (.tcp, 8080): .http
        case (.tcp, 21): .ftp
        case (.tcp, 23): .telnet
        case (.tcp, 110): .pop3
        case (.tcp, 143): .imap
        case (.tcp, 53), (.udp, 53): .dns
        default: nil
        }
    }

    /// Certificate revocation checks and captive-portal probes travel in HTTP by design: their content is
    /// signed or meaningless, so they are shown as harmless.
    static func isBenignPlaintext(hostnames: some Collection<String>) -> Bool {
        guard !hostnames.isEmpty else { return false }
        return hostnames.allSatisfy { name in
            let name = name.lowercased()
            return name.hasPrefix("ocsp") || name.hasPrefix("crl") || name.contains(".ocsp.") || name.contains(".crl.")
                || name == "captive.apple.com" || name.hasSuffix(".pki.goog") || name == "ocsp.digicert.com"
                || name == "connectivitycheck.gstatic.com" || name == "detectportal.firefox.com"
        }
    }

    enum Service: Equatable, Sendable {
        case privateRelay
        case encryptedDNS(String)
    }

    private static let resolvers: Set<String> = [
        "dns.google", "dns.google.com", "cloudflare-dns.com", "mozilla.cloudflare-dns.com", "chrome.cloudflare-dns.com",
        "one.one.one.one", "dns.quad9.net", "dns11.quad9.net", "doh.opendns.com", "dns.adguard-dns.com",
        "doh.cleanbrowsing.org", "dns.mullvad.net", "doh.mullvad.net",
    ]

    /// What a hostname stands for, when it hides the real destination or the real names.
    static func service(of hostname: String) -> Service? {
        let name = hostname.lowercased()
        if name == "mask.icloud.com" || name == "mask-h2.icloud.com" || name == "mask-api.icloud.com"
            || name == "mask-canary.icloud.com" || name.hasSuffix(".mask.apple-dns.net") {
            return .privateRelay
        }
        if resolvers.contains(name) || name.hasSuffix(".dns.nextdns.io") || name == "dns.nextdns.io"
            || name.hasPrefix("doh.") || name.hasPrefix("dns.") && name.hasSuffix(".cloudflare-dns.com") {
            return .encryptedDNS(name)
        }
        return nil
    }

    /// Sidebar label for such a host; it keeps it apart from the provider's other traffic.
    static func label(for service: Service) -> String {
        switch service {
        case .privateRelay: privateRelayLabel
        case .encryptedDNS(let name): "\(encryptedDNSPrefix) · \(name)"
        }
    }

    /// Interfaces a VPN tunnels through.
    static func isTunnel(_ interface: String) -> Bool {
        interface.hasPrefix("utun") || interface.hasPrefix("ipsec") || interface.hasPrefix("ppp")
    }
}
