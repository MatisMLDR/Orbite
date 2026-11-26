// Builds the README images, the GitHub social preview and the DMG background from the demo screenshots.
// Usage: scripts/screenshots.sh && swift scripts/marketing/compose.swift
// Reads build/screenshots/*.png and the app icon; writes docs/images/ and scripts/dmg/background.tiff.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let shots = root.appendingPathComponent("build/screenshots")
let images = root.appendingPathComponent("docs/images")
try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

// The icon's night blues and its two comets (scripts/make-icon.swift).
let top = NSColor(srgbRed: 0x22 / 255, green: 0x32 / 255, blue: 0x7A / 255, alpha: 1)
let middle = NSColor(srgbRed: 0x0E / 255, green: 0x1A / 255, blue: 0x48 / 255, alpha: 1)
let bottom = NSColor(srgbRed: 0x07 / 255, green: 0x0C / 255, blue: 0x24 / 255, alpha: 1)
let glow = NSColor(srgbRed: 0x3D / 255, green: 0x7B / 255, blue: 1, alpha: 1)
let pink = NSColor(srgbRed: 0xE4 / 255, green: 0x63 / 255, blue: 0xF2 / 255, alpha: 1)

/// Draws into a bitmap of exactly `width` × `height` pixels, origin at the bottom left.
func canvas(_ width: Int, _ height: Int, draw: (CGRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func background(_ rect: CGRect) {
    NSGradient(colors: [top, middle, bottom], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!.draw(in: rect, angle: -90)
    // A soft blue glow behind the window, a pink one at a corner, like the comets.
    NSGradient(starting: glow.withAlphaComponent(0.35), ending: glow.withAlphaComponent(0))!
        .draw(fromCenter: CGPoint(x: rect.midX, y: rect.height * 0.35), radius: 0,
              toCenter: CGPoint(x: rect.midX, y: rect.height * 0.35), radius: rect.width * 0.55, options: [])
    NSGradient(starting: pink.withAlphaComponent(0.18), ending: pink.withAlphaComponent(0))!
        .draw(fromCenter: CGPoint(x: rect.width * 0.92, y: rect.height * 0.95), radius: 0,
              toCenter: CGPoint(x: rect.width * 0.92, y: rect.height * 0.95), radius: rect.width * 0.35, options: [])
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: CGRect,
          alignment: NSTextAlignment = .center) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
        .kern: size * -0.01,
    ]
    NSAttributedString(string: string, attributes: attributes).draw(with: rect, options: [.usesLineFragmentOrigin])
}

/// The screenshot with the window's rounded corners and a deep shadow.
func window(_ image: NSImage, in rect: CGRect, radius: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = rect.width * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.01)
    shadow.set()
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.14).setStroke()
    path.lineWidth = 2
    path.stroke()
}

func save(_ rep: NSBitmapImageRep, _ name: String, jpeg: Bool = true) {
    let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])!
        : rep.representation(using: .png, properties: [:])!
    let url = images.appendingPathComponent(name)
    try! data.write(to: url)
    print("→ \(url.path.replacingOccurrences(of: root.path + "/", with: "")) (\(data.count / 1024) KB)")
}

func shot(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: shots.appendingPathComponent("\(name).png")) else {
        fatalError("missing build/screenshots/\(name).png: run scripts/screenshots.sh first")
    }
    return image
}

// MARK: - Feature images: a headline over the window, which runs off the bottom edge.

let features: [(file: String, shot: String, title: String, subtitle: String)] = [
    ("hero.jpg", "globe", "Every connection your Mac makes,\nlive on a 3D globe",
     "Apps, domains, cities and countries, as they happen. Everything stays on your Mac."),
    ("apps.jpg", "app", "See which app talks to whom",
     "Each app's destinations, hostnames, ports, protocols and latency."),
    ("privacy.jpg", "tracker", "Spot trackers and clear-text traffic",
     "DuckDuckGo's tracker lists, matched on your Mac. Unencrypted connections stand out."),
    ("places.jpg", "place", "Know where your data travels",
     "Every server on the map: city, owner, distance, and how long light takes to get there."),
    ("recap.jpg", "recap", "Your week on the network",
     "Top apps, countries, trackers and the busiest hours, in a recap you can share."),
    ("diagnosis.jpg", "diagnosis", "Why is it slow? Find out",
     "Router, internet, Wi-Fi signal and the hungriest apps, checked in a few seconds."),
    ("search.jpg", "search", "Find anything with ⌘K",
     "Apps, domains, places, trackers and every action, one keystroke away."),
]

for feature in features {
    let rep = canvas(2400, 1500) { rect in
        background(rect)
        let lines = feature.title.components(separatedBy: "\n").count
        let titleHeight: CGFloat = CGFloat(lines) * 100
        text(feature.title, size: 84, weight: .bold, color: .white,
             in: CGRect(x: 120, y: rect.height - 110 - titleHeight, width: rect.width - 240, height: titleHeight))
        text(feature.subtitle, size: 38, weight: .regular, color: NSColor.white.withAlphaComponent(0.68),
             in: CGRect(x: 160, y: rect.height - 150 - titleHeight - 60, width: rect.width - 320, height: 60))
        let width: CGFloat = 1960
        let height = width * 1800 / 2880
        let windowTop = rect.height - 150 - titleHeight - 110
        window(shot(feature.shot), in: CGRect(x: (rect.width - width) / 2, y: windowTop - height, width: width, height: height),
               radius: 26)
    }
    save(rep, feature.file)
}

// MARK: - GitHub social preview, 1280 × 640.

let icon = NSImage(contentsOf: root.appendingPathComponent("Orbite/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"))!
let social = canvas(1280, 640) { rect in
    background(rect)
    // The globe from the hero screenshot, cut along its rim so it floats. The screenshot is 1440 × 900 points
    // (2x pixels); the globe's centre sits at (708, 451) from the bottom left, with a 362-point radius.
    let globe = shot("globe")
    let source = CGRect(x: 708 - 380, y: 451 - 380, width: 760, height: 760)
    let target = CGRect(x: 690, y: 0, width: 640, height: 640)
    let center = CGPoint(x: target.midX, y: target.midY), radius = 362 * target.width / source.width
    NSGradient(starting: glow.withAlphaComponent(0.45), ending: glow.withAlphaComponent(0))!
        .draw(fromCenter: center, radius: radius * 0.9, toCenter: center, radius: radius * 1.25, options: [])
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).addClip()
    globe.draw(in: target, from: source, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    icon.draw(in: CGRect(x: 72, y: 380, width: 168, height: 168))
    text("Orbite", size: 92, weight: .bold, color: .white, in: CGRect(x: 72, y: 250, width: 560, height: 110),
         alignment: .left)
    text("Every connection your Mac makes,\nlive on a world map and 3D globe.", size: 30, weight: .medium,
         color: NSColor.white.withAlphaComponent(0.82), in: CGRect(x: 72, y: 150, width: 600, height: 90), alignment: .left)
    text("Free & open source  ·  macOS 26  ·  100% local", size: 22, weight: .semibold,
         color: glow.blended(withFraction: 0.35, of: .white)!, in: CGRect(x: 72, y: 80, width: 600, height: 30),
         alignment: .left)
}
save(social, "social-preview.png", jpeg: false)

// MARK: - DMG background, 660 × 400 points, at 1x and 2x.

func dmgBackground(scale: CGFloat) -> NSBitmapImageRep {
    canvas(Int(660 * scale), Int(400 * scale)) { rect in
        background(rect)
        // An arrow from the app (x 180) to Applications (x 480), at the icons' height (y 190 from the top).
        let y = rect.height - 190 * scale
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: 268 * scale, y: y))
        arrow.line(to: CGPoint(x: 386 * scale, y: y))
        arrow.lineWidth = 5 * scale
        arrow.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.55).setStroke()
        arrow.stroke()
        let head = NSBezierPath()
        head.move(to: CGPoint(x: 370 * scale, y: y + 16 * scale))
        head.line(to: CGPoint(x: 392 * scale, y: y))
        head.line(to: CGPoint(x: 370 * scale, y: y - 16 * scale))
        head.lineWidth = 5 * scale
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.stroke()
        text("Drag Orbite to Applications", size: 17 * scale, weight: .medium,
             color: NSColor.white.withAlphaComponent(0.7), in: CGRect(x: 0, y: 56 * scale, width: rect.width, height: 28 * scale))
    }
}
let dmg = root.appendingPathComponent("scripts/dmg")
try? FileManager.default.createDirectory(at: dmg, withIntermediateDirectories: true)
let temporary = FileManager.default.temporaryDirectory
let one = temporary.appendingPathComponent("orbite-dmg.png"), two = temporary.appendingPathComponent("orbite-dmg@2x.png")
try! dmgBackground(scale: 1).representation(using: .png, properties: [:])!.write(to: one)
try! dmgBackground(scale: 2).representation(using: .png, properties: [:])!.write(to: two)
let tiff = Process()
tiff.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiff.arguments = ["-cathidpicheck", one.path, two.path, "-out", dmg.appendingPathComponent("background.tiff").path]
try! tiff.run()
tiff.waitUntilExit()
print("→ scripts/dmg/background.tiff")
