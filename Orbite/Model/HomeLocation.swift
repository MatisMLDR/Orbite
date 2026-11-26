import CoreLocation
import Foundation
import Observation

/// Where the Mac sits on the map: Location Services when allowed, else the time zone's city.
@Observable
final class HomeLocation: NSObject, CLLocationManagerDelegate {
    enum Source: String {
        case location, saved, timeZone

        var label: String {
            switch self {
            case .location: String(localized: "Location Services")
            case .saved: String(localized: "Last known location")
            case .timeZone: String(localized: "Time zone")
            }
        }
    }

    private(set) var coordinate: CLLocationCoordinate2D
    private(set) var source: Source
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    @ObservationIgnored private let manager = CLLocationManager()
    private static let latitudeKey = "homeLatitude"
    private static let longitudeKey = "homeLongitude"

    override init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.latitudeKey) != nil {
            coordinate = CLLocationCoordinate2D(latitude: defaults.double(forKey: Self.latitudeKey),
                                                longitude: defaults.double(forKey: Self.longitudeKey))
            source = .saved
        } else {
            coordinate = Self.timeZoneCoordinate() ?? CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
            source = .timeZone
        }
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedAlways || authorization == .authorized
    }

    func start() {
        if isAuthorized { manager.requestLocation() }
    }

    func requestAccess() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            if isAuthorized { self.manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        MainActor.assumeIsolated {
            self.coordinate = coordinate
            source = .location
            UserDefaults.standard.set(coordinate.latitude, forKey: Self.latitudeKey)
            UserDefaults.standard.set(coordinate.longitude, forKey: Self.longitudeKey)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    /// zone.tab lists a reference city per time zone: « FR  +4852+00220  Europe/Paris ».
    static func timeZoneCoordinate(identifier: String = TimeZone.current.identifier) -> CLLocationCoordinate2D? {
        guard let text = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, fields[2] == identifier else { continue }
            return parseISO6709(String(fields[1]))
        }
        return nil
    }

    /// « +4852+00220 » or « +404251-0740023 ».
    static func parseISO6709(_ text: String) -> CLLocationCoordinate2D? {
        guard let split = text.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        let latText = String(text[..<split]), lonText = String(text[split...])
        func degrees(_ value: String, degreeDigits: Int) -> Double? {
            let sign: Double = value.hasPrefix("-") ? -1 : 1
            let digits = Array(value.dropFirst())
            guard digits.count >= degreeDigits + 2 else { return nil }
            let d = Double(String(digits[0..<degreeDigits])) ?? 0
            let m = Double(String(digits[degreeDigits..<(degreeDigits + 2)])) ?? 0
            let s = digits.count >= degreeDigits + 4 ? Double(String(digits[(degreeDigits + 2)..<(degreeDigits + 4)])) ?? 0 : 0
            return sign * (d + m / 60 + s / 3600)
        }
        guard let lat = degrees(latText, degreeDigits: 2), let lon = degrees(lonText, degreeDigits: 3) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

#if DEBUG
extension HomeLocation {
    /// Screenshot mode: a fixed home, never the Mac's.
    func showDemo() {
        coordinate = Demo.home
        source = .location
    }
}
#endif
