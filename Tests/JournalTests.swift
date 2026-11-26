import XCTest

final class JournalTests: XCTestCase {
    func testLearningPeriodTeachesWithoutEvents() {
        var state = JournalState(now: 1000, learning: true)
        XCTAssertNil(JournalRules.observe(.app(id: "app:a", name: "A"), in: &state, now: 1100, isBrowser: false))
        XCTAssertEqual(state.apps["app:a"], 1100)
        // Known now: no event even after learning.
        XCTAssertNil(JournalRules.observe(.app(id: "app:a", name: "A"), in: &state, now: 5000, isBrowser: false))
        let event = JournalRules.observe(.app(id: "app:b", name: "B"), in: &state, now: 5000, isBrowser: false)
        XCTAssertEqual(event?.kind, .newApp)
        XCTAssertEqual(event?.appName, "B")
    }

    func testBrowsersOnlyReportCountries() {
        var state = JournalState(now: 0, learning: false)
        XCTAssertNil(JournalRules.observe(.domain(appID: "app:s", appName: "Safari", domain: "lemonde.fr"),
                                          in: &state, now: 10, isBrowser: true))
        XCTAssertNotNil(state.domains["app:s|lemonde.fr"], "the domain is still remembered")
        let country = JournalRules.observe(.country(appID: "app:s", appName: "Safari", code: "JP", name: "Japon"),
                                           in: &state, now: 10, isBrowser: true)
        XCTAssertEqual(country?.kind, .newCountry)
        let domain = JournalRules.observe(.domain(appID: "app:n", appName: "Notes", domain: "facebook.com"),
                                          in: &state, now: 10, isBrowser: false)
        XCTAssertEqual(domain?.subject, "facebook.com")
    }

    func testSeedKeepsOldestDateAndHistoryStart() {
        var state = JournalState(now: 10_000, learning: false)
        state.apps["app:a"] = 9000
        JournalRules.seed(&state, apps: ["app:a": 5000, "app:b": 7000], domains: ["app:a|x.com": 6000], countries: [:])
        XCTAssertEqual(state.apps["app:a"], 5000)
        XCTAssertEqual(state.apps["app:b"], 7000)
        XCTAssertEqual(state.historyStart, 5000)
        XCTAssertNil(JournalRules.observe(.domain(appID: "app:a", appName: "A", domain: "x.com"), in: &state, now: 10_001,
                                          isBrowser: false))
    }

    func testPruneDropsOldEventsAndCaps() {
        var state = JournalState(now: 0, learning: false)
        let now = 40 * 86_400
        state.events = [JournalEvent(date: 1, kind: .newApp)]
        JournalRules.append(JournalEvent(date: now, kind: .newApp), to: &state, now: now)
        XCTAssertEqual(state.events.count, 1)
        for index in 0..<(JournalRules.maxEvents + 5) {
            state.events.append(JournalEvent(date: now + index, kind: .newApp))
        }
        JournalRules.prune(&state, now: now)
        XCTAssertEqual(state.events.count, JournalRules.maxEvents)
        XCTAssertEqual(state.events.last?.date, now + JournalRules.maxEvents + 4)
    }

    func testGroupMergesSameAppKindAndHour() {
        let events = [
            JournalEvent(date: 7200 + 10, kind: .newDomain, appID: "app:s", appName: "Spotify", subject: "scdn.co"),
            JournalEvent(date: 7200 + 600, kind: .newDomain, appID: "app:s", appName: "Spotify", subject: "spotify.com"),
            JournalEvent(date: 7200 + 900, kind: .newApp, appID: "app:s", appName: "Spotify"),
            JournalEvent(date: 3600 + 5, kind: .newDomain, appID: "app:s", appName: "Spotify", subject: "old.com"),
        ]
        let locale = Format.locale
        defer { Format.locale = locale }
        Format.locale = Locale(identifier: "en_US")
        let groups = JournalRules.group(events)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].kind, .newApp)
        XCTAssertEqual(groups[1].events.count, 2)
        XCTAssertEqual(groups[1].title, "Spotify contacts 2 new domains")
        XCTAssertEqual(groups[1].subtitle, "spotify.com, scdn.co")
        XCTAssertEqual(groups[2].title, "Spotify contacts old.com for the first time")
    }

    func testUnusualTitles() {
        let locale = Format.locale
        defer { Format.locale = locale }
        Format.locale = Locale(identifier: "en_US")
        let up = JournalGroup(events: [JournalEvent(date: 0, kind: .unusual, appID: "app:p", appName: "Photos",
                                                    subject: "up", detail: "15", bytes: 1_200_000_000)])
        XCTAssertEqual(up.title, "Photos sends 1.20 GB in an hour")
        XCTAssertEqual(up.subtitle, "About 15× more than a usual hour")
        let away = JournalGroup(events: [JournalEvent(date: 0, kind: .whileAway, appName: "Photos", bytes: 340_000_000,
                                                      duration: 7800)])
        XCTAssertEqual(away.title, "While you were away (2h 10m): 340 MB exchanged")
    }
}

final class AnomalyTests: XCTestCase {
    private let now = 1000 * 3600 + 1800

    private func hours(baseline: UInt64, count: Int, current: Traffic) -> [Int32: Traffic] {
        var hours: [Int32: Traffic] = [:]
        for index in 0..<count { hours[Int32(1000 - 2 - index * 3)] = Traffic(bytesIn: baseline, bytesOut: baseline) }
        hours[1000] = current
        return hours
    }

    func testFlagsBigUpload() {
        let finding = AnomalyRules.check(hours: hours(baseline: 2_000_000, count: 10,
                                                      current: Traffic(bytesIn: 0, bytesOut: 80_000_000)), now: now)
        XCTAssertEqual(finding?.direction, .up)
        XCTAssertEqual(finding?.factor, 40)
    }

    func testIgnoresSmallOrUsualVolumes() {
        // Above 10× but under the 50 Mo floor.
        XCTAssertNil(AnomalyRules.check(hours: hours(baseline: 1_000_000, count: 10,
                                                     current: Traffic(bytesIn: 0, bytesOut: 40_000_000)), now: now))
        // Big, but this app always sends that much.
        XCTAssertNil(AnomalyRules.check(hours: hours(baseline: 60_000_000, count: 10,
                                                     current: Traffic(bytesIn: 0, bytesOut: 90_000_000)), now: now))
    }

    func testNeedsABaseline() {
        XCTAssertNil(AnomalyRules.check(hours: hours(baseline: 1000, count: 2,
                                                     current: Traffic(bytesIn: 0, bytesOut: 900_000_000)), now: now))
    }

    func testUploadWinsOverDownload() {
        let finding = AnomalyRules.check(hours: hours(baseline: 1_000_000, count: 10,
                                                      current: Traffic(bytesIn: 900_000_000, bytesOut: 60_000_000)), now: now)
        XCTAssertEqual(finding?.direction, .up)
    }

    func testMedianAndCooldown() {
        XCTAssertEqual(AnomalyRules.median([5, 1, 3]), 3)
        XCTAssertEqual(AnomalyRules.median([4, 1, 3, 2]), 2)
        XCTAssertTrue(AnomalyRules.allowed("a|up", in: [:], now: 0))
        XCTAssertFalse(AnomalyRules.allowed("a|up", in: ["a|up": 0], now: 3600))
        XCTAssertTrue(AnomalyRules.allowed("a|up", in: ["a|up": 0], now: 6 * 3600))
    }
}
