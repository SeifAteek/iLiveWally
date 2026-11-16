import AVFoundation
import ImageIO
import Metal
import Photos
import UniformTypeIdentifiers
import VideoToolbox

/// Draws wallpaper frames into pixel buffers without a window: for system-wallpaper stills and Live Photos.
final class Offscreen {
    let size: CGSize
    private let queue: MTLCommandQueue
    private var cache: CVMetalTextureCache?

    init(size: CGSize) {
        self.size = size
        let device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    func frame(_ c: Config, _ w: Wallpaper, time: Double, audio: Analyzer? = nil) throws -> CVPixelBuffer {
        let (width, height) = (Int(size.width), Int(size.height))
        var buffer: CVPixelBuffer?, wrapped: CVMetalTexture?
        let attrs = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer)
        guard let buffer, let cache,
              CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapped) == kCVReturnSuccess,
              let wrapped, let texture = CVMetalTextureGetTexture(wrapped), let cb = queue.makeCommandBuffer() else { throw CocoaError(.fileWriteUnknown) }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { throw CocoaError(.fileWriteUnknown) }
        let drawn = Result { try WallView.encode(enc, c, w, time: time, real: time, audio: audio, size: size, format: .bgra8Unorm) }
        enc.endEncoding() // must happen even when encode throws
        try drawn.get()
        cb.commit()
        cb.waitUntilCompleted()
        return buffer
    }
}

enum Export {
    static let devices: [(name: String, size: CGSize)] = [("iPhone", CGSize(width: 1290, height: 2796)), ("Apple Watch", CGSize(width: 820, height: 1004))]
    static let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("iLiveWally")

    static func write(_ buffer: CVPixelBuffer, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard let image, let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A Live Photo of `w` as it looks with the current settings: `base`.heic and `base`.mov, tied together by a shared
    /// content identifier (in the photo's Apple maker note and the movie's metadata). That pairing is what Photos looks for.
    static func livePhoto(_ c: Config, _ w: Wallpaper, size: CGSize, to base: URL, seconds: Double = 3, fps: Int32 = 30) throws -> [URL] {
        let id = UUID().uuidString
        let photo = base.appendingPathExtension("heic"), video = base.appendingPathExtension("mov")
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        for old in [photo, video] { try? FileManager.default.removeItem(at: old) }

        func item(_ key: String, _ value: NSCopying & NSObjectProtocol, _ type: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.keySpace = .quickTimeMetadata; m.key = key as NSString; m.value = value; m.dataType = type
            return m
        }
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        writer.metadata = [item("com.apple.quicktime.content.identifier", id as NSString, "com.apple.metadata.datatype.UTF-8")]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        // A timed metadata track marks which video frame the photo is.
        let spec = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: "mdta/com.apple.quicktime.still-image-time",
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: "com.apple.metadata.datatype.int8"] as CFDictionary
        var format: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: nil, metadataType: kCMMetadataFormatType_Boxed,
                                                                    metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &format)
        let stillInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        let stillAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: stillInput)
        writer.add(input)
        writer.add(stillInput)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let offscreen = Offscreen(size: size)
        let frames = Int(seconds * Double(fps)), key = frames / 2, speed = Double(c.values(w)[0])
        let audio = w.reactive ? Analyzer() : nil // no music in a photo: reactive wallpapers move to the built-in beat
        for i in -Int(fps) * 2..<frames { // two seconds of run-up let a reactive wallpaper's spectrum settle
            let t = 30 + Double(i) / Double(fps)
            audio?.update(Engine.synth(at: t, count: 2048), sampleRate: 48000, dt: 1 / Float(fps), gain: c.gain)
            if i < 0 { continue }
            let buffer = try offscreen.frame(c, w, time: t * speed, audio: audio)
            while !input.isReadyForMoreMediaData { usleep(2000) }
            let time = CMTime(value: CMTimeValue(i), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            if i == key {
                stillAdaptor.append(AVTimedMetadataGroup(items: [item("com.apple.quicktime.still-image-time", 0 as NSNumber, "com.apple.metadata.datatype.int8")],
                                                         timeRange: CMTimeRange(start: time, duration: CMTime(value: 1, timescale: fps))))
                try write(buffer, to: photo, type: .heic, properties: [kCGImagePropertyMakerAppleDictionary: ["17": id]])
            }
        }
        input.markAsFinished()
        stillInput.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return [photo, video]
    }

    /// Adds the pair to the Photos library as one Live Photo; iCloud Photos then carries it to the iPhone and Watch.
    static func addToPhotos(_ files: [URL], done: @escaping (String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return done("Photos access was not allowed.") }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: files[0], options: nil)
                request.addResource(with: .pairedVideo, fileURL: files[1], options: nil)
            }) { ok, error in done(ok ? "Added to Photos as a Live Photo." : error?.localizedDescription ?? "Could not add to Photos.") }
        }
    }
}
