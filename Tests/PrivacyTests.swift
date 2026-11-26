import XCTest

final class TrackerListTests: XCTestCase {
    private let web = """
    {"trackers": {
      "doubleclick.net": {"owner": {"name": "Google LLC", "displayName": "Google Ads (Google)"}, "default": "block",
                          "categories": ["Ad Motivated Tracking", "Advertising"], "prevalence": 0.44, "fingerprinting": 3},
      "googletagmanager.com": {"owner": {"displayName": "Google"}, "default": "ignore",
                               "categories": ["Analytics", "Tag Manager"]},
      "google.com": {"owner": {"displayName": "Google"}, "default": "ignore",
                     "categories": ["Advertising", "Content Delivery", "Online Payment"]},
      "facebook.net": {"owner": {"displayName": "Facebook"}, "default": "ignore",
                       "categories": ["Advertising", "Social Network", "Embedded Content"]},
      "addthis.com": {"owner": {"displayName": "Oracle"}, "default": "block", "categories": ["Social - Share"]},
      "fp.example": {"owner": {"displayName": "FP"}, "default": "block", "fingerprinting": 3}
    }, "entities": {}, "domains": {}}
    """
    private let apps = """
    {"trackers": {
      "www.facebook.com": {"owner": {"displayName": "Facebook"}, "default": "block"},
      "a.applovin.com": {"owner": {"displayName": "AppLovin"}, "default": "block"},
      "fonts.googleapis.com": {"owner": {"displayName": "Google"}, "default": "ignore"}
    }}
    """

    private func list() throws -> TrackerList {
        try TrackerList.parse(web: Data(web.utf8), apps: Data(apps.utf8))
    }

    func testWebCategoriesAndServices() throws {
        let list = try list()
        XCTAssertEqual(list.lookup("ad.doubleclick.net", inBrowser: true)?.category, .advertising)
        XCTAssertEqual(list.lookup("ad.doubleclick.net", inBrowser: true)?.owner, "Google Ads (Google)")
        XCTAssertEqual(list.lookup("www.googletagmanager.com", inBrowser: true)?.category, .analytics)
        XCTAssertNil(list.lookup("www.google.com", inBrowser: true), "a content service is not a tracker")
        XCTAssertNil(list.lookup("connect.facebook.net", inBrowser: true))
        XCTAssertEqual(list.lookup("s7.addthis.com", inBrowser: true)?.category, .social)
        XCTAssertEqual(list.lookup("fp.example", inBrowser: false)?.category, .fingerprinting)
    }

    func testAppListOnlyOutsideBrowsers() throws {
        let list = try list()
        XCTAssertNil(list.lookup("www.facebook.com", inBrowser: true))
        XCTAssertEqual(list.lookup("www.facebook.com", inBrowser: false)?.owner, "Facebook")
        XCTAssertNil(list.lookup("fonts.googleapis.com", inBrowser: false), "ignored entries are not trackers")
        XCTAssertEqual(list.lookup("o123.ingest.sentry.io", inBrowser: false)?.category, .telemetry)
        XCTAssertEqual(list.lookup("A.APPLOVIN.COM.", inBrowser: false)?.owner, "AppLovin")
    }

    func testSummary() {
        let ads = TrackerInfo(owner: "Google", category: .advertising)
        let crash = TrackerInfo(owner: "Sentry", category: .telemetry)
        let summary = TrackerSummary.make([(ads, 300), (nil, 600), (crash, 50), (ads, 50)])
        XCTAssertEqual(summary.trackerHosts, 3)
        XCTAssertEqual(summary.trackerBytes, 400)
        XCTAssertEqual(summary.share, 0.4, accuracy: 0.0001)
        XCTAssertEqual(summary.owners.map(\.name), ["Google", "Sentry"])
        XCTAssertEqual(summary.owners.first?.hosts, 2)
    }
}

final class SpecialHostsTests: XCTestCase {
    func testPlaintextPorts() {
        XCTAssertEqual(SpecialHosts.plaintext(transport: .tcp, port: 80), .http)
        XCTAssertEqual(SpecialHosts.plaintext(transport: .udp, port: 53), .dns)
        XCTAssertNil(SpecialHosts.plaintext(transport: .tcp, port: 443))
        XCTAssertNil(SpecialHosts.plaintext(transport: .quic, port: 80))
    }

    func testBenignPlaintext() {
        XCTAssertTrue(SpecialHosts.isBenignPlaintext(hostnames: ["ocsp.apple.com", "ocsp2.apple.com"]))
        XCTAssertTrue(SpecialHosts.isBenignPlaintext(hostnames: ["captive.apple.com"]))
        XCTAssertFalse(SpecialHosts.isBenignPlaintext(hostnames: ["ocsp.apple.com", "example.com"]))
        XCTAssertFalse(SpecialHosts.isBenignPlaintext(hostnames: [String]()))
    }

    func testServices() {
        XCTAssertEqual(SpecialHosts.service(of: "mask.icloud.com"), .privateRelay)
        XCTAssertEqual(SpecialHosts.service(of: "dns.google"), .encryptedDNS("dns.google"))
        XCTAssertEqual(SpecialHosts.service(of: "abc123.dns.nextdns.io"), .encryptedDNS("abc123.dns.nextdns.io"))
        XCTAssertNil(SpecialHosts.service(of: "www.icloud.com"))
        XCTAssertEqual(SpecialHosts.label(for: .privateRelay), "iCloud Private Relay")
        XCTAssertTrue(SpecialHosts.isTunnel("utun4"))
        XCTAssertFalse(SpecialHosts.isTunnel("en0"))
    }

    func testFactorFormat() {
        XCTAssertEqual(Format.factor(3.24), "3,2×")
        XCTAssertEqual(Format.factor(15.4), "15×")
    }
}
