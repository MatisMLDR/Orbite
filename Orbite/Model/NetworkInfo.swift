import CoreWLAN
import Darwin
import Foundation
import Network
import Observation
import SystemConfiguration

/// The Mac's own side of the network: active interface, addresses, router, DNS, Wi-Fi link.
@Observable
final class NetworkInfo {
    enum Medium: String {
        case wifi, ethernet, cellular, vpn, other, none

        var symbol: String {
            switch self {
            case .wifi: "wifi"
            case .ethernet: "cable.connector"
            case .cellular: "antenna.radiowaves.left.and.right"
            case .vpn: "lock.shield"
            case .other: "network"
            case .none: "wifi.slash"
            }
        }
    }

    struct WiFi: Equatable {
        var ssid: String?
        var rssi: Int
        var noise: Int
        var transmitRate: Double
        var channel: String?
        var security: String?

        /// 0…4 bars from RSSI.
        var bars: Int {
            switch rssi {
            case ..<(-85): 1
            case ..<(-72): 2
            case ..<(-60): 3
            default: 4
            }
        }
    }

    private(set) var interface: String?
    private(set) var serviceName: String?
    private(set) var medium: Medium = .none
    private(set) var ipv4: [String] = []
    private(set) var ipv6: [String] = []
    private(set) var router: String?
    private(set) var dnsServers: [String] = []
    private(set) var wifi: WiFi?
    private(set) var isExpensive = false
    private(set) var isConstrained = false
    private(set) var isOnline = true
    private(set) var vpnActive = false
    /// Physical interface byte rate (all protocols, all apps).
    private(set) var linkRate = Rate.zero
    /// The network traffic is counted against, read even with the window closed.
    private(set) var currentNetwork: NetworkIdentity?
    /// Wi-Fi signal over the last two hours: every 3 s on screen, every minute in the background.
    private(set) var wifiHistory: [WiFiSample] = []

    struct WiFiSample: Equatable {
        var date: Date
        var rssi: Int
        var noise: Int
        var transmitRate: Double
    }

    @ObservationIgnored private let store = SCDynamicStoreCreate(nil, "Orbite" as CFString, nil, nil)
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCounters: (date: Date, traffic: Traffic)?
    @ObservationIgnored private var displayNames: [String: String] = [:]
    @ObservationIgnored private var backgroundTimer: Timer?

    /// Watches the path (online, expensive). The periodic refresh waits for `setActive(true)`.
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = online
                self.isExpensive = expensive
                self.isConstrained = constrained
                // Inactive, the next setActive(true) reads everything anyway.
                if self.timer != nil { self.refresh() }
                self.readNetwork()
            }
        }
        monitor.start(queue: .main)
        readNetwork()
        // Joining another Wi-Fi does not always change the path: look again now and then.
        let background = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.readNetwork()
                if self.timer == nil { self.sampleWiFi() }
            }
        }
        background.tolerance = 10
        backgroundTimer = background
    }

    /// Which network traffic belongs to. The Wi-Fi counts even under a VPN, whose tunnel is not a network.
    func readNetwork() {
        guard isOnline else { return }
        let global = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) } as? [String: Any]
        let primary = global?["PrimaryInterface"] as? String
        let wifiInterface = CWWiFiClient.shared().interface()
        let tunnelled = primary.map(SpecialHosts.isTunnel) ?? false
        let identity: NetworkIdentity
        let joined = wifiInterface?.wlanChannel() != nil
        if let wifiInterface, primary == wifiInterface.interfaceName || (tunnelled && joined) {
            // The Wi-Fi card is never Ethernet: while it is still joining, wait for the next look.
            guard joined else { return }
            identity = .wifi(ssid: wifiInterface.ssid(), expensive: isExpensive,
                             security: Self.securityLabel(wifiInterface.security()))
        } else if primary?.hasPrefix("pdp_ip") == true {
            identity = .cellular(expensive: isExpensive)
        } else if let primary, primary.hasPrefix("en") {
            if displayNames[primary] == nil { displayNames[primary] = Self.displayName(bsdName: primary) ?? primary }
            identity = .ethernet(name: displayNames[primary], expensive: isExpensive)
        } else {
            return
        }
        set(\.currentNetwork, identity)
    }

    private func sampleWiFi() {
        guard let wifiInterface = CWWiFiClient.shared().interface(), wifiInterface.wlanChannel() != nil else { return }
        appendSample(WiFiSample(date: Date(), rssi: wifiInterface.rssiValue(), noise: wifiInterface.noiseMeasurement(),
                                transmitRate: wifiInterface.transmitRate()))
    }

    private func appendSample(_ sample: WiFiSample) {
        wifiHistory.append(sample)
        let oldest = Date().addingTimeInterval(-7200)
        if let first = wifiHistory.first, first.date < oldest { wifiHistory.removeAll { $0.date < oldest } }
    }

    /// Wi-Fi, addresses and link rate are only read while the window or the menu bar panel shows them.
    func setActive(_ active: Bool) {
        #if DEBUG
        if Demo.isActive { return }
        #endif
        if active {
            guard timer == nil else { return }
            refresh()
            let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.5
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            // The next rate must not average the whole pause.
            lastCounters = nil
        }
    }

    func refresh() {
        #if DEBUG
        if Demo.isActive { return }
        #endif
        let global = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) } as? [String: Any]
        let name = global?["PrimaryInterface"] as? String
        set(\.interface, name)
        set(\.router, global?["Router"] as? String)
        let dns = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/DNS" as CFString) } as? [String: Any]
        set(\.dnsServers, dns?["ServerAddresses"] as? [String] ?? [])

        let (v4, v6) = Self.addresses(of: name)
        set(\.ipv4, v4)
        set(\.ipv6, v6)
        set(\.vpnActive, name?.hasPrefix("utun") == true || name?.hasPrefix("ipsec") == true || name?.hasPrefix("ppp") == true)

        let client = CWWiFiClient.shared()
        let wifiInterface = client.interface()
        let isWiFi = name != nil && wifiInterface?.interfaceName == name
        if isWiFi, let wifiInterface {
            var channel: String?
            if let wlan = wifiInterface.wlanChannel() {
                let band: String
                switch wlan.channelBand {
                case .band2GHz: band = "\(Format.decimal(2.4, digits: 1)) GHz"
                case .band5GHz: band = "5 GHz"
                case .band6GHz: band = "6 GHz"
                default: band = ""
                }
                channel = band.isEmpty ? "\(wlan.channelNumber)" : "\(wlan.channelNumber) · \(band)"
            }
            let wifi = WiFi(ssid: wifiInterface.ssid(), rssi: wifiInterface.rssiValue(), noise: wifiInterface.noiseMeasurement(),
                            transmitRate: wifiInterface.transmitRate(), channel: channel,
                            security: Self.securityLabel(wifiInterface.security()))
            set(\.wifi, wifi)
            appendSample(WiFiSample(date: Date(), rssi: wifi.rssi, noise: wifi.noise, transmitRate: wifi.transmitRate))
        } else {
            set(\.wifi, nil)
        }

        let medium: Medium
        if name == nil { medium = .none }
        else if isWiFi { medium = .wifi }
        else if vpnActive { medium = .vpn }
        else if name?.hasPrefix("en") == true { medium = .ethernet }
        else if name?.hasPrefix("pdp_ip") == true { medium = .cellular }
        else { medium = .other }
        set(\.medium, medium)
        if let name, displayNames[name] == nil { displayNames[name] = Self.displayName(bsdName: name) ?? name }
        set(\.serviceName, name.flatMap { displayNames[$0] })

        let counters = Self.physicalCounters()
        let now = Date()
        if let last = lastCounters {
            let rate = Rate(counters - last.traffic, over: now.timeIntervalSince(last.date))
            set(\.linkRate, rate)
        }
        lastCounters = (now, counters)
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<NetworkInfo, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private static func displayName(bsdName: String) -> String? {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for item in all where SCNetworkInterfaceGetBSDName(item) as String? == bsdName {
            return SCNetworkInterfaceGetLocalizedDisplayName(item) as String?
        }
        return nil
    }

    /// The security label of a network with none.
    static let openLabel = String(localized: "Open")

    /// Open or WEP: anyone nearby can read what goes in clear.
    static func isWeak(_ security: String?) -> Bool {
        security == openLabel || security == "WEP"
    }

    private static func securityLabel(_ security: CWSecurity) -> String? {
        switch security {
        case .none: openLabel
        case .WEP: "WEP"
        case .wpaPersonal, .wpaPersonalMixed: "WPA"
        case .wpa2Personal: "WPA2"
        case .wpa3Personal, .wpa3Transition: "WPA3"
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise: String(localized: "WPA2 Enterprise")
        case .wpa3Enterprise: String(localized: "WPA3 Enterprise")
        default: nil
        }
    }

    private static func addresses(of interface: String?) -> ([String], [String]) {
        guard let interface else { return ([], []) }
        var v4: [String] = []
        var v6: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return ([], []) }
        defer { freeifaddrs(list) }
        for entry in Swift.sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: entry.pointee.ifa_name) == interface, let address = entry.pointee.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6,
                  getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if family == AF_INET {
                v4.append(text)
            } else if !text.hasPrefix("fe80") {
                v6.append(text.split(separator: "%").first.map(String.init) ?? text)
            }
        }
        return (v4, v6)
    }

    /// 64-bit byte counters of physical interfaces (en*, pdp_ip*), so a VPN is not counted twice.
    private static func physicalCounters() -> Traffic {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return .zero }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return .zero }
        var total = Traffic.zero
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                            total += Traffic(bytesIn: info.ifm_data.ifi_ibytes, bytesOut: info.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return total
    }
}

#if DEBUG
extension NetworkInfo {
    /// Screenshot mode: a made-up café Wi-Fi with documentation addresses, never the Mac's own network.
    func showDemo() {
        interface = "en0"
        serviceName = "Wi-Fi"
        medium = .wifi
        ipv4 = ["192.168.1.24"]
        ipv6 = ["2001:db8:4f2a:10::24"]
        router = "192.168.1.1"
        dnsServers = ["192.168.1.1"]
        wifi = WiFi(ssid: "Orbite Café", rssi: -52, noise: -93, transmitRate: 866, channel: "36 · 5 GHz", security: "WPA3")
        isOnline = true
        currentNetwork = NetworkIdentity.wifi(ssid: "Orbite Café", expensive: false, security: "WPA3")
        let now = Date()
        wifiHistory = (0..<80).reversed().map { step in
            let wave = 3 * sin(Double(step) / 6) + 1.5 * sin(Double(step) / 2.3)
            return WiFiSample(date: now.addingTimeInterval(Double(-step * 45)), rssi: -53 + Int(wave.rounded()), noise: -93,
                              transmitRate: 866)
        }
    }

    func setDemoLinkRate(_ rate: Rate) {
        linkRate = Rate(inPerSecond: rate.inPerSecond * 1.04, outPerSecond: rate.outPerSecond * 1.08)
    }
}
#endif
