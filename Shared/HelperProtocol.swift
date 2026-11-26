import CryptoKit
import Foundation

/// Names and code requirements shared by the app and its privileged helper.
nonisolated enum HelperConstants {
    static let machServiceName = "app.matis.Orbite.Helper"
    static let plistName = "app.matis.Orbite.Helper.plist"
    /// The team that signs Orbite, from `DEVELOPMENT_TEAM` through the Info.plist of the app and of the helper.
    /// Missing, no signature matches and the app and the helper refuse each other.
    static let teamID = Bundle.main.object(forInfoDictionaryKey: "OrbiteTeamID") as? String ?? ""
    static let appIdentifier = "app.matis.Orbite"
    static let helperIdentifier = "app.matis.Orbite.Helper"

    /// The only client the helper talks to: Orbite, signed by this team.
    static var appRequirement: String { requirement(for: appIdentifier) }
    /// The only daemon the app trusts.
    static var helperRequirement: String { requirement(for: helperIdentifier) }

    private static func requirement(for identifier: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// SHA-256 of a file, used as the helper's version: a rebuilt helper always differs.
    static func digest(ofFileAt path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One DNS answer seen on the wire: `address` was returned when something asked for `hostname`.
nonisolated struct DNSMapping: Codable, Sendable, Hashable {
    var address: String
    var hostname: String
    var seenAt: Date
}

/// XPC interface of the helper. Read-only: the app can only fetch what the helper observed.
@objc(OrbiteHelperProtocol)
nonisolated protocol OrbiteHelperProtocol {
    /// SHA-256 of the executable the daemon is running from.
    func helperVersion(reply: @escaping @Sendable (String) -> Void)
    /// Mappings recorded after `sequence`, as a property list of `[DNSMapping]`, with the new sequence.
    func dnsMappings(after sequence: UInt64, reply: @escaping @Sendable (Data, UInt64) -> Void)
    /// Interfaces being captured, and the last capture error if any.
    func captureStatus(reply: @escaping @Sendable ([String], String?) -> Void)
    /// Quit, so launchd restarts the daemon from the updated binary inside the app bundle.
    func exitForUpdate()
}
