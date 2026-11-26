import XCTest

final class NetworkLedgerTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    func testDayIndexIsCivilAndStableAcrossDST() {
        XCTAssertEqual(NetworkLedger.civilDays(year: 1970, month: 1, day: 1), 0)
        XCTAssertEqual(NetworkLedger.civilDays(year: 2000, month: 3, day: 1), 11_017)
        // 2026-03-29 is the spring change in Paris: early morning and late evening are the same day.
        let morning = NetworkLedger.dayIndex(date("2026-03-29T00:30:00Z"), calendar: paris)
        let evening = NetworkLedger.dayIndex(date("2026-03-29T21:30:00Z"), calendar: paris)
        XCTAssertEqual(morning, evening)
        // 23:30 UTC on the 29th is already the 30th in Paris.
        XCTAssertEqual(NetworkLedger.dayIndex(date("2026-03-29T23:30:00Z"), calendar: paris), morning + 1)
    }

    func testCycleStart() {
        let utc: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }()
        func day(_ y: Int, _ m: Int, _ d: Int) -> Int32 { Int32(NetworkLedger.civilDays(year: y, month: m, day: d)) }
        XCTAssertEqual(NetworkLedger.cycleStart(resetDay: 1, now: date("2026-11-25T12:00:00Z"), calendar: utc), day(2026, 11, 1))
        XCTAssertEqual(NetworkLedger.cycleStart(resetDay: 28, now: date("2026-11-25T12:00:00Z"), calendar: utc), day(2026, 10, 28))
        XCTAssertEqual(NetworkLedger.cycleStart(resetDay: 15, now: date("2026-01-03T12:00:00Z"), calendar: utc), day(2025, 12, 15))
        // A reset on the 31st falls on the last day of February, then on the 31st again.
        XCTAssertEqual(NetworkLedger.cycleStart(resetDay: 31, now: date("2026-02-28T12:00:00Z"), calendar: utc), day(2026, 2, 28))
        XCTAssertEqual(NetworkLedger.cycleStart(resetDay: 31, now: date("2026-03-10T12:00:00Z"), calendar: utc), day(2026, 2, 28))
        XCTAssertEqual(NetworkLedger.cycleStart(resetDay: 31, now: date("2028-02-29T12:00:00Z"), calendar: utc), day(2028, 2, 29))
    }

    func testRecordAndMobileUsage() {
        var ledger = NetworkLedger()
        let home = NetworkIdentity.wifi(ssid: "Maison", expensive: false, security: "WPA2")
        let phone = NetworkIdentity.wifi(ssid: "iPhone", expensive: true, security: "WPA3")
        ledger.record(home, total: Traffic(bytesIn: 1000, bytesOut: 10), byApp: ["app:a": Traffic(bytesIn: 1000, bytesOut: 10)],
                      at: 100_000, day: 10)
        ledger.record(phone, total: Traffic(bytesIn: 500, bytesOut: 0), byApp: ["app:a": Traffic(bytesIn: 300, bytesOut: 0),
                                                                                "app:b": Traffic(bytesIn: 200, bytesOut: 0)],
                      at: 100_001, day: 10)
        ledger.record(phone, total: Traffic(bytesIn: 50, bytesOut: 0), byApp: ["app:b": Traffic(bytesIn: 50, bytesOut: 0)],
                      at: 200_000, day: 11)
        XCTAssertEqual(ledger.networks.count, 2)
        XCTAssertTrue(ledger.networks["wifi:iPhone"]!.isMobile)
        XCTAssertFalse(ledger.networks["wifi:Maison"]!.isMobile)
        let usage = ledger.mobileUsage(fromDay: 10, toDay: 11)
        XCTAssertEqual(usage.total.total, 550)
        XCTAssertEqual(usage.byApp["app:b"]?.total, 250)
        XCTAssertEqual(ledger.mobileUsage(fromDay: 11, toDay: 11).total.total, 50)
        ledger.setMobileOverride(true, for: "wifi:Maison")
        XCTAssertEqual(ledger.mobileUsage(fromDay: 10, toDay: 11).total.total, 1560)
        XCTAssertEqual(ledger.globalDays[10]?.total, 1510)
    }

    func testPeakAndPlaintextAndPrune() {
        var ledger = NetworkLedger()
        let home = NetworkIdentity.ethernet(name: "Ethernet", expensive: false)
        ledger.record(home, total: .zero, byApp: [:], at: 0, day: 0)
        ledger.notePeak(5000, for: "ethernet", at: 0)
        ledger.notePeak(3000, for: "ethernet", at: 10)
        XCTAssertEqual(ledger.networks["ethernet"]?.peakRate, 5000)
        ledger.notePeak(1000, for: "ethernet", at: NetworkLedger.peakHorizon + 1)
        XCTAssertEqual(ledger.networks["ethernet"]?.peakRate, 1000, "an old peak gives way")
        ledger.notePlaintext(["curl · example.com"], for: "ethernet")
        ledger.notePlaintext(["curl · example.com"], for: "ethernet")
        XCTAssertEqual(ledger.networks["ethernet"]?.plaintextHosts, ["curl · example.com"])
        ledger.globalDays = [1: Traffic(bytesIn: 1, bytesOut: 0), 200: Traffic(bytesIn: 1, bytesOut: 0)]
        ledger.prune(now: 200 * 86_400, today: 200)
        XCTAssertEqual(Array(ledger.globalDays.keys), [200])
    }
}

final class DiagnosisTests: XCTestCase {
    private func ping(_ median: Double?, received: Int = 10) -> PingStats {
        PingStats(sent: 10, received: received, median: median)
    }

    func testAllFine() {
        var input = DiagnosisInput()
        input.router = ping(3)
        input.internet = ping(14)
        input.internetBaseline = 12
        input.wifi = .init(rssi: -55, noise: -92, band: "2,4 GHz", transmitRate: 70)
        let result = Diagnosis.run(input)
        XCTAssertEqual(result.verdict?.id, "fine", "tips do not take the headline")
        XCTAssertTrue(result.findings.contains { $0.id == "band" })
        XCTAssertEqual(result.worst, .info)
    }

    func testSaturation() {
        var input = DiagnosisInput()
        input.peakRate = 10_000_000
        input.currentRate = 9_500_000
        input.topTalker = .init(id: "app:steam", name: "Steam", rate: 9_000_000, uploading: false)
        input.router = ping(4)
        input.internet = ping(90)
        input.internetBaseline = 15
        let result = Diagnosis.run(input)
        XCTAssertEqual(result.verdict?.id, "saturated")
        XCTAssertEqual(result.verdict?.target, .app("app:steam"))
    }

    func testLocalVersusProvider() {
        var local = DiagnosisInput()
        local.router = ping(120)
        local.internet = ping(160)
        local.wifi = .init(rssi: -82, noise: -90, band: "5 GHz", transmitRate: 300)
        let localResult = Diagnosis.run(local)
        XCTAssertEqual(localResult.verdict?.id, "router")
        XCTAssertTrue(localResult.findings.contains { $0.id == "signal" })

        var provider = DiagnosisInput()
        provider.router = ping(3)
        provider.internet = ping(180)
        provider.internetBaseline = 14
        let providerResult = Diagnosis.run(provider)
        XCTAssertEqual(providerResult.verdict?.id, "internet-slow")
        XCTAssertTrue(providerResult.verdict?.detail.contains("provider") == true)
    }

    func testSilentRouterIsNotAProblem() {
        var input = DiagnosisInput()
        input.router = ping(nil, received: 0)
        input.internet = ping(15)
        XCTAssertEqual(Diagnosis.run(input).verdict?.id, "fine")
    }

    func testOneSlowDestination() {
        var input = DiagnosisInput()
        input.router = ping(3)
        input.internet = ping(14)
        input.destinations = [.init(id: "s1", title: "Ashburn", rtt: 400, baseline: 90, loss: nil),
                              .init(id: "s2", title: "Paris", rtt: 12, baseline: 10, loss: nil)]
        let result = Diagnosis.run(input)
        XCTAssertEqual(result.verdict?.id, "destination")
        XCTAssertEqual(result.verdict?.title, "Only Ashburn is slow")
        XCTAssertEqual(result.verdict?.target, .site("s1"))
    }

    func testOffline() {
        var input = DiagnosisInput()
        input.online = false
        XCTAssertEqual(Diagnosis.run(input).findings.map(\.id), ["offline"])
    }
}

final class PingerTests: XCTestCase {
    func testEchoRequestChecksumAndReply() {
        let packet = Pinger.echoRequest(identifier: 0x1234, sequence: 7)
        XCTAssertEqual(packet[0], 8)
        XCTAssertEqual(Pinger.checksum(packet), 0, "a packet with its checksum sums to zero")
        var reply = packet
        reply[0] = 0
        // With a 20-byte IPv4 header in front, as macOS delivers it.
        let header: [UInt8] = [0x45] + Array(repeating: 0, count: 19)
        XCTAssertTrue(Pinger.isReply(ArraySlice(header + reply), sequence: 7))
        XCTAssertFalse(Pinger.isReply(ArraySlice(header + reply), sequence: 8))
        XCTAssertTrue(Pinger.isReply(ArraySlice(reply), sequence: 7))
    }

    func testLossWindow() {
        var window = LossWindow()
        window.add(retransmitted: 5_000, sent: 100_000, at: 100)
        window.add(retransmitted: 0, sent: 0, at: 101)
        XCTAssertEqual(window.ratio(now: 110) ?? 0, 0.05, accuracy: 0.0001)
        XCTAssertNil(window.ratio(now: 200), "older than 30 s")
        XCTAssertEqual(LossWindow.baseline(nil, sample: 20), 20)
        XCTAssertLessThan(LossWindow.baseline(20, sample: 200), 21, "a spike barely moves the usual latency")
    }
}
