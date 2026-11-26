import CoreLocation
import XCTest

final class NetTopParserTests: XCTestCase {
    private let sample = """
    ,interface,state,bytes_in,bytes_out,re-tx,rtt_avg,\r
    apsd.447,,,134190,646135,12876,,\r
    tcp4 192.168.1.24:50147<->17.188.185.134:5223,en0,Established,134190,646135,12876,58.47 ms,\r
    com.apple.WebKi.85310,,,14317,2000,0,,\r
    tcp6 2001:db8:4f2a:10::1.59069<->2620:149:a41:280::2:8.443,en0,Established,1000,200,0,101.97 ms,\r
    quic4 192.168.1.24:64429<->17.248.236.20:443,en0,,9399,1200,,117.50 ms,\r
    udp6 fe80::1c2b:3d4e:5f60:7a8b%utun4.1027<->*.*,utun4,,10,20,,,\r
    python3.14.15490,,,0,0,0,,\r
    ,interface,state,bytes_in,bytes_out,re-tx,rtt_avg,\r
    """

    func testParsesProcessesAndFlows() throws {
        var parser = NetTopParser()
        var samples: [NetTopSample] = []
        for line in sample.split(whereSeparator: \.isNewline) {
            if let finished = parser.consume(line) { samples.append(finished) }
        }
        XCTAssertEqual(samples.count, 1)
        let processes = try XCTUnwrap(samples.first?.processes)
        XCTAssertEqual(processes.map(\.name), ["apsd", "com.apple.WebKi", "python3.14"])
        XCTAssertEqual(processes.map(\.pid), [447, 85310, 15490])
        XCTAssertEqual(processes[0].bytesOut, 646_135)

        let apns = try XCTUnwrap(processes[0].flows.first)
        XCTAssertEqual(apns.transport, .tcp)
        XCTAssertEqual(apns.remote, SocketEndpoint(address: "17.188.185.134", port: 5223))
        XCTAssertEqual(apns.state, "Established")
        XCTAssertEqual(apns.retransmitted, 12_876)
        XCTAssertEqual(try XCTUnwrap(apns.rtt), 58.47, accuracy: 0.001)

        let v6 = processes[1].flows[0]
        XCTAssertTrue(v6.isIPv6)
        XCTAssertEqual(v6.remote, SocketEndpoint(address: "2620:149:a41:280::2:8", port: 443))
        XCTAssertEqual(processes[1].flows[1].transport, .quic)

        let scoped = processes[1].flows[2]
        XCTAssertEqual(scoped.local.address, "fe80::1c2b:3d4e:5f60:7a8b")
        XCTAssertTrue(scoped.remote.isWildcard)
    }

    func testFlushEndsSampleWithoutNextHeader() {
        var parser = NetTopParser()
        for line in sample.split(whereSeparator: \.isNewline).prefix(3) { _ = parser.consume(line) }
        XCTAssertEqual(parser.flush()?.processes.first?.flows.count, 1)
        XCTAssertNil(parser.flush())
    }
}

final class DNSMessageTests: XCTestCase {
    /// youtube.com → CNAME youtube-ui.l.google.com → A 142.250.179.110, AAAA 2a00:1450:4007:80c::200e.
    private func response() -> [UInt8] {
        var bytes: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00]
        func name(_ labels: [String]) -> [UInt8] {
            labels.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
        }
        bytes += name(["www", "YouTube", "com"]) + [0x00, 0x01, 0x00, 0x01]
        // Answer 1: pointer to question name, CNAME
        let target = [UInt8(10)] + Array("youtube-ui".utf8) + [1] + Array("l".utf8) + [6] + Array("google".utf8) + [0xC0, 0x18]
        bytes += [0xC0, 0x0C, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, UInt8(target.count)] + target
        // Answer 2: A record on the CNAME target (pointer to its offset)
        let cnameOffset = UInt8(12 + 17 + 4 + 12)
        bytes += [0xC0, cnameOffset, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 142, 250, 179, 110]
        // Answer 3: AAAA
        bytes += [0xC0, cnameOffset, 0x00, 0x1C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x10,
                  0x2A, 0x00, 0x14, 0x50, 0x40, 0x07, 0x08, 0x0C, 0, 0, 0, 0, 0, 0, 0x20, 0x0E]
        return bytes
    }

    func testMapsEveryAddressToTheQuestion() {
        let answers = DNSMessage.answers(in: response())
        XCTAssertEqual(answers, [
            DNSMessage.Answer(address: "142.250.179.110", hostname: "www.youtube.com"),
            DNSMessage.Answer(address: "2a00:1450:4007:80c::200e", hostname: "www.youtube.com"),
        ])
    }

    func testIgnoresQueriesAndErrors() {
        var query = response()
        query[2] = 0x01 // QR = 0
        XCTAssertTrue(DNSMessage.answers(in: query).isEmpty)
        var failure = response()
        failure[3] = 0x83 // NXDOMAIN
        XCTAssertTrue(DNSMessage.answers(in: failure).isEmpty)
        XCTAssertTrue(DNSMessage.answers(in: Array(response().prefix(20))).isEmpty)
    }

    func testRejectsPointerLoops() {
        let loop: [UInt8] = [0, 0, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0, 0xC0, 0x0C]
        XCTAssertNil(DNSMessage.readName(loop, at: 12))
    }

    func testDecodesUDPInEthernetFrame() {
        let payload = response()
        var frame: [UInt8] = Array(repeating: 0, count: 12) + [0x08, 0x00]
        let udpLength = 8 + payload.count
        frame += [0x45, 0, 0, UInt8(20 + udpLength), 0, 0, 0x40, 0, 64, 17, 0, 0, 8, 8, 8, 8, 192, 168, 1, 2]
        frame += [0, 53, 0xC3, 0x50, UInt8(udpLength >> 8), UInt8(udpLength & 0xFF), 0, 0] + payload
        let datagram = frame.withUnsafeBytes { PacketDecoder.udpDatagram(linkType: 1, frame: $0) }
        XCTAssertEqual(datagram?.sourcePort, 53)
        XCTAssertEqual(datagram?.payload, payload)
        XCTAssertEqual(datagram?.source, [8, 8, 8, 8])
        XCTAssertEqual(datagram?.destination, [192, 168, 1, 2])
    }

    // MARK: - Only responses to this Mac's queries

    private let mac: [UInt8] = [192, 168, 1, 2]
    private let server: [UInt8] = [8, 8, 8, 8]

    private func query(from client: [UInt8]? = nil, port: UInt16 = 50_000) -> PacketDecoder.Datagram {
        var payload = response()
        payload[2] = 0x01 // QR = 0
        return PacketDecoder.Datagram(sourcePort: port, destinationPort: 53, payload: payload,
                                      source: client ?? mac, destination: server)
    }

    private func reply(id: UInt16 = 0x1234, from source: [UInt8]? = nil, port: UInt16 = 50_000) -> PacketDecoder.Datagram {
        var payload = response()
        payload[0] = UInt8(id >> 8)
        payload[1] = UInt8(id & 0xFF)
        return PacketDecoder.Datagram(sourcePort: 53, destinationPort: port, payload: payload,
                                      source: source ?? server, destination: mac)
    }

    func testDropsUnsolicitedResponses() {
        var tracker = DNSQueryTracker()
        XCTAssertTrue(tracker.handle(reply(), localAddresses: [mac], now: 0).isEmpty)
    }

    func testAcceptsTheResponseToAQueryOnce() {
        var tracker = DNSQueryTracker()
        XCTAssertTrue(tracker.handle(query(), localAddresses: [mac], now: 0).isEmpty)
        XCTAssertEqual(tracker.handle(reply(), localAddresses: [mac], now: 0.05).count, 2)
        XCTAssertTrue(tracker.handle(reply(), localAddresses: [mac], now: 0.06).isEmpty)
    }

    func testDropsResponsesThatDoNotMatchTheQuery() {
        var tracker = DNSQueryTracker()
        _ = tracker.handle(query(), localAddresses: [mac], now: 0)
        XCTAssertTrue(tracker.handle(reply(id: 0x9999), localAddresses: [mac], now: 0.1).isEmpty)
        XCTAssertTrue(tracker.handle(reply(port: 50_001), localAddresses: [mac], now: 0.1).isEmpty)
        XCTAssertTrue(tracker.handle(reply(from: [1, 1, 1, 1]), localAddresses: [mac], now: 0.1).isEmpty)
        XCTAssertTrue(tracker.handle(reply(), localAddresses: [mac], now: DNSQueryTracker.lifetime + 1).isEmpty)
    }

    func testIgnoresQueriesNotSentByThisMac() {
        var tracker = DNSQueryTracker()
        _ = tracker.handle(query(from: [192, 168, 1, 66]), localAddresses: [mac], now: 0)
        var forged = reply()
        forged.destination = [192, 168, 1, 66]
        XCTAssertTrue(tracker.handle(forged, localAddresses: [mac], now: 0.1).isEmpty)
    }
}

final class AddressTests: XCTestCase {
    func testScopes() {
        XCTAssertEqual(IPAddress.scope("17.253.144.10"), .internet)
        XCTAssertEqual(IPAddress.scope("192.168.1.10"), .localNetwork)
        XCTAssertEqual(IPAddress.scope("172.20.0.1"), .localNetwork)
        XCTAssertEqual(IPAddress.scope("127.0.0.1"), .loopback)
        XCTAssertEqual(IPAddress.scope("224.0.0.251"), .multicast)
        XCTAssertEqual(IPAddress.scope("fe80::1%en0"), .localNetwork)
        XCTAssertEqual(IPAddress.scope("ff02::fb"), .multicast)
        XCTAssertEqual(IPAddress.scope("::1"), .loopback)
        XCTAssertEqual(IPAddress.scope("2620:149:a41:280::2:8"), .internet)
    }

    func testNormalizesMappedAndLongForms() {
        XCTAssertEqual(IPAddress.normalize("::ffff:17.1.2.3"), "17.1.2.3")
        XCTAssertEqual(IPAddress.normalize("2620:0149:0a41:0280:0000:0000:0002:0008"), "2620:149:a41:280::2:8")
    }

    func testLabels() {
        XCTAssertEqual(HostLabel.registrableDomain("rr3---sn-25glene6.googlevideo.com"), "googlevideo.com")
        XCTAssertEqual(HostLabel.registrableDomain("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(HostLabel.registrableDomain("d1.cloudfront.net"), "d1.cloudfront.net")
        XCTAssertEqual(HostLabel.cleanOrganization("GOOGLE LLC"), "Google")
        XCTAssertEqual(HostLabel.cleanOrganization("Akamai International B.V."), "Akamai")
        XCTAssertEqual(HostLabel.cleanOrganization("Scaleway S.A.S."), "Scaleway")
        XCTAssertEqual(HostLabel.cleanOrganization("DIGITAL OCEAN NETWORK SERVICES"), "Digital Ocean Network Services")
    }
}

final class TrafficTests: XCTestCase {
    /// The previous 5-minute window lies before the ring: an empty range, not a crash.
    func testRingSumOutsideTheRingIsZero() {
        var ring = SecondRing(capacity: 300, now: 1_000)
        ring.add(Traffic(bytesIn: 7, bytesOut: 3), at: 1_000)
        XCTAssertEqual(ring.sum(from: 400, to: 700), .zero)
        XCTAssertEqual(ring.sum(from: 1_200, to: 1_300), .zero)
        XCTAssertEqual(ring.bins(count: 30, width: 10, end: 700), Array(repeating: .zero, count: 30))
        XCTAssertEqual(ring.sum(from: 600, to: 1_001), Traffic(bytesIn: 7, bytesOut: 3))
    }

    func testRingKeepsAMovingSum() {
        var ring = SecondRing(capacity: 10, now: 100)
        ring.add(Traffic(bytesIn: 5, bytesOut: 1), at: 100)
        ring.add(Traffic(bytesIn: 5, bytesOut: 1), at: 105)
        XCTAssertEqual(ring.sum, Traffic(bytesIn: 10, bytesOut: 2))
        ring.advance(to: 110)
        XCTAssertEqual(ring.sum, Traffic(bytesIn: 5, bytesOut: 1))
        ring.advance(to: 130)
        XCTAssertEqual(ring.sum, .zero)
        ring.add(Traffic(bytesIn: 1, bytesOut: 0), at: 130)
        XCTAssertEqual(ring.bins(count: 2, width: 5, end: 131), [.zero, Traffic(bytesIn: 1, bytesOut: 0)])
    }

    func testBucketsSumWindows() {
        let now = 1_800_000_000
        var buckets = TrafficBuckets()
        buckets.add(Traffic(bytesIn: 100, bytesOut: 10), at: now - 30)
        buckets.add(Traffic(bytesIn: 100, bytesOut: 10), at: now - 2 * 3600)
        buckets.add(Traffic(bytesIn: 100, bytesOut: 10), at: now - 3 * 86_400)
        XCTAssertEqual(buckets.sum(from: now - 3600, to: now + 1, now: now).bytesIn, 100)
        XCTAssertEqual(buckets.sum(from: now - 86_400, to: now + 1, now: now).bytesIn, 200)
        XCTAssertEqual(buckets.sum(from: now - 7 * 86_400, to: now + 1, now: now).bytesIn, 300)
        buckets.prune(now: now + 6 * 86_400)
        XCTAssertEqual(buckets.sum(from: now - 7 * 86_400, to: now + 1, now: now + 6 * 86_400).bytesIn, 200)
    }

    func testSaturatingDifference() {
        XCTAssertEqual(Traffic(bytesIn: 5, bytesOut: 1) - Traffic(bytesIn: 7, bytesOut: 0), Traffic(bytesIn: 0, bytesOut: 1))
    }

    func testFormats() {
        let locale = Format.locale
        defer { Format.locale = locale }
        Format.locale = Locale(identifier: "fr_FR")
        XCTAssertEqual(Format.bytes(UInt64(0)), "0 o")
        XCTAssertEqual(Format.bytes(UInt64(512)), "512 o")
        XCTAssertEqual(Format.bytes(UInt64(1_760_000)), "1,76 Mo")
        XCTAssertEqual(Format.bytes(UInt64(49_700_000)), "49,7 Mo")
        XCTAssertEqual(Format.bytes(UInt64(412_000_000)), "412 Mo")
        XCTAssertEqual(Format.bytes(UInt64(999_600)), "1,00 Mo")
        XCTAssertEqual(Format.compactRate(4_200_000), "4,20 M")
        XCTAssertEqual(Format.percent(0.045), "4,5 %")
        XCTAssertEqual(Format.duration(7800), "2 h 10")
        Format.locale = Locale(identifier: "en_US")
        XCTAssertEqual(Format.bytes(UInt64(0)), "0 B")
        XCTAssertEqual(Format.bytes(UInt64(1_760_000)), "1.76 MB")
        XCTAssertEqual(Format.compactRate(4_200_000), "4.20 M")
        XCTAssertEqual(Format.percent(0.045), "4.5%")
        XCTAssertEqual(Format.duration(7800), "2h 10m")
        XCTAssertEqual(Format.plural(0, "place", "places"), "0 places")
        XCTAssertEqual(Format.plural(1, "place", "places"), "1 place")
        XCTAssertEqual(Format.port(443, transport: .quic), "quic (443)")
        XCTAssertEqual(Format.port(443, transport: .tcp), "https (443)")
        XCTAssertEqual(Format.flag("fr"), "🇫🇷")
    }
}

final class GeoTests: XCTestCase {
    func testGreatCircle() {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let newYork = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.006)
        XCTAssertEqual(GeoMath.distanceKm(paris, newYork), 5837, accuracy: 15)
        let middle = GeoMath.interpolate(paris, newYork, fraction: 0.5)
        // The great circle bends north of both cities.
        XCTAssertGreaterThan(middle.latitude, 50)
        XCTAssertEqual(GeoMath.interpolate(paris, newYork, fraction: 0).latitude, paris.latitude, accuracy: 1e-6)
        XCTAssertEqual(GeoMath.interpolate(paris, newYork, fraction: 1).longitude, newYork.longitude, accuracy: 1e-6)
    }

    func testCentroidOfTwoPlacesIsTheMiddleOfTheirGreatCircle() throws {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let newYork = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.006)
        let middle = GeoMath.interpolate(paris, newYork, fraction: 0.5)
        let centroid = try XCTUnwrap(GeoMath.centroid([paris, newYork]))
        XCTAssertEqual(centroid.latitude, middle.latitude, accuracy: 1e-6)
        XCTAssertEqual(centroid.longitude, middle.longitude, accuracy: 1e-6)
        XCTAssertNil(GeoMath.centroid([]))
    }

    func testGlobeProjectionShowsTheFacingHemisphere() throws {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let newYork = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.006)
        let sydney = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
        let camera = GlobeCamera(latitude: paris.latitude, longitude: paris.longitude, radius: 300)
        let projection = GlobeProjection(camera: camera, size: CGSize(width: 800, height: 600))
        let center = try XCTUnwrap(projection.project(paris))
        XCTAssertEqual(center.x, 400, accuracy: 1e-6)
        XCTAssertEqual(center.y, 300, accuracy: 1e-6)
        // New York lies west of Paris: left of the centre, on the disc.
        let west = try XCTUnwrap(projection.project(newYork))
        XCTAssertLessThan(west.x, 400)
        XCTAssertLessThan(hypot(west.x - 400, west.y - 300), 300)
        XCTAssertNil(projection.project(sydney))
        // Over the North Pole, on the meridian opposite Paris: straight above the centre.
        let beyond = projection.point(GlobeProjection.unit(CLLocationCoordinate2D(latitude: 80, longitude: paris.longitude + 180)))
        XCTAssertEqual(beyond.x, 400, accuracy: 1e-6)
        XCTAssertLessThan(beyond.y, 300)
    }

    func testShiftedGlobeProjectionMovesTheWholeDisc() throws {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let newYork = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.006)
        let camera = GlobeCamera(latitude: paris.latitude, longitude: paris.longitude, radius: 300)
        let size = CGSize(width: 800, height: 600)
        let centred = GlobeProjection(camera: camera, size: size)
        let shifted = GlobeProjection(camera: camera, size: size, shift: 120)
        XCTAssertEqual(shifted.center.x, 520, accuracy: 1e-6)
        XCTAssertEqual(shifted.center.y, 300, accuracy: 1e-6)
        let facing = try XCTUnwrap(shifted.project(paris))
        XCTAssertEqual(facing.x, 520, accuracy: 1e-6)
        XCTAssertEqual(facing.y, 300, accuracy: 1e-6)
        // Every place moves by the shift alone.
        let before = try XCTUnwrap(centred.project(newYork))
        let after = try XCTUnwrap(shifted.project(newYork))
        XCTAssertEqual(after.x - before.x, 120, accuracy: 1e-6)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6)
    }

    func testGlobeFollowsThePanelsOnlyWhileTheWholeEarthShows() {
        let size = CGSize(width: 1400, height: 900)
        // The whole Earth fits in the height: it follows all the way.
        XCTAssertEqual(GlobeCamera(latitude: 0, longitude: 0, radius: 360).panelFollow(in: size), 1)
        XCTAssertEqual(GlobeCamera(latitude: 0, longitude: 0, radius: 450).panelFollow(in: size), 1, accuracy: 1e-9)
        // It covers the whole view: the panels move nothing.
        XCTAssertEqual(GlobeCamera(latitude: 0, longitude: 0, radius: 833).panelFollow(in: size), 0, accuracy: 1e-9)
        XCTAssertEqual(GlobeCamera(latitude: 0, longitude: 0, radius: 1600).panelFollow(in: size), 0)
        // In between, less and less as it zooms in.
        let steps = stride(from: 450.0, through: 833, by: 20).map {
            GlobeCamera(latitude: 0, longitude: 0, radius: $0).panelFollow(in: size)
        }
        XCTAssertEqual(steps, steps.sorted(by: >))
        XCTAssertGreaterThan(steps[steps.count / 2], 0.2)
        XCTAssertLessThan(steps[steps.count / 2], 0.8)
    }

    func testGlideLandsWithoutOvershooting() {
        let glide = Glide(resting: 0, at: 10).aimed(at: 150, at: 10)
        XCTAssertEqual(glide.value(at: 10), 0)
        let values = stride(from: 10.0, through: glide.end + 0.1, by: 1.0 / 120).map { glide.value(at: $0) }
        XCTAssertEqual(values, values.sorted())
        XCTAssertLessThanOrEqual(values.max() ?? 0, 150)
        XCTAssertEqual(glide.value(at: glide.end - 1e-3), 150, accuracy: 0.05)
        XCTAssertLessThan(glide.end - 10, 1.8)
        XCTAssertEqual(glide.value(at: glide.end), 150)
        XCTAssertEqual(glide.speed(at: glide.end), 0)
        // It sets off gently, from rest, and takes over a second.
        XCTAssertEqual(glide.speed(at: 10), 0, accuracy: 1e-9)
        XCTAssertLessThan(glide.value(at: 10.05), 1)
        XCTAssertGreaterThan(glide.speed(at: 10.1), 0)
        XCTAssertLessThan(glide.value(at: 11), 150)
        XCTAssertGreaterThan(glide.end - 10, 1)
    }

    func testGlideAimedAgainKeepsItsPlaceAndSpeed() {
        let first = Glide(resting: 0, at: 0).aimed(at: 150, at: 0)
        let second = first.aimed(at: -80, at: 0.2)
        XCTAssertEqual(second.value(at: 0.2), first.value(at: 0.2), accuracy: 1e-9)
        XCTAssertEqual(second.speed(at: 0.2), first.speed(at: 0.2), accuracy: 1e-9)
        XCTAssertEqual(second.value(at: second.end), -80)
        // Its acceleration does not jump either.
        let h = 1e-4
        let before = (first.speed(at: 0.2) - first.speed(at: 0.2 - h)) / h
        let after = (second.speed(at: 0.2 + h) - second.speed(at: 0.2)) / h
        XCTAssertEqual(after, before, accuracy: abs(before) * 0.01 + 1)
    }

    func testGlobeArcIsCutAtTheRim() throws {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let sydney = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
        let camera = GlobeCamera(latitude: paris.latitude, longitude: paris.longitude, radius: 300)
        let projection = GlobeProjection(camera: camera, size: CGSize(width: 600, height: 600))
        let samples = (0...40).map { GlobeProjection.unit(GeoMath.interpolate(paris, sydney, fraction: Double($0) / 40)) }
        let runs = projection.visibleRuns(samples)
        XCTAssertEqual(runs.count, 1)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run[0].x, 300, accuracy: 1e-6)
        // The run ends on the rim, not at the last visible sample.
        let end = try XCTUnwrap(run.last)
        XCTAssertEqual(hypot(end.x - 300, end.y - 300), 300, accuracy: 1e-6)
    }

    func testFlightArcsLeaveTheGround() throws {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let newYork = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.006)
        let lyon = CLLocationCoordinate2D(latitude: 45.764, longitude: 4.8357)
        let far = GlobeProjection.flightArc(paris, newYork)
        let near = GlobeProjection.flightArc(paris, lyon)
        func length(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }
        // Both ends on the ground, the middle in the air, higher for the longer trip.
        XCTAssertEqual(length(try XCTUnwrap(far.first)), 1, accuracy: 1e-9)
        XCTAssertEqual(length(try XCTUnwrap(far.last)), 1, accuracy: 1e-9)
        let farTop = try XCTUnwrap(far.map(length).max()), nearTop = try XCTUnwrap(near.map(length).max())
        XCTAssertGreaterThan(nearTop, 1.01)
        XCTAssertGreaterThan(farTop, nearTop + 0.1)
    }

    func testLiftedArcShowsPastTheRimAndHidesBehindTheEarth() throws {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let sydney = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
        let camera = GlobeCamera(latitude: paris.latitude, longitude: paris.longitude, radius: 300)
        let projection = GlobeProjection(camera: camera, size: CGSize(width: 600, height: 600))
        // Behind the centre: hidden over the disc, visible beside it.
        let back = -GlobeProjection.unit(paris)
        XCTAssertEqual(projection.side(back * 1.2), .hidden)
        // Over the equator opposite Paris: 20 % up stays behind the disc, a full radius up rises past the rim.
        let opposite = GlobeProjection.unit(CLLocationCoordinate2D(latitude: 0, longitude: paris.longitude + 180))
        XCTAssertEqual(projection.side(opposite * 1.2), .hidden)
        XCTAssertEqual(projection.side(opposite * 2), .behind)
        XCTAssertEqual(projection.side(GlobeProjection.unit(paris) * 1.2), .front)

        let runs = projection.runs(GlobeProjection.flightArc(paris, sydney))
        let first = try XCTUnwrap(runs.first)
        XCTAssertTrue(first.front)
        XCTAssertEqual(first.points[0].x, 300, accuracy: 1e-6)
        // The arc rises past the rim before the Earth hides it: it reaches further out than the disc.
        let reach = runs.flatMap(\.points).map { hypot($0.x - 300, $0.y - 300) }.max() ?? 0
        XCTAssertGreaterThan(reach, 300)
        // Sydney itself, on the far side, is never drawn.
        let sydneyPoint = projection.point(GlobeProjection.unit(sydney))
        XCTAssertFalse(runs.flatMap(\.points).contains { hypot($0.x - sydneyPoint.x, $0.y - sydneyPoint.y) < 1 })
        // Comets follow the arc from the Mac, but only up to where the Earth hides it.
        let flight = projection.flightPath(GlobeProjection.flightArc(paris, sydney))
        XCTAssertEqual(flight.first?.x ?? 0, 300, accuracy: 1e-6)
        XCTAssertTrue(projection.flightPath(GlobeProjection.flightArc(sydney, paris)).isEmpty)
    }

    func testArcShadowFallsAwayFromTheSun() throws {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let berlin = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405)
        let camera = GlobeCamera(latitude: 50, longitude: 8, radius: 2000)
        let projection = GlobeProjection(camera: camera, size: CGSize(width: 800, height: 800))
        let flight = GlobeProjection.flightArc(paris, berlin)
        // Sun low in the south-west of the arc: shadows fall to the north-east, up and right on screen.
        let sun = GlobeProjection.unit(CLLocationCoordinate2D(latitude: 10, longitude: -30))
        let shadow = try XCTUnwrap(projection.shadowRuns(flight, sun: sun).first)
        XCTAssertEqual(shadow.count, flight.count)
        let start = try XCTUnwrap(projection.project(paris))
        XCTAssertEqual(shadow[0].x, start.x, accuracy: 1e-6)
        XCTAssertEqual(shadow[0].y, start.y, accuracy: 1e-6)
        let middle = flight.count / 2
        let ground = projection.point(flight[middle] / (flight[middle] * flight[middle]).sum().squareRoot())
        XCTAssertGreaterThan(shadow[middle].x, ground.x + 5)
        XCTAssertLessThan(shadow[middle].y, ground.y - 5)
        // At night there is no shadow.
        XCTAssertTrue(projection.shadowRuns(flight, sun: -GlobeProjection.unit(paris)).isEmpty)
    }

    func testSubsolarPointFollowsTheSeasonsAndTheDay() {
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        // June solstice, noon UTC: over the Tropic of Cancer, near Greenwich.
        let june = GeoMath.subsolarPoint(at: date("2026-06-21T12:00:00Z"))
        XCTAssertEqual(june.latitude, 23.44, accuracy: 0.1)
        XCTAssertEqual(june.longitude, 0, accuracy: 1)
        // December solstice, midnight UTC: over the Tropic of Capricorn, on the date line.
        let december = GeoMath.subsolarPoint(at: date("2026-12-21T00:00:00Z"))
        XCTAssertEqual(december.latitude, -23.44, accuracy: 0.1)
        XCTAssertEqual(abs(december.longitude), 180, accuracy: 1.5)
        // Six hours later the sun has moved 90° west.
        let morning = GeoMath.subsolarPoint(at: date("2026-06-21T18:00:00Z"))
        XCTAssertEqual(morning.longitude, june.longitude - 90, accuracy: 0.2)
    }

    func testGlobeDragFollowsThePointer() {
        var camera = GlobeCamera(latitude: 0, longitude: 0, radius: 100)
        // Dragging right brings the west into view; dragging down brings the north.
        camera.rotate(dx: 100 * .pi / 2, dy: 0)
        XCTAssertEqual(camera.longitude, -90, accuracy: 1e-9)
        camera.rotate(dx: 0, dy: 100 * .pi / 6)
        XCTAssertEqual(camera.latitude, 30, accuracy: 1e-9)
        camera.rotate(dx: 0, dy: 10_000)
        XCTAssertEqual(camera.latitude, 80)
        camera.rotate(dx: -100 * .pi * 1.5, dy: 0)
        XCTAssertEqual(abs(camera.longitude), 180, accuracy: 1e-9)
    }

    func testGlobeFramingFitsThePlaces() throws {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let berlin = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405)
        let sydney = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
        let near = try XCTUnwrap(GlobeCamera.framing([paris, berlin], fit: 300, maxRadius: 5000))
        XCTAssertGreaterThan(near.radius, 1000)
        let projection = GlobeProjection(camera: near, size: CGSize(width: 800, height: 800))
        for place in [paris, berlin] {
            let point = try XCTUnwrap(projection.project(place))
            XCTAssertLessThanOrEqual(hypot(point.x - 400, point.y - 400), 300)
        }
        // Across the world: the whole globe at its fitting size.
        XCTAssertEqual(try XCTUnwrap(GlobeCamera.framing([paris, sydney], fit: 300, maxRadius: 5000)).radius, 300, accuracy: 2)
        // « Recentrer » on the globe: the Mac in the middle, the places around it in view.
        let around = try XCTUnwrap(GlobeCamera.framing([paris, berlin], around: paris, fit: 300, maxRadius: 5000))
        XCTAssertEqual(around.latitude, paris.latitude, accuracy: 1e-9)
        XCTAssertEqual(around.longitude, paris.longitude, accuracy: 1e-9)
        let fromParis = GlobeProjection(camera: around, size: CGSize(width: 800, height: 800))
        let berlinPoint = try XCTUnwrap(fromParis.project(berlin))
        XCTAssertLessThanOrEqual(hypot(berlinPoint.x - 400, berlinPoint.y - 400), 300)
        // Short way round the date line, zoom on a log scale.
        let flight = GlobeCamera(latitude: 0, longitude: 170, radius: 100)
            .interpolated(to: GlobeCamera(latitude: 0, longitude: -170, radius: 400), 0.5)
        XCTAssertEqual(abs(flight.longitude), 180, accuracy: 1e-9)
        XCTAssertEqual(flight.radius, 200, accuracy: 1e-9)
    }

    func testDeclutterGivesPillsToHeaviestAndFoldsTheRest() {
        let items = [
            Declutter.Item(id: "paris", point: CGPoint(x: 100, y: 100), labelWidth: 60, weight: 10),
            Declutter.Item(id: "nanterre", point: CGPoint(x: 104, y: 102), labelWidth: 80, weight: 5),
            Declutter.Item(id: "lyon", point: CGPoint(x: 300, y: 300), labelWidth: 50, weight: 1),
            Declutter.Item(id: "near", point: CGPoint(x: 130, y: 100), labelWidth: 50, weight: 2),
        ]
        let placement = Declutter.place(items)
        XCTAssertEqual(placement["lyon"], .pill(extra: 0))
        XCTAssertEqual(placement["nanterre"], .hidden)
        XCTAssertEqual(placement["paris"], .pill(extra: 2))
        XCTAssertEqual(placement["near"], .hidden)
    }

    /// Runs against the real DB-IP files when ORBITE_GEOIP_DIR (or Application Support) has them.
    func testMMDBLookups() throws {
        let directory = ProcessInfo.processInfo.environment["ORBITE_GEOIP_DIR"]
            ?? (NSHomeDirectory() + "/Library/Application Support/Orbite/GeoIP")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        guard let city = files.first(where: { $0.contains("city") && $0.hasSuffix(".mmdb") }),
              let asn = files.first(where: { $0.contains("asn") && $0.hasSuffix(".mmdb") }) else {
            throw XCTSkip("No GeoIP database in \(directory)")
        }
        let database = GeoDatabase(cityPath: directory + "/" + city, asnPath: directory + "/" + asn)
        XCTAssertEqual(database.place(for: "8.8.8.8")?.countryCode, "US")
        XCTAssertEqual(database.owner(for: "8.8.8.8")?.number, 15169)
        XCTAssertEqual(database.owner(for: "1.1.1.1")?.number, 13335)
        XCTAssertEqual(database.owner(for: "17.253.144.10").flatMap { $0.organization.map(HostLabel.cleanOrganization) }, "Apple")
        XCTAssertNotNil(database.place(for: "2620:149:a41:280::2:8"))
        XCTAssertNil(database.place(for: "10.0.0.1"))
    }
}
