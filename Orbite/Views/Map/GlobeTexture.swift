import AppKit
import ImageIO
import MapKit
import UniformTypeIdentifiers

/// The Plan map wrapped around the globe: four MapKit snapshots of the world (MapKit will not draw
/// it smaller), turned from Mercator into an equirectangular image and kept in the caches folder.
nonisolated enum GlobeTexture {
    /// Width of the texture; the height is half. 6144 keeps city names readable at continent scale.
    static let width = 6144
    private static let version = 1

    @MainActor
    static func load(dark: Bool) async -> CGImage? {
        let url = cacheURL(dark: dark)
        if let cached = await read(url) { return cached }
        var tiles: [Tile] = []
        do {
            for ty in 0..<2 {
                for tx in 0..<2 {
                    tiles.append(try await snapshot(tx: tx, ty: ty, dark: dark))
                }
            }
        } catch {
            return nil
        }
        guard let image = await compose(tiles) else { return nil }
        Task.detached(priority: .utility) { write(image, to: url) }
        return image
    }

    /// One quadrant of the Mercator world, and for each row of the texture the row of the quadrant
    /// to copy (nil when the latitude falls in another quadrant).
    private struct Tile: @unchecked Sendable {
        let tx: Int
        let image: CGImage
        let rows: [Int?]
    }

    @MainActor
    private static func snapshot(tx: Int, ty: Int, dark: Bool) async throws -> Tile {
        let world = MKMapRect.world.width
        let options = MKMapSnapshotter.Options()
        options.mapRect = MKMapRect(x: Double(tx) * world / 2, y: Double(ty) * world / 2, width: world / 2, height: world / 2)
        let side = 2048.0
        options.size = NSSize(width: side, height: side)
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        options.preferredConfiguration = configuration
        options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let snapshot = try await MKMapSnapshotter(options: options).start()
        var rect = CGRect(origin: .zero, size: snapshot.image.size)
        guard let image = snapshot.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // MapKit says where each latitude landed (its points count from the bottom): no guessing its edges.
        let half = width / 2
        let height = width / 2
        let rows: [Int?] = (0..<height).map { row in
            let latitude = min(85.05, max(-85.05, 90 - (Double(row) + 0.5) * 180 / Double(height)))
            let y = snapshot.point(for: CLLocationCoordinate2D(latitude: latitude, longitude: 0)).y
            let fromTop = (side - y) / side * Double(half)
            guard fromTop >= 0, fromTop < Double(half) else { return nil }
            return Int(fromTop)
        }
        return Tile(tx: tx, image: image, rows: rows)
    }

    @concurrent
    private static func compose(_ tiles: [Tile]) async -> CGImage? {
        let half = width / 2, height = width / 2
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let output = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: space, bitmapInfo: info),
              let target = output.data else { return nil }
        // Rows MapKit did not cover (the poles, past 85°) take the colour of the nearest one.
        var filled = [Bool](repeating: false, count: height * 2)
        for tile in tiles {
            guard let quadrant = CGContext(data: nil, width: half, height: half, bitsPerComponent: 8, bytesPerRow: half * 4,
                                           space: space, bitmapInfo: info),
                  let source = quadrant.data else { continue }
            quadrant.interpolationQuality = .high
            quadrant.draw(tile.image, in: CGRect(x: 0, y: 0, width: half, height: half))
            for (row, sourceRow) in tile.rows.enumerated() {
                guard let sourceRow else { continue }
                memcpy(target + row * width * 4 + tile.tx * half * 4, source + sourceRow * half * 4, half * 4)
                filled[row * 2 + tile.tx] = true
            }
        }
        for side in 0..<2 {
            let offset = side * half * 4
            guard let first = (0..<height).first(where: { filled[$0 * 2 + side] }),
                  let last = (0..<height).last(where: { filled[$0 * 2 + side] }) else { continue }
            for row in 0..<first {
                memcpy(target + row * width * 4 + offset, target + first * width * 4 + offset, half * 4)
            }
            for row in (last + 1)..<height {
                memcpy(target + row * width * 4 + offset, target + last * width * 4 + offset, half * 4)
            }
        }
        return output.makeImage()
    }

    private static func cacheURL(dark: Bool) -> URL {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
            .filter { $0.isLetter || $0.isNumber || $0 == "." }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbite", isDirectory: true)
        // A new macOS can restyle Plans: one cache per system build.
        return folder.appendingPathComponent("globe-\(dark ? "dark" : "light")-\(system)-v\(version).heic")
    }

    @concurrent
    private static func read(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Left undecoded (2 MB instead of 72): Metal's texture loader decodes it once, off the main thread.
        let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        return image?.width == width ? image : nil
    }

    private static func write(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
