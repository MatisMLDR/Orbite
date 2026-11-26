import AppKit

/// Apps that open web links. They meet new domains all day, and a site they open on purpose is no tracker.
enum Browsers {
    private static var bundleIDs: Set<String>?
    private static var answers: [String: Bool] = [:]

    static func contains(_ identity: AppIdentity?) -> Bool {
        guard let identity, let path = identity.bundlePath else { return false }
        if let known = answers[identity.id] { return known }
        if bundleIDs == nil {
            let probe = URL(string: "https://example.com")!
            bundleIDs = Set(NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { Bundle(url: $0)?.bundleIdentifier })
        }
        let answer = Bundle(path: path)?.bundleIdentifier.map { bundleIDs?.contains($0) == true } ?? false
        answers[identity.id] = answer
        return answer
    }
}
