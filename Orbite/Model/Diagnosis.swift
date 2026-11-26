import Foundation

/// What a diagnosis looks at, gathered by the runner.
nonisolated struct DiagnosisInput: Sendable {
    struct WiFi: Sendable {
        var rssi: Int
        var noise: Int
        var band: String?
        var transmitRate: Double
    }

    struct Talker: Sendable {
        var id: String
        var name: String
        /// Bytes per second right now.
        var rate: Double
        var uploading: Bool
    }

    struct Destination: Sendable {
        var id: String
        var title: String
        var rtt: Double
        var baseline: Double?
        var loss: Double?
    }

    struct Lossy: Sendable {
        var id: String
        var name: String
        var ratio: Double
    }

    var online = true
    var wifi: WiFi?
    var router: PingStats?
    var routerAddress: String?
    var internet: PingStats?
    var routerBaseline: Double?
    var internetBaseline: Double?
    /// All apps together, bytes per second.
    var currentRate: Double = 0
    /// Highest 10-second average seen on this network lately.
    var peakRate: Double = 0
    var topTalker: Talker?
    var destinations: [Destination] = []
    var lossyApps: [Lossy] = []
}

nonisolated struct DiagnosisFinding: Identifiable, Sendable, Equatable {
    enum Severity: Int, Sendable, Comparable {
        case good, info, warning, problem
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Target: Sendable, Equatable {
        case app(String)
        case site(String)
    }

    var id: String
    var severity: Severity
    var symbol: String
    var title: String
    var detail: String
    var target: Target?
}

nonisolated struct DiagnosisResult: Sendable, Equatable {
    var findings: [DiagnosisFinding]
    var date: Date

    var worst: DiagnosisFinding.Severity { findings.map(\.severity).max() ?? .good }
    /// The headline: the most serious finding.
    var verdict: DiagnosisFinding? { findings.first }
}

/// Turns measurements into plain-French findings, most serious first. No I/O, so it can be tested.
nonisolated enum Diagnosis {
    static let weakSignal = -75
    static let poorSNR = 20
    static let saturation = 0.8
    static let minimumPeak = 500_000.0

    static func run(_ input: DiagnosisInput, at date: Date = Date()) -> DiagnosisResult {
        var findings: [DiagnosisFinding] = []
        guard input.online else {
            return DiagnosisResult(findings: [DiagnosisFinding(
                id: "offline", severity: .problem, symbol: "wifi.slash", title: String(localized: "No internet connection"),
                detail: String(localized: "The Mac has no usable network. Check the Wi-Fi or the cable."))], date: date)
        }

        // The link is full: one app takes most of what this network usually carries.
        if input.peakRate >= minimumPeak, input.currentRate >= input.peakRate * saturation, let top = input.topTalker,
           top.rate >= input.currentRate * 0.5 {
            let share = Format.percent(min(1, top.rate / max(input.peakRate, 1)))
            findings.append(DiagnosisFinding(
                id: "saturated", severity: .problem, symbol: "gauge.with.dots.needle.100percent",
                title: String(localized: "Your link is saturated by \(top.name)"),
                detail: top.uploading
                    ? String(localized: "\(top.name) uploads at \(Format.rate(top.rate)), about \(share) of the highest rate seen on this network. Everything else waits its turn.")
                    : String(localized: "\(top.name) downloads at \(Format.rate(top.rate)), about \(share) of the highest rate seen on this network. Everything else waits its turn."),
                target: .app(top.id)))
        }

        if let wifi = input.wifi {
            if wifi.rssi < weakSignal {
                findings.append(DiagnosisFinding(
                    id: "signal", severity: .warning, symbol: "wifi.exclamationmark",
                    title: String(localized: "Weak Wi-Fi signal (\(wifi.rssi) dBm)"),
                    detail: String(localized: "Move closer to the router or clear what is in the way: below \(weakSignal) dBm, the rate drops and losses climb.")))
            } else if wifi.rssi - wifi.noise < poorSNR {
                findings.append(DiagnosisFinding(
                    id: "noise", severity: .warning, symbol: "waveform.path.ecg",
                    title: String(localized: "Lots of Wi-Fi interference"),
                    detail: String(localized: "The signal (\(wifi.rssi) dBm) barely rises above the noise (\(wifi.noise) dBm). Another channel or the 5 GHz band would help.")))
            }
            if wifi.band?.hasPrefix("2") == true, wifi.transmitRate < 100 {
                findings.append(DiagnosisFinding(
                    id: "band", severity: .info, symbol: "dot.radiowaves.left.and.right",
                    title: String(localized: "You are on \(wifi.band ?? "2.4 GHz")"),
                    detail: String(localized: "This band reaches far but goes slower (\(Int(wifi.transmitRate)) Mbit/s here). If your router offers 5 GHz, join it.")))
            }
        }

        var localProblem = false
        if let router = input.router, !router.silent, let median = router.median {
            let slow = median > max(30, (input.routerBaseline ?? 0) * 3)
            if router.loss >= 0.2 || slow {
                localProblem = true
                findings.append(DiagnosisFinding(
                    id: "router", severity: .problem, symbol: "wifi.router",
                    title: String(localized: "The link to your router is poor"),
                    detail: String(localized: "It answers in \(Format.milliseconds(median)) with \(Format.percent(router.loss)) loss. The trouble is at home: Wi-Fi, cable or router.")))
            }
        }

        var internetProblem = false
        if let internet = input.internet {
            if internet.silent || internet.loss >= 0.2 {
                internetProblem = true
                findings.append(DiagnosisFinding(
                    id: "internet-loss", severity: .problem, symbol: "antenna.radiowaves.left.and.right.slash",
                    title: internet.silent ? String(localized: "The internet does not answer") : String(localized: "Your internet connection loses packets"),
                    detail: localProblem ? String(localized: "It most likely comes from the link to your router.")
                        : String(localized: "The router answers well, but \(Format.percent(internet.loss)) of the pings to the internet get lost: the trouble is on your router's or your provider's side.")))
            } else if let median = internet.median {
                let usual = input.internetBaseline
                let slow = usual.map { median > max($0 * 2.5, $0 + 50) } ?? (median > 150)
                if slow {
                    internetProblem = true
                    let since = usual.map { String(localized: ", usually \(Format.milliseconds($0))") } ?? ""
                    findings.append(DiagnosisFinding(
                        id: "internet-slow", severity: .warning, symbol: "tortoise",
                        title: String(localized: "The internet is slow"),
                        detail: String(localized: "1.1.1.1 answers in \(Format.milliseconds(median))\(since). ")
                            + (localProblem ? String(localized: "The link to your router is enough to explain it.") : String(localized: "Your router answers well: it comes from your provider or the network further away."))))
                }
            }
        }

        // Only one place is slow while the rest is fine: the trouble is on their side.
        if !localProblem, !internetProblem {
            let slow = input.destinations.filter { destination in
                let slowRTT = destination.baseline.map { destination.rtt > max($0 * 3, $0 + 80) } ?? false
                return slowRTT || (destination.loss ?? 0) >= 0.05
            }
            .sorted { $0.rtt > $1.rtt }
            if let worst = slow.first {
                var detail = String(localized: "It answers in \(Format.milliseconds(worst.rtt))")
                if let baseline = worst.baseline { detail += String(localized: " instead of the usual \(Format.milliseconds(baseline))") }
                if let loss = worst.loss, loss >= 0.05 { detail += String(localized: ", with \(Format.percent(loss)) retransmissions") }
                detail += String(localized: ". The rest of the network is fine: the trouble is on their side.")
                findings.append(DiagnosisFinding(
                    id: "destination", severity: .warning, symbol: "mappin.slash",
                    title: slow.count == 1 ? String(localized: "Only \(worst.title) is slow") : String(localized: "\(worst.title) and \(slow.count - 1) other places are slow"),
                    detail: detail, target: .site(worst.id)))
            }
        }

        for app in input.lossyApps.sorted(by: { $0.ratio > $1.ratio }).prefix(2) where app.ratio >= 0.05 {
            findings.append(DiagnosisFinding(
                id: "loss-\(app.id)", severity: .info, symbol: "arrow.triangle.2.circlepath",
                title: String(localized: "\(app.name) resends \(Format.percent(app.ratio)) of what it sends"),
                detail: String(localized: "Packets get lost on the way and leave a second time: it is slow for this app."),
                target: .app(app.id)))
        }

        if findings.allSatisfy({ $0.severity <= .info }) {
            var parts: [String] = []
            if let median = input.router?.median, input.router?.silent == false { parts.append(String(localized: "router in \(Format.milliseconds(median))")) }
            if let median = input.internet?.median { parts.append(String(localized: "internet in \(Format.milliseconds(median))")) }
            if let wifi = input.wifi { parts.append(String(localized: "signal \(wifi.rssi) dBm")) }
            findings.insert(DiagnosisFinding(
                id: "fine", severity: .good, symbol: "checkmark.seal.fill", title: String(localized: "Nothing unusual"),
                detail: parts.isEmpty ? String(localized: "Your network answers well.") : String(localized: "Your network answers well: \(parts.joined(separator: ", ")).")),
                at: 0)
        }

        findings.sort { $0.severity > $1.severity }
        // With only tips left, « all fine » is the headline and the tips follow.
        if let fine = findings.firstIndex(where: { $0.id == "fine" }) { findings.insert(findings.remove(at: fine), at: 0) }
        return DiagnosisResult(findings: findings, date: date)
    }
}

/// Retransmitted and sent bytes of the last seconds, kept only for seconds that sent something.
nonisolated struct LossWindow: Sendable {
    private(set) var entries: [(second: Int, retransmitted: UInt64, sent: UInt64)] = []
    static let span = 30

    mutating func add(retransmitted: UInt64, sent: UInt64, at second: Int) {
        guard sent > 0 || retransmitted > 0 else { return }
        if let last = entries.last, last.second == second {
            entries[entries.count - 1].retransmitted += retransmitted
            entries[entries.count - 1].sent += sent
        } else {
            entries.append((second, retransmitted, sent))
        }
        if let first = entries.first, first.second < second - Self.span { entries.removeAll { $0.second < second - Self.span } }
    }

    /// Share of sent bytes that were retransmissions over the last 30 s, once enough was sent to tell.
    func ratio(now: Int, minimumSent: UInt64 = 50_000) -> Double? {
        var retransmitted: UInt64 = 0, sent: UInt64 = 0
        for entry in entries where entry.second >= now - Self.span {
            retransmitted += entry.retransmitted
            sent += entry.sent
        }
        guard sent >= minimumSent else { return nil }
        return min(1, Double(retransmitted) / Double(sent))
    }

    /// Usual latency: falls fast toward a better value, rises slowly, so a bad spell does not become the norm.
    static func baseline(_ current: Double?, sample: Double) -> Double {
        guard let current else { return sample }
        return sample < current ? current * 0.95 + sample * 0.05 : current * 0.999 + sample * 0.001
    }
}
