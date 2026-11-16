import MetalKit

/// A Metal view that draws the wallpaper chosen for one place (a display, the screen saver, the lock screen).
/// The desktop windows, the settings preview and the screen saver are all this view.
final class WallView: MTKView, MTKViewDelegate {
    static var shaderURL = Bundle(for: WallView.self).url(forResource: "Shaders", withExtension: "metal")
    private static var library: MTLLibrary?
    private static var pipelines: [String: MTLRenderPipelineState] = [:]
    private static let lock = NSLock() // exports and stills render on background threads

    private let config: () -> Config
    private let place: String
    private let queue: MTLCommandQueue
    private var time = 0.0, seen = Engine.shared.now

    init(frame: CGRect, place: String, config: @escaping () -> Config) {
        let device = MTLCreateSystemDefaultDevice()!
        self.config = config
        self.place = place
        queue = device.makeCommandQueue()!
        super.init(frame: frame, device: device)
        autoResizeDrawable = false // draw(in:) sizes the drawable itself, to apply the render scale
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError() }

    // Shaders are compiled from source at first use, so the build needs no Metal toolchain.
    static func pipeline(_ device: MTLDevice, _ frag: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        lock.lock(); defer { lock.unlock() }
        let key = "\(frag)-\(format.rawValue)"
        if let p = pipelines[key] { return p }
        if library == nil {
            guard let url = shaderURL else { throw CocoaError(.fileNoSuchFile) }
            library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library!.makeFunction(name: "vsQuad")
        d.fragmentFunction = library!.makeFunction(name: frag)
        d.colorAttachments[0].pixelFormat = format
        let p = try device.makeRenderPipelineState(descriptor: d)
        pipelines[key] = p
        return p
    }

    /// Packs `struct U` of Shaders.metal and draws the full-screen triangle. Stills, Live Photos and the tests render through this too.
    /// `time` is the wallpaper's own speed-scaled clock, `real` runs at wall speed; without `audio` the picture is the silent one.
    static func encode(_ enc: MTLRenderCommandEncoder, _ c: Config, _ w: Wallpaper, time: Double, real: Double, audio a: Analyzer?,
                       size: CGSize, format: MTLPixelFormat) throws {
        let v = c.values(w), k = w.reactive && a != nil ? v[7] : 0
        // shortcut: time wraps every 4 h so Float keeps sub-frame precision, at the cost of one visible jump per wrap; pass it as two floats if that ever bothers anyone.
        func wrapped(_ t: Double) -> Float { Float(t.truncatingRemainder(dividingBy: 14400)) }
        var u = [SIMD4<Float>](repeating: .zero, count: 12)
        u[0] = [Float(size.width), Float(size.height), wrapped(time), wrapped(real)]
        u[1] = SIMD4(a?.bass ?? 0, a?.mid ?? 0, a?.treble ?? 0, a?.level ?? 0) * k
        u[2] = [(a?.beat ?? 0) * k, 0, 0, 0]
        u[3] = [v[1], v[2], v[3], v[4] * .pi / 180]
        u[4] = [v[5], v[6], 0, 0]
        for (i, x) in v.dropFirst(commonParams.count).prefix(12).enumerated() { u[5 + i / 4][i % 4] = x }
        for (i, col) in c.colors(w).prefix(4).enumerated() { u[8 + i] = [col[0], col[1], col[2], 1] }
        let silent = [Float](repeating: 0, count: Analyzer.bands)
        enc.setRenderPipelineState(try pipeline(enc.device, w.frag, format))
        enc.setFragmentBytes(u, length: 12 * 16, index: 0)
        enc.setFragmentBytes(a?.spectrum.map { $0 * k } ?? silent, length: Analyzer.bands * 4, index: 1)
        enc.setFragmentBytes(a?.wave ?? silent, length: Analyzer.bands * 4, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    func draw(in view: MTKView) {
        let c = config(), w = c.wallpaper(place), e = Engine.shared
        if preferredFramesPerSecond != c.fps { preferredFramesPerSecond = c.fps }
        let px = convertToBacking(bounds).size, s = CGFloat(c.renderScale)
        let want = CGSize(width: max(16, (px.width * s).rounded()), height: max(16, (px.height * s).rounded()))
        if drawableSize != want { drawableSize = want }
        e.tick()
        time += (e.now - seen) * Double(c.values(w)[0])
        seen = e.now
        if w.reactive { e.listen(gain: c.gain) }
        guard let drawable = currentDrawable, let rpd = currentRenderPassDescriptor, let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        do { try Self.encode(enc, c, w, time: time, real: e.now, audio: w.reactive ? e.analyzer : nil, size: drawableSize, format: colorPixelFormat) }
        catch { NSLog("iLiveWally: %@", "\(error)") }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
