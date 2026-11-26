import Foundation

/// How the sidebar names the other end of a connection.
nonisolated enum HostLabelKind: String, Codable, Sendable {
    /// A domain seen in DNS (youtube.com).
    case domain
    /// The network that owns the address (Google, Akamai), from the ASN database.
    case organization
    /// Nothing better than the address itself.
    case address
    /// A device on the local network.
    case local
}

nonisolated enum HostLabel {
    /// Second-level suffixes under which names register one level deeper (bbc.co.uk).
    private static let compoundSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "com.br", "net.br", "org.br", "gov.br",
        "com.cn", "net.cn", "org.cn", "gov.cn",
        "com.tw", "com.hk", "com.sg", "com.my", "com.tr", "com.mx", "com.ar", "com.co",
        "co.kr", "or.kr", "co.nz", "co.in", "co.za", "co.il", "co.id", "co.th",
        "gouv.fr", "asso.fr", "nom.fr",
        "cloudfront.net", "amazonaws.com", "azurewebsites.net", "herokuapp.com",
        "github.io", "vercel.app", "netlify.app", "pages.dev", "workers.dev",
    ]

    /// The registrable part of a hostname: rr3---sn-25g.googlevideo.com → googlevideo.com.
    static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if compoundSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    private static let wellKnown: [(String, String)] = [
        ("google", "Google"), ("akamai", "Akamai"), ("amazon", "Amazon"), ("cloudflare", "Cloudflare"),
        ("microsoft", "Microsoft"), ("fastly", "Fastly"), ("apple", "Apple"), ("facebook", "Meta"),
        ("meta platforms", "Meta"), ("netflix", "Netflix"), ("ovh", "OVH"), ("hetzner", "Hetzner"),
        ("digitalocean", "DigitalOcean"), ("github", "GitHub"), ("twitter", "X"), ("tiktok", "TikTok"),
        ("bytedance", "ByteDance"), ("spotify", "Spotify"), ("zscaler", "Zscaler"), ("edgecast", "Edgio"),
        ("limelight", "Edgio"), ("level 3", "Lumen"), ("free sas", "Free"), ("free mobile", "Free Mobile"),
        ("proxad", "Free"), ("orange", "Orange"), ("bouygues", "Bouygues Telecom"), ("sfr", "SFR"),
        ("anthropic", "Anthropic"), ("openai", "OpenAI"), ("oracle", "Oracle"), ("salesforce", "Salesforce"),
    ]

    private static let legalSuffixes = [
        ", inc.", " inc.", ", inc", " inc", " llc", ", llc", " l.l.c.", " ltd.", " ltd", " limited",
        " corporation", " corp.", " corp", " b.v.", " bv", " gmbh", " ag", " s.a.", " sa", " sas",
        " s.a.s.", " sarl", " s.r.l.", " srl", " plc", " co.,", " co.", " oy", " ab", " as", " a/s",
        " pty", " pte", " kk", " k.k.", " l.p.", " lp", " international", " technologies",
    ]

    /// "GOOGLE LLC" → "Google", "Akamai International B.V." → "Akamai".
    static func cleanOrganization(_ raw: String) -> String {
        let lower = raw.lowercased()
        for (needle, name) in wellKnown where lower.contains(needle) { return name }
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for suffix in legalSuffixes where name.lowercased().hasSuffix(suffix) && name.count > suffix.count + 2 {
                name = String(name.dropLast(suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
                changed = true
            }
        }
        let letters = name.filter(\.isLetter)
        if letters.count > 4, letters == letters.uppercased() {
            name = name.capitalized
        }
        return name.isEmpty ? raw : name
    }
}
