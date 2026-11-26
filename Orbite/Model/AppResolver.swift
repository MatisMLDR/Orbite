import AppKit
import Foundation
import Observation
import Security

/// Who is talking: an app, a macOS service (grouped under « macOS »), or a command-line tool.
nonisolated struct AppIdentity: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case app, system, tool

        var label: String {
            switch self {
            case .app: "App"
            case .system: String(localized: "macOS services")
            case .tool: String(localized: "Command-line tool")
            }
        }
    }

    var id: String
    var name: String
    var kind: Kind
    var bundlePath: String?
    /// Executable for tools; nil for the macOS group.
    var executablePath: String?

    static let macOS = AppIdentity(id: "macos", name: "macOS", kind: .system)
}

nonisolated struct ResolvedProcess: Sendable {
    var app: AppIdentity
    /// Name of the process inside its app (for macOS services: apsd, nsurlsessiond…).
    var processName: String
    var path: String
}

nonisolated struct CodeSignature: Sendable {
    enum State: Sendable {
        case valid, unsigned, invalid
    }

    var state: State
    /// Only read from a valid signature: anyone can write any identifier in a broken or forged one.
    var identifier: String?
    var teamID: String?
    /// Signed by Apple itself (`anchor apple`), checked against Apple's root certificate.
    var isApple: Bool

    static let unsigned = CodeSignature(state: .unsigned, identifier: nil, teamID: nil, isApple: false)
    static let invalid = CodeSignature(state: .invalid, identifier: nil, teamID: nil, isApple: false)

    /// « APPLE/com.apple.AppStore », « D9FCRQ6TA6/app.matis.Orbite », « ad hoc/node ».
    var codeID: String {
        switch state {
        case .unsigned: return String(localized: "unsigned")
        case .invalid: return String(localized: "invalid signature")
        case .valid:
            let owner = isApple ? "APPLE" : (teamID ?? "ad hoc")
            return "\(owner)/\(identifier ?? "?")"
        }
    }
}

/// Maps processes to the app they belong to. Same rules as StatsApp: the outermost `.app` in the
/// path decides, except XPC services, which are attributed to the process responsible for them.
@Observable
final class AppResolver {
    /// Read-only Apple locations; /usr/bin and /bin are excluded: those are tools people run.
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/lib/", "/Library/Apple/"]
    /// System locations that hold real apps (App Store, Safari, Music…).
    static let systemAppPrefixes = ["/System/Applications/", "/System/Cryptexes/App/System/Applications/"]

    @ObservationIgnored private var cache: [String: ResolvedProcess] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var signatures: [String: CodeSignature?] = [:]
    @ObservationIgnored private var pendingSignatures: Set<String> = []
    @ObservationIgnored private var bundleNames: [String: String] = [:]
    /// Bumped when a signature check finishes, so the inspector shows it.
    private(set) var signatureRevision = 0
    #if DEBUG
    /// Screenshot mode: the executables behind the made-up PIDs.
    @ObservationIgnored var demoPaths: [Int32: String] = [:]
    #endif

    func resolve(pid: Int32, name: String) -> ResolvedProcess {
        let key = "\(pid)|\(name)"
        if let cached = cache[key] { return cached }
        let resolved = compute(pid: pid, name: name)
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = resolved
        return resolved
    }

    private func compute(pid: Int32, name: String) -> ResolvedProcess {
        var own = LibProc.path(of: pid)
        #if DEBUG
        if let path = demoPaths[pid] { own = path }
        #endif
        var subject = own
        if own.isEmpty || own.contains(".xpc/") || own.contains("/XPCServices/") {
            if let responsible = LibProc.responsiblePID(of: pid), responsible != pid {
                let path = LibProc.path(of: responsible)
                if !path.isEmpty { subject = path }
            }
        }
        let processName = own.isEmpty ? name : Self.executableName(path: own)

        guard !subject.isEmpty else {
            return ResolvedProcess(app: .macOS, processName: processName, path: own)
        }
        if let bundle = Self.outermostBundle(subject) {
            let isSystemApp = Self.systemAppPrefixes.contains { bundle.hasPrefix($0) }
            if Self.isSystemPath(bundle) && !isSystemApp {
                return ResolvedProcess(app: .macOS, processName: displayName(forBundle: bundle), path: own)
            }
            let identity = AppIdentity(id: "app:\(Self.canonicalBundle(bundle))", name: displayName(forBundle: bundle),
                                       kind: .app, bundlePath: bundle, executablePath: nil)
            return ResolvedProcess(app: identity, processName: processName, path: own)
        }
        if Self.isSystemPath(subject) {
            return ResolvedProcess(app: .macOS, processName: Self.executableName(path: subject), path: own)
        }
        let toolName = Self.executableName(path: subject)
        let identity = AppIdentity(id: "tool:\(subject)", name: toolName, kind: .tool, bundlePath: nil, executablePath: subject)
        return ResolvedProcess(app: identity, processName: processName, path: own)
    }

    static func isSystemPath(_ path: String) -> Bool {
        systemPrefixes.contains { path.hasPrefix($0) }
    }

    static func outermostBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else {
            return nil
        }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Safari runs from the App cryptex but is installed as /Applications/Safari.app: one row for both.
    private static func canonicalBundle(_ bundle: String) -> String {
        bundle.replacingOccurrences(of: "/System/Cryptexes/App/System/Applications/", with: "/Applications/")
    }

    /// An executable named after its version (`…/claude/versions/2.1.311`) takes its tool's name.
    static func executableName(path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let isVersion = name.first?.isNumber == true && name.allSatisfy { $0.isNumber || $0 == "." }
        guard isVersion else { return name }
        var parent = (path as NSString).deletingLastPathComponent
        if (parent as NSString).lastPathComponent == "versions" {
            parent = (parent as NSString).deletingLastPathComponent
        }
        let tool = (parent as NSString).lastPathComponent
        return tool.isEmpty || tool == "/" ? name : tool.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func displayName(forBundle path: String) -> String {
        if let cached = bundleNames[path] { return cached }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        bundleNames[path] = name
        return name
    }

    // MARK: - Icons and signatures

    func icon(for identity: AppIdentity) -> NSImage {
        if let cached = icons[identity.id] { return cached }
        let image: NSImage
        switch identity.kind {
        case .app:
            image = NSWorkspace.shared.icon(forFile: identity.bundlePath ?? "/Applications")
        case .system:
            image = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        case .tool:
            image = NSWorkspace.shared.icon(forFile: identity.executablePath ?? "/bin/sh")
        }
        icons[identity.id] = image
        return image
    }

    func processIcon(path: String) -> NSImage {
        let key = "process:\(path)"
        if let cached = icons[key] { return cached }
        let target = Self.outermostBundle(path) ?? (path.isEmpty ? "/bin/sh" : path)
        let image = NSWorkspace.shared.icon(forFile: target)
        icons[key] = image
        return image
    }

    /// Cached signature, or nil while it is checked: checking hashes the executable, so it runs off the main thread.
    func signature(path: String) -> CodeSignature? {
        _ = signatureRevision
        if let cached = signatures[path] { return cached }
        guard !pendingSignatures.contains(path) else { return nil }
        pendingSignatures.insert(path)
        Task.detached(priority: .utility) {
            let value = Self.readSignature(path: path)
            await MainActor.run {
                self.signatures[path] = value
                self.pendingSignatures.remove(path)
                self.signatureRevision += 1
            }
        }
        return nil
    }

    /// The signature is checked before any of its fields is believed. Resources are left out: identity
    /// lives in the code directory and the certificates, and hashing a large bundle would take seconds.
    nonisolated private static func readSignature(path: String) -> CodeSignature? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSDoNotValidateResources)
        switch SecStaticCodeCheckValidity(code, flags, nil) {
        case errSecSuccess: break
        case errSecCSUnsigned: return .unsigned
        default: return .invalid
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return .invalid }
        var apple: SecRequirement?
        let isApple = SecRequirementCreateWithString("anchor apple" as CFString, [], &apple) == errSecSuccess
            && apple.map { SecStaticCodeCheckValidity(code, flags, $0) == errSecSuccess } == true
        return CodeSignature(state: .valid, identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
                             teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String, isApple: isApple)
    }
}
