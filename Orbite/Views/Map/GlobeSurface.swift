import AppKit
import MetalKit
import SwiftUI

/// Mirrors GlobeUniforms in Globe.metal, field for field.
private struct GlobeUniforms {
    var glow: SIMD4<Float>
    var ocean: SIMD4<Float>
    var sun: SIMD4<Float>
    var night: SIMD4<Float>
    var center: SIMD2<Float>
    var radius: Float
    var latitude: Float
    var longitude: Float
    var lod: Float
    var hasTexture: Float
}

/// The Earth itself, drawn by Metal: a sphere wearing the Plan map, with its atmosphere.
/// Draws only when the camera or the texture changes, in the same Core Animation transaction as the
/// SwiftUI places over it: the globe and its pins move in the same frame.
struct GlobeSurface: NSViewRepresentable {
    let camera: GlobeCamera
    let texture: CGImage?
    let dark: Bool
    /// Unit vector towards the light, Earth-fixed: the sun, or a fixed light from the upper left.
    let light: SIMD3<Double>
    /// Night falls where the light does not reach; off, the whole globe keeps the Plan's colours.
    let dayNight: Bool
    /// Points from the middle of the view to the globe's centre, along x.
    var shift: CGFloat = 0

    func makeCoordinator() -> GlobeRenderer { GlobeRenderer() }

    func makeNSView(context: Context) -> MTKView { context.coordinator.makeView() }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(view, camera: camera, texture: texture, dark: dark, light: light, dayNight: dayNight,
                                   shift: shift)
    }
}

/// Lets the mouse through to SwiftUI, which turns the globe and handles the clicks on the places.
private final class GlobeMetalView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class GlobeRenderer: NSObject, MTKViewDelegate {
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private lazy var pipeline: MTLRenderPipelineState? = makePipeline()
    private var texture: MTLTexture?
    private var textureSource: CGImage?
    private var camera = GlobeCamera(latitude: 0, longitude: 0, radius: 100)
    private var dark = false
    private var light = SIMD3<Double>(1, 0, 0)
    private var dayNight = false
    private var shift: CGFloat = 0

    func makeView() -> MTKView {
        let view = GlobeMetalView(frame: .zero, device: device)
        view.delegate = self
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        // The map texture holds sRGB values: show them as they are.
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Presented with the transaction SwiftUI commits, not whenever the GPU is done.
        (view.layer as? CAMetalLayer)?.presentsWithTransaction = true
        return view
    }

    func update(_ view: MTKView, camera: GlobeCamera, texture source: CGImage?, dark: Bool,
                light: SIMD3<Double>, dayNight: Bool, shift: CGFloat) {
        if source !== textureSource {
            textureSource = source
            if let source { upload(source, to: view) }
        }
        guard camera != self.camera || dark != self.dark || light != self.light || dayNight != self.dayNight
            || shift != self.shift else { return }
        self.camera = camera
        self.dark = dark
        self.light = light
        self.dayNight = dayNight
        self.shift = shift
        // Now, inside SwiftUI's update, where the places take their new positions: not at the next display pass.
        view.draw()
    }

    /// The loader decodes the image and builds the mipmaps off the main thread; the old texture stays meanwhile.
    private func upload(_ image: CGImage, to view: MTKView) {
        guard let device else { return }
        let loader = MTKTextureLoader(device: device)
        Task { [weak self, weak view] in
            let texture = try? await loader.newTexture(cgImage: image, options: [
                .SRGB: false,
                .allocateMipmaps: true,
                .generateMipmaps: true,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ])
            guard let self, let texture, self.textureSource === image else { return }
            self.texture = texture
            view?.needsDisplay = true
        }
    }

    fileprivate static func uniforms(camera: GlobeCamera, drawableSize: CGSize, scale: Float, texture: MTLTexture?,
                                     dark: Bool, light: SIMD3<Double>, dayNight: Bool, shift: Float = 0) -> GlobeUniforms {
        let radius = Float(camera.radius) * scale
        var lod: Float = 0
        if let texture {
            // Texels per screen pixel along the equator, at the middle of the disc.
            lod = max(0, log2(Float(texture.width) / (2 * .pi * radius)))
        }
        return GlobeUniforms(
            glow: dark ? SIMD4(0.36, 0.62, 1.0, 0.55) : SIMD4(0.50, 0.74, 1.0, 0.65),
            ocean: dark ? SIMD4(0.11, 0.17, 0.30, 1) : SIMD4(0.55, 0.76, 0.95, 1),
            sun: SIMD4(Float(light.x), Float(light.y), Float(light.z), 0),
            // The dark map is already dim: its night side keeps more. Alpha 0: no night at all.
            night: dark ? SIMD4(0.30, 0.34, 0.50, dayNight ? 1 : 0) : SIMD4(0.20, 0.24, 0.38, dayNight ? 1 : 0),
            center: SIMD2(Float(drawableSize.width) / 2 + shift * scale, Float(drawableSize.height) / 2),
            radius: radius,
            latitude: Float(camera.latitude * .pi / 180),
            longitude: Float(camera.longitude * .pi / 180),
            lod: lod,
            hasTexture: texture == nil ? 0 : 1)
    }

    fileprivate static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "globeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "globeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func makePipeline() -> MTLRenderPipelineState? {
        guard let device, let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "globeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "globeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let pipeline, let queue, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, view.bounds.width > 0,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Self.uniforms(camera: camera, drawableSize: view.drawableSize,
                                     scale: Float(view.drawableSize.width / view.bounds.width), texture: texture,
                                     dark: dark, light: light, dayNight: dayNight, shift: Float(shift))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GlobeUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
    }
}

/// The globe drawn once into an image, off screen, for the recap's shareable card.
enum GlobeSnapshot {
    /// A single small pass: waiting for it here is shorter than a hop through a continuation.
    private static func finish(_ commands: MTLCommandBuffer) {
        commands.commit()
        commands.waitUntilCompleted()
    }

    static func render(camera: GlobeCamera, size: CGSize, scale: CGFloat, texture image: CGImage?, dark: Bool,
                       light: SIMD3<Double>, dayNight: Bool) async -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let pipeline = GlobeRenderer.makePipeline(device: device) else { return nil }
        var texture: MTLTexture?
        if let image {
            texture = try? await MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
                .SRGB: false,
                .allocateMipmaps: true,
                .generateMipmaps: true,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ])
        }
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = GlobeRenderer.uniforms(camera: camera, drawableSize: CGSize(width: width, height: height),
                                              scale: Float(scale), texture: texture, dark: dark, light: light, dayNight: dayNight)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GlobeUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        finish(commands)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data else { return nil }
        target.getBytes(data, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return context.makeImage()
    }
}
