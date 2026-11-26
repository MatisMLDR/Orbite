#!/usr/bin/env swift
// Draws Orbite's app icon (the Earth in lit dots on a night-blue squircle, with three connections leaving Paris
// for New York, Mumbai and São Paulo) and writes every size into Orbite/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit
import CoreGraphics
import simd

let size: CGFloat = 1024
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appendingPathComponent("Orbite/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Draw with the origin at the top left, y going down. Shadow offsets stay in device space (y up).
context.translateBy(x: 0, y: size)
context.scaleBy(x: 1, y: -1)

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// Paints only the blurred shadow of a shape: a soft glow. `blur` is a Gaussian standard deviation.
func glow(blur: CGFloat, color glowColor: CGColor, _ draw: () -> Void) {
    context.saveGState()
    context.translateBy(x: 4000, y: 0)
    context.setShadow(offset: CGSize(width: -4000, height: 0), blur: blur * 2, color: glowColor)
    draw()
    context.restoreGState()
}

// MARK: - The land, one cell per 3° of latitude and longitude ('#' is land), from 90° N at the top, 180° W at the left.

let landMask = """
    ........................................................................................................................
    ........................................................................................................................
    ........................................................................................................................
    ................................#####...#############...................................................................
    ................................##....###############...................................................................
    ..........................................###########....................................########.......................
    .....................####......####........#########...............................#.##################...###...........
    ......########.#####.#####...#..#..###.....######.................#####.........########################################
    ......##########################....##.....###..................###.####.###############################################
    ......#######################...............##.................###.###################################################..
    .......##......##############.....###.........................####..#######################################.............
    ................##############.....#####..................#........######################################.......#.......
    .................################.#######................#.#..############################################..............
    ..................####################......................##############################################..............
    ...................############.######.....................###############################################..............
    ...................##################.......................##.#.####....###.############################...............
    ...................#################.....................###.......##..#..##..########################..................
    ....................###############......................##..........#######..#####################.....................
    ....................##############........................#.###.........############################....................
    ......................###########........................########.......############################....................
    .......................#####.............................###################.#######################....................
    ........................####...........................################.####.....###################....................
    .........................###...........................#################.######....###############......................
    ..........................##..#........................#################..#####.....####...####.........................
    ............................###........................##################.###.......###.....###.........................
    ...............................#.......................####################..........#.......###........................
    ....................................#..................####################..........#..................................
    ...................................#####................####################............................................
    ...................................########....................#############.................#....#.....................
    ..................................#########....................############..................#...##.....................
    ..................................###########..................###########...................##.##......................
    .................................###############................#########.....................#..........###............
    ..................................##############................#########.................................##............
    ..................................##############.................########...............................................
    ...................................############.................#########..............................##...............
    ....................................###########.................#########..#.........................#####.#............
    .....................................##########.................########...#........................#########...........
    .....................................#########...................#######...#......................############..........
    .....................................#######.....................######...........................############..........
    .....................................#######......................####............................#############.........
    .....................................######.......................###.............................####..######..........
    ....................................#####.................................................................####..........
    ....................................#####...............................................................................
    ....................................###.................................................................................
    ....................................##..................................................................................
    ....................................##..................................................................................
    ....................................#...................................................................................
    ....................................#...................................................................................
    ........................................................................................................................
    ........................................................................................................................
    ........................................................................................................................
    ........................................................................................................................
    ......................................#....................................#######.....#####################............
    ....................................####.................##########################################################.....
    ..................##......##############.............#############################################################......
    ..........#################################.......################################################################......
    ########################################################################################################################
    ########################################################################################################################
    ########################################################################################################################
    ########################################################################################################################
    """.split(separator: "\n").map { Array($0.utf8) }

func isLand(latitude: Double, longitude: Double) -> Bool {
    let row = min(landMask.count - 1, max(0, Int(((90 - latitude) / 3).rounded(.down))))
    let column = ((Int(((longitude + 180) / 3).rounded(.down)) % 120) + 120) % 120
    return landMask[row][column] == UInt8(ascii: "#")
}

// MARK: - The globe, seen from slightly above the equator, centred east of Paris.

let center = CGPoint(x: 512, y: 548), radius: CGFloat = 262
let tilt = 18 * Double.pi / 180, turn = -14 * Double.pi / 180

func direction(_ latitude: Double, _ longitude: Double) -> SIMD3<Double> {
    let la = latitude * .pi / 180, lo = longitude * .pi / 180
    return SIMD3(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
}

/// Turns a point of the globe into view space: x to the right, y up, z towards the viewer.
func view(_ p: SIMD3<Double>) -> SIMD3<Double> {
    let x = p.x * cos(turn) + p.z * sin(turn), z = -p.x * sin(turn) + p.z * cos(turn)
    return SIMD3(x, p.y * cos(tilt) - z * sin(tilt), p.y * sin(tilt) + z * cos(tilt))
}

func project(_ v: SIMD3<Double>) -> CGPoint {
    CGPoint(x: center.x + radius * CGFloat(v.x), y: center.y - radius * CGFloat(v.y))
}

let sphere = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
                    transform: nil)

// MARK: - Background and squircle body (824 pt on the macOS grid, a superellipse like the system's icons).

func squircle(_ side: CGFloat) -> CGPath {
    let path = CGMutablePath(), half = side / 2
    for step in 0..<360 {
        let t = Double(step) / 360 * 2 * .pi, c = cos(t), s = sin(t)
        let point = CGPoint(x: 512 + half * CGFloat(copysign(pow(abs(c), 0.4), c)),
                            y: 512 + half * CGFloat(copysign(pow(abs(s), 0.4), s)))
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

let body = squircle(824)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
context.addPath(body)
context.setFillColor(color(0x0B1433))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(body)
context.clip()
context.drawLinearGradient(gradient([(0, color(0x1D2B72)), (0.5, color(0x0D1846)), (1, color(0x050A1F))]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
context.drawRadialGradient(gradient([(0, color(0x3D7BFF, 0.45)), (0.55, color(0x3D7BFF, 0.45)), (1, color(0x3D7BFF, 0))]),
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: radius * 1.6, options: [])

// Atmosphere, then the sphere lit from the top left.
glow(blur: 16, color: color(0x4A95FF, 0.6)) {
    context.setLineWidth(30)
    context.setStrokeColor(color(0x4A95FF))
    context.strokeEllipse(in: CGRect(x: center.x - radius - 4, y: center.y - radius - 4, width: (radius + 4) * 2, height: (radius + 4) * 2))
}
context.saveGState()
context.addPath(sphere)
context.clip()
let light = CGPoint(x: center.x - radius + 0.72 * radius, y: center.y - radius + 0.6 * radius)
context.drawRadialGradient(gradient([(0, color(0x2F6BEA)), (0.5, color(0x153A9E)), (1, color(0x071444))]),
                           startCenter: light, startRadius: 0, endCenter: light, endRadius: radius * 1.7,
                           options: [.drawsAfterEndLocation])

// The continents, one dot per cell, smaller and dimmer towards the rim.
let dotScale = 1.05 * Double(radius) / 278
for latitude in stride(from: -87.0, through: 87.0, by: 3.2) {
    let count = max(1, Int((360 * cos(latitude * .pi / 180) / 3.2).rounded()))
    for index in 0..<count {
        let longitude = -180 + (Double(index) + 0.5) * 360 / Double(count)
        guard isLand(latitude: latitude, longitude: longitude) else { continue }
        let v = view(direction(latitude, longitude))
        guard v.z > 0.03 else { continue }
        let p = project(v), r = CGFloat(4.6 * dotScale * (0.45 + 0.55 * v.z))
        context.setFillColor(color(0xB5DEFF, CGFloat(0.35 + 0.65 * v.z)))
        context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }
}

// Night falls towards the bottom right.
let dusk = CGPoint(x: center.x - 0.95 * radius, y: center.y - 0.83 * radius)
context.drawRadialGradient(gradient([(0.5, color(0x020617, 0)), (1, color(0x020617, 0.72))]),
                           startCenter: dusk, startRadius: 0, endCenter: dusk, endRadius: radius * 2.14,
                           options: [.drawsAfterEndLocation])
context.restoreGState()

context.setLineWidth(3)
context.setStrokeColor(color(0xA9D6FF, 0.55))
context.strokeEllipse(in: CGRect(x: center.x - radius + 1, y: center.y - radius + 1, width: (radius - 1) * 2, height: (radius - 1) * 2))

// MARK: - Connections: great-circle arcs that rise above the surface, hidden where they pass behind the globe.

let paris = (48.86, 2.35)
func arc(to destination: (Double, Double), lift: Double) -> (path: CGPath, end: CGPoint, endVisible: Bool) {
    let a = direction(paris.0, paris.1), b = direction(destination.0, destination.1)
    let angle = acos(min(1, simd_dot(a, b))), height = (0.06 + 0.3 * angle / .pi) * lift
    let path = CGMutablePath()
    var drawing = false, end = CGPoint.zero, endVisible = false
    for step in 0...80 {
        let t = Double(step) / 80
        let p = (a * sin((1 - t) * angle) + b * sin(t * angle)) / sin(angle) * (1 + height * sin(.pi * t))
        let v = view(p), point = project(v)
        let hidden = v.z < 0 && v.x * v.x + v.y * v.y < 1
        if hidden { drawing = false } else if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
        end = point
        endVisible = !hidden
    }
    return (path, end, endVisible)
}

let home = project(view(direction(paris.0, paris.1)))
let cyan: UInt32 = 0x5CC8FF, pink: UInt32 = 0xF08CFF
for (destination, hue, lift) in [((40.71, -74.0), cyan, 1.9), ((19.08, 72.88), pink, 1.7), ((-23.55, -46.63), cyan, 1.6)] {
    let (path, end, endVisible) = arc(to: destination, lift: lift)
    glow(blur: 10, color: color(hue, 0.45)) {
        context.addPath(path)
        context.setLineWidth(26)
        context.setLineCap(.round)
        context.setStrokeColor(color(hue))
        context.strokePath()
    }
    context.saveGState()
    context.addPath(path)
    context.setLineWidth(11)
    context.setLineCap(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(gradient([(0, color(hue, 0.25)), (0.55, color(hue)), (1, color(0xFFFFFF))]),
                               start: home, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    if endVisible {
        context.drawRadialGradient(gradient([(0, color(hue, 0.9)), (1, color(hue, 0))]),
                                   startCenter: end, startRadius: 0, endCenter: end, endRadius: 44, options: [])
        context.setFillColor(color(0xFFFFFF))
        context.fillEllipse(in: CGRect(x: end.x - 13, y: end.y - 13, width: 26, height: 26))
    }
}

// The Mac: a bright point on Paris.
glow(blur: 10, color: color(0xFFFFFF, 0.24)) {
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: CGRect(x: home.x - 56, y: home.y - 56, width: 112, height: 112))
}
context.setFillColor(color(0xFFFFFF))
context.fillEllipse(in: CGRect(x: home.x - 18, y: home.y - 18, width: 36, height: 36))
context.restoreGState()

// Subtle inner highlight.
context.addPath(squircle(821))
context.setStrokeColor(color(0xFFFFFF, 0.16))
context.setLineWidth(3)
context.strokePath()

let master = context.makeImage()!
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let small = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        small.interpolationQuality = .high
        small.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let rep = NSBitmapImageRep(cgImage: small.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appendingPathComponent("Contents.json"))
print("icon written to \(iconSet.path)")
