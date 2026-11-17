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
    static let devices: [(name: String, size: CGSize)] = [("iPhone", CGSize(width: 1080, height: 2340)), ("Apple Watch", CGSize(width: 820, height: 1004))]
    static let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("iLiveWally")

    static func write(_ buffer: CVPixelBuffer, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard let image, let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    // What an iPhone camera writes into every Live Photo movie and iOS insists on before it will animate a wallpaper:
    // the setup data of the "live-photo-info" track and one frame's sample. Both are opaque Apple data, taken from the
    // device-verified template in github.com/pudding0503/live-photo-batch (MIT), which found these rules by testing on an iPhone.
    private static let infoSetup = Data(base64Encoded: "AAABWWNmZ3ZicGxpc3QwMNMBAgMEBQxfECFMaXZlUGhvdG9NZXRhZGF0YVNldHVwRGF0YVZlcnNpb25dU3lzdGVtVmVyc2lvbl8QEUZyYW1ld29ya1ZlcnNpb25zEAHTBgcICQoLXxATUHJvZHVjdEJ1aWxkVmVyc2lvbltQcm9kdWN0TmFtZV5Qcm9kdWN0VmVyc2lvblgyMUE1Mjc3aFlpUGhvbmUgT1NUMTcuMNQNDg8QERITFFpDb3JlTW90aW9uXUNNQ2FwdHVyZUNvcmVeSDEwSVNQU2VydmljZXNZQ29yZU1lZGlhWDI4NjguMC4yVzQ0Ni41LjNUMjAuMl4zMDQ1LjY5LjIuMTEuNAAIAA8AMwBBAFUAVwBeAHQAgACPAJgAogCnALAAuwDJANgA4gDrAPMA+AAAAAAAAAIBAAAAAAAAABUAAAAAAAAAAAAAAAAAAAEHAAAAEGRpbXMAAAeAAAAFoA==")!
    private static let infoSample = Data(base64Encoded: "AwAAAL3DbTzjtettgAAAAHuArUJaLWRBCgjLPn/upr156fY/AACAQAQA/wAAAAAAAAAAAAAAAAAAAAAAAAAAAAcAAABSXoc+5m5SvxsqasTTeGK/dh7SPd4/jsMT9S85svBEOf8wnb8aF/HtGwcAACBnlu0bBwAAAAAAAAAAAAAAAAAAAAAAAA==")!

    /// A Live Photo of `w` as it looks with the current settings: `base`.heic and `base`.mov, tied together by a shared
    /// content identifier (in the photo's Apple maker note and the movie's metadata). That pairing makes it a Live Photo.
    /// The rest is what iOS needs to offer it as a moving wallpaper, none of it documented by Apple: 60 fps HEVC on a
    /// 1/600 timebase, a photo equal to the opening frame, and the camera's three timed metadata items tied to the video.
    static func livePhoto(_ c: Config, _ w: Wallpaper, size: CGSize, to base: URL, seconds: Double = 2.5) throws -> [URL] {
        let id = UUID().uuidString, fps: Int32 = 60, tick: Int32 = 600
        let photo = base.appendingPathExtension("heic"), video = base.appendingPathExtension("mov")
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        for old in [photo, video] { try? FileManager.default.removeItem(at: old) }

        let mdta = "mdta/com.apple.quicktime.", ident = kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier
        let dtype = kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType
        func item(_ key: String, _ value: NSCopying & NSObjectProtocol, _ type: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.keySpace = .quickTimeMetadata; m.key = "com.apple.quicktime.\(key)" as NSString; m.value = value; m.dataType = type
            return m
        }
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        writer.movieTimeScale = tick
        writer.metadata = [item("content.identifier", id as NSString, kCMMetadataBaseDataType_UTF8 as String)]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel, AVVideoExpectedSourceFrameRateKey: fps,
                                              AVVideoAllowFrameReorderingKey: false], // like the camera: no B-frames
        ])
        input.mediaTimeScale = tick
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        func metadataTrack(_ specs: [[CFString: Any]]) -> AVAssetWriterInputMetadataAdaptor {
            var format: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: nil, metadataType: kCMMetadataFormatType_Boxed,
                                                                        metadataSpecifications: specs as CFArray, formatDescriptionOut: &format)
            let track = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
            track.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.metadataReferent.rawValue)
            writer.add(track)
            return AVAssetWriterInputMetadataAdaptor(assetWriterInput: track)
        }
        // The camera's private data type has to be registered before CoreMedia will describe a track with it.
        CMMetadataDataTypeRegistryRegisterDataType("com.apple.quicktime.com.apple.quicktime.live-photo-info" as CFString, description: "Live Photo info" as CFString,
                                                   conformingDataTypes: [kCMMetadataBaseDataType_RawData] as CFArray)
        let infoType = "com.apple.quicktime.com.apple.quicktime.live-photo-info", transformType = kCMMetadataBaseDataType_PerspectiveTransformF64 as String
        let infoTrack = metadataTrack([[ident: mdta + "live-photo-info", dtype: infoType, kCMMetadataFormatDescriptionMetadataSpecificationKey_SetupData: infoSetup]])
        let stillTrack = metadataTrack([[ident: mdta + "still-image-time", dtype: kCMMetadataBaseDataType_SInt8],
                                        [ident: mdta + "live-photo-still-image-transform", dtype: transformType]])
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let offscreen = Offscreen(size: size)
        let frames = Int(seconds * Double(fps)), speed = Double(c.values(w)[0])
        let audio = w.reactive ? Analyzer() : nil // no music in a photo: reactive wallpapers move to the built-in beat
        for i in -Int(fps) * 2..<frames { // two seconds of run-up let a reactive wallpaper's spectrum settle
            let t = 30 + Double(i) / Double(fps)
            audio?.update(Engine.synth(at: t, count: 2048), sampleRate: 48000, dt: 1 / Float(fps), gain: c.gain)
            if i < 0 { continue }
            let buffer = try offscreen.frame(c, w, time: t * speed, audio: audio)
            while !input.isReadyForMoreMediaData { usleep(2000) }
            let range = CMTimeRange(start: CMTime(value: CMTimeValue(i) * 10, timescale: tick), duration: CMTime(value: 10, timescale: tick))
            guard adaptor.append(buffer, withPresentationTime: range.start),
                  infoTrack.append(AVTimedMetadataGroup(items: [item("live-photo-info", infoSample as NSData, infoType)], timeRange: range))
            else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            if i == 0 { try write(buffer, to: photo, type: .heic, properties: [kCGImagePropertyMakerAppleDictionary: ["17": id]]) }
        }
        // As the camera writes it: the still-image marker (-1) with an identity transform, 250 ticks in.
        let identity = [1, 0, 0, 0, 1, 0, 0, 0, 1].map { NSNumber(value: Double($0)) } as NSArray
        guard stillTrack.append(AVTimedMetadataGroup(items: [item("still-image-time", -1 as NSNumber, kCMMetadataBaseDataType_SInt8 as String),
                                                             item("live-photo-still-image-transform", identity, transformType)],
                                                     timeRange: CMTimeRange(start: CMTime(value: 250, timescale: tick), duration: CMTime(value: 1, timescale: tick))))
        else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.inputs.forEach { $0.markAsFinished() }
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
