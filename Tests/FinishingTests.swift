import XCTest

final class SearchIndexTests: XCTestCase {
    private func item(_ title: String, kind: SearchItem.Kind = .app, weight: Double = 0, keywords: [String] = []) -> SearchItem {
        SearchItem(id: title, kind: kind, title: title, keywords: keywords, weight: weight, payload: "app|\(title)")
    }

    func testPrefixBeatsWordBeatsSubstring() {
        let items = [item("Spotify"), item("Apple Music"), item("Musique Store"), item("Ancien musée")]
        XCTAssertEqual(SearchIndex.rank("mus", in: items).map(\.title), ["Musique Store", "Apple Music", "Ancien musée"])
    }

    func testAccentsAndCaseAreIgnored() {
        let items = [item("Préférences Système"), item("Paris", kind: .place, keywords: ["France"])]
        XCTAssertEqual(SearchIndex.rank("PREFE", in: items).first?.title, "Préférences Système")
        XCTAssertEqual(SearchIndex.rank("france", in: items).first?.title, "Paris")
    }

    func testWeightBreaksTies() {
        let items = [item("tiktok.com", kind: .domain, weight: 10), item("tiktokcdn.com", kind: .domain, weight: 500)]
        XCTAssertEqual(SearchIndex.rank("tiktok", in: items).map(\.title), ["tiktok.com", "tiktokcdn.com"], "exact beats prefix")
        XCTAssertEqual(SearchIndex.rank("tik", in: items).first?.title, "tiktokcdn.com")
    }

    func testEmptyQueryKeepsOrder() {
        let items = [item("B"), item("A")]
        XCTAssertEqual(SearchIndex.rank("  ", in: items).map(\.title), ["B", "A"])
    }
}

final class ExporterTests: XCTestCase {
    func testCSVEscaping() {
        let table = ExportTable(columns: ["app", "bytes_in"], rows: [["Safari", "12"], ["Mon \"app\", v2", "3"], ["a\nb", "0"]])
        XCTAssertEqual(Exporter.csv(table), "app,bytes_in\r\nSafari,12\r\n\"Mon \"\"app\"\", v2\",3\r\n\"a\nb\",0\r\n")
    }

    func testJSONNumbersAndEmptyFields() throws {
        let table = ExportTable(columns: ["app", "bytes_in", "tracker_owner"], rows: [["Safari", "12", ""]])
        let objects = try JSONSerialization.jsonObject(with: Exporter.json(table)) as? [[String: Any]]
        XCTAssertEqual(objects?.first?["app"] as? String, "Safari")
        XCTAssertEqual(objects?.first?["bytes_in"] as? Int, 12)
        XCTAssertNil(objects?.first?["tracker_owner"])
    }
}

final class ReplayTimelineTests: XCTestCase {
    func testSlotsAndTrail() {
        let now = 1_000_000 * 300 + 120
        let end = (now / 300 + 1) * 300
        let start = end - 288 * 300
        // One minute in the first slot, two in the last.
        let first = Int32(start / 60)
        let last = Int32((end - 60) / 60)
        let timeline = ReplayTimeline.build(
            now: now, global: [first: Traffic(bytesIn: 10, bytesOut: 0)],
            sites: ["a": [first: Traffic(bytesIn: 1, bytesOut: 0), last: Traffic(bytesIn: 5, bytesOut: 1)],
                    "old": [first - 100: Traffic(bytesIn: 9, bytesOut: 9)]])
        XCTAssertEqual(timeline.start, start)
        XCTAssertEqual(timeline.global[0].bytesIn, 10)
        XCTAssertNil(timeline.sites["old"], "outside the 24 hours")
        XCTAssertEqual(timeline.places(at: 0).first?.now.bytesIn, 1)
        XCTAssertEqual(timeline.places(at: 287).first?.trail.total, 6)
        XCTAssertTrue(timeline.places(at: 100).isEmpty)
    }
}

final class RecapTests: XCTestCase {
    func testWeekFigures() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // Monday 2026-11-16 00:00 UTC.
        let start = 1_763_251_200
        let hour = Int32(start / 3600)
        let input = RecapInput(
            start: start, end: start + 7 * 86_400,
            global: [hour + 2: Traffic(bytesIn: 100, bytesOut: 0), hour + 30: Traffic(bytesIn: 900, bytesOut: 100)],
            previousWeek: Traffic(bytesIn: 500, bytesOut: 0),
            apps: [.init(id: "a", name: "Night", hours: [hour + 2: Traffic(bytesIn: 6_000_000, bytesOut: 0)]),
                   .init(id: "b", name: "Day", hours: [hour + 30: Traffic(bytesIn: 9_000_000, bytesOut: 0)])],
            places: [.init(title: "Tokyo", countryCode: "JP", country: "Japon", distanceKm: 9700, bytes: 10),
                     .init(title: "Paris", countryCode: "FR", country: "France", distanceKm: 3, bytes: 10),
                     .init(title: "Nowhere", countryCode: "XX", country: nil, distanceKm: 20_000, bytes: 0)],
            domainCount: 12, trackerShare: 0.1, topTrackerOwner: "Google")
        let recap = Recap.make(input, calendar: utc)
        XCTAssertEqual(recap.total.total, 1100)
        XCTAssertEqual(recap.change ?? 0, 1.2, accuracy: 0.0001)
        XCTAssertEqual(recap.topApps.map(\.name), ["Day", "Night"])
        XCTAssertEqual(recap.nightOwl?.name, "Night")
        XCTAssertEqual(recap.countryCount, 2)
        XCTAssertEqual(recap.farthest?.title, "Tokyo")
        XCTAssertEqual(recap.busiestHour, 6)
        XCTAssertEqual(recap.busiestDay?.start, start + 86_400)
    }
}
