import AVFoundation
import MetalKit

// Self-check, run by build.sh: every wallpaper fits the uniform block, its shader compiles and draws a picture
// (saved to build/snapshots for a look); settings load and resolve per place; a Live Photo comes out as a matched pair.
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
WallView.shaderURL = URL(fileURLWithPath: "Sources/Shared/Shaders.metal")
let out = URL(fileURLWithPath: "build/snapshots")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let (w, h) = (960, 540)
let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
td.usage = [.renderTarget, .shaderRead]
let tex = device.makeTexture(descriptor: td)!

var cfg = Config()
for wp in wallpapers {
    precondition(wp.params.count <= 12 && wp.colors.count <= 4, "\(wp.id) overflows the uniform block")
    let audio = wp.reactive ? Analyzer() : nil
    for i in 0..<600 { audio?.update(Engine.synth(at: Double(i) / 60, count: 2048), sampleRate: 48000, dt: 1.0 / 60, gain: 1) } // 10 s of music

    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = tex
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    let cb = queue.makeCommandBuffer()!, enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
    try WallView.encode(enc, cfg, wp, time: 10, real: 10, audio: audio, size: CGSize(width: w, height: h), format: .rgba8Unorm)
    enc.endEncoding()
    cb.commit()
    await cb.completed()

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    let px = rep.bitmapData!
    tex.getBytes(px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let lit = stride(from: 0, to: w * h * 4, by: 4).filter { Int(px[$0]) + Int(px[$0 + 1]) + Int(px[$0 + 2]) > 60 }.count
    precondition(lit > w * h / 200, "\(wp.id) rendered an (almost) black frame")
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(wp.id).png"))
}

// Settings: round trip, stale slider lists, per-place choice, and files written by an older version.
cfg.values["Bars"] = wallpapers[0].all.map(\.def)
cfg.places["lock"] = "Rain"
let saved = try JSONEncoder().encode(cfg)
precondition(Config.load(saved) == cfg, "config round trip")
precondition(cfg.wallpaper("lock").id == "Rain" && cfg.wallpaper("saver").id == cfg.selected && cfg.wallpaper("no such display").id == cfg.selected)
cfg.values["Bars"] = [1, 2] // stale list from an older version → defaults
precondition(cfg.values(wallpapers[0]) == wallpapers[0].all.map(\.def))
let old = Config.load(Data(#"{"selected":"Rain","liveLock":true,"fps":30}"#.utf8)) // unknown key ignored, missing keys defaulted
precondition(old.selected == "Rain" && old.fps == 30 && old.matchSystem && old.places.isEmpty, "older config must still load")
precondition(Config.load(Data("junk".utf8)) == Config())

// Live Photo: the photo's maker note and the movie's metadata must carry the same identifier, and the movie must have
// what iOS wants before it animates a wallpaper: 60 fps and the camera's three timed metadata items.
let files = try Export.livePhoto(Config(), wallpapers[0], size: CGSize(width: 320, height: 480), to: URL(fileURLWithPath: "build/snapshots/live-test"), seconds: 1)
let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(files[0] as CFURL, nil)!, 0, nil) as! [CFString: Any]
let photoID = (props[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?["17"] as? String
let movie = AVURLAsset(url: files[1])
let ids = AVMetadataItem.metadataItems(from: try await movie.load(.metadata), filteredByIdentifier: .quickTimeMetadataContentIdentifier)
let videoID = try await ids.first?.load(.stringValue)
precondition(photoID != nil && photoID == videoID, "Live Photo pair does not share an identifier: \(photoID ?? "nil") / \(videoID ?? "nil")")
var timed: Set<String> = []
for track in try await movie.loadTracks(withMediaType: .metadata) {
    for format in try await track.load(.formatDescriptions) { timed.formUnion((CMMetadataFormatDescriptionGetIdentifiers(format) as? [String]) ?? []) }
}
let wanted = ["live-photo-info", "live-photo-still-image-transform", "still-image-time"].map { "mdta/com.apple.quicktime." + $0 }
precondition(timed == Set(wanted), "Live Photo movie has timed metadata \(timed)")
let rate = try await movie.loadTracks(withMediaType: .video)[0].load(.nominalFrameRate)
let seconds = try await movie.load(.duration).seconds
precondition(abs(rate - 60) < 0.5 && abs(seconds - 1) < 0.1, "Live Photo movie: \(rate) fps, \(seconds) s")
print("ok: \(wallpapers.count) wallpapers render, settings load, Live Photo has what iOS wallpapers need")
