import AppKit
import AudioToolbox
import CoreAudio

/// Captures everything the Mac is playing via a Core Audio process tap (macOS 14.2+). (From MacVisualiser.)
final class SystemAudio {
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 16384)
    private var writeIndex = 0
    private(set) var sampleRate: Double = 48000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    // The tap and aggregate are private to this process, so Core Audio removes them when we exit.
    func start() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create process tap")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "read tap format")
        sampleRate = asbd.mSampleRate

        let outputUID = try defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "iLiveWally Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [weak self] _, input, _, _, _ in
            self?.push(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start device")
    }

    /// Downmixes every channel of every buffer to mono into the ring.
    private func push(_ abl: UnsafeMutableAudioBufferListPointer) {
        guard let first = abl.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
        let totalChannels = Float(abl.reduce(0) { $0 + Int($1.mNumberChannels) })
        lock.lock(); defer { lock.unlock() }
        for f in 0..<frames {
            var sum: Float = 0
            for buf in abl {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = Int(buf.mNumberChannels)
                for c in 0..<ch { sum += p[f * ch + c] }
            }
            ring[writeIndex] = sum / totalChannels
            writeIndex = (writeIndex + 1) & (ring.count - 1)
        }
    }

    /// Most recent `count` samples, oldest first.
    func latest(_ count: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let start = (writeIndex - count + ring.count) & (ring.count - 1)
        return (0..<count).map { ring[(start + $0) & (ring.count - 1)] }
    }

    private func defaultOutputUID() throws -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device), "find output device")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid), "read output device UID")
        return uid!.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw NSError(domain: "Audio", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not \(what) (OSStatus \(status))"]) }
    }
}

extension NSScreen {
    /// Stable id of the physical display; it is this display's key in `Config.places`.
    var key: String {
        let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(id)"
    }
}

/// Every place a wallpaper can be chosen for.
func places() -> [(key: String, name: String)] {
    NSScreen.screens.map { ($0.key, $0.localizedName) } + [("saver", "Screen Saver"), ("lock", "Lock Screen")]
}

/// Keeps the macOS wallpaper a still of the live one. macOS paints the lock screen and tints the menu bar from its own
/// wallpaper, and no app window can get in between, so this is what makes both match.
enum SystemWallpaper {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iLiveWally/stills")
    private static let queue = DispatchQueue(label: "stills")

    /// Each display gets a still of its own wallpaper, or of the lock screen's while the Mac is locked.
    static func sync() {
        let c = Store.shared.cfg
        guard c.matchSystem else { return }
        var jobs: [(screen: NSScreen, url: URL, w: Wallpaper, size: CGSize)] = [], keep: Set<String> = []
        for screen in NSScreen.screens {
            let size = screen.convertRectToBacking(screen.frame).size
            for place in [screen.key, "lock"] {
                // The file name changes with anything that changes the picture: macOS does not reload a path it has already shown.
                let w = c.wallpaper(place), look = "\(w.id)\(c.values(w))\(c.colors(w))\(size)"
                let hash = look.utf8.reduce(14695981039346656037 as UInt64) { ($0 ^ UInt64($1)) &* 1099511628211 }
                let url = folder.appendingPathComponent("\(w.id)-\(String(hash, radix: 16)).jpg")
                keep.insert(url.lastPathComponent)
                if place == (c.locked ? "lock" : screen.key) { jobs.append((screen, url, w, size)) }
            }
            if c.originalWallpapers[screen.key] == nil, let now = NSWorkspace.shared.desktopImageURL(for: screen), !now.path.hasPrefix(folder.path) {
                Store.shared.cfg.originalWallpapers[screen.key] = now.path
            }
        }
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for job in jobs where !fm.fileExists(atPath: job.url.path) {
                if let frame = try? Offscreen(size: job.size).frame(c, job.w, time: 30) { try? Export.write(frame, to: job.url, type: .jpeg) }
            }
            for old in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(old) { try? fm.removeItem(at: folder.appendingPathComponent(old)) }
            DispatchQueue.main.async {
                for job in jobs where fm.fileExists(atPath: job.url.path) && NSWorkspace.shared.desktopImageURL(for: job.screen) != job.url {
                    try? NSWorkspace.shared.setDesktopImageURL(job.url, for: job.screen, options: [:])
                }
            }
        }
    }

    /// Puts back the wallpapers macOS had before matching was turned on.
    static func restore() {
        for screen in NSScreen.screens {
            if let path = Store.shared.cfg.originalWallpapers[screen.key] { try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:]) }
        }
        Store.shared.cfg.originalWallpapers = [:]
    }
}

enum Saver {
    static let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/iLiveWally.saver")
    static let config = installed.appendingPathComponent("Contents/Resources/config.json")
    private static let bundled = Bundle.main.url(forResource: "iLiveWally", withExtension: "saver")

    /// Whether iLiveWally is the screen saver picked in System Settings. This looks for its name in the wallpaper store,
    /// which is not a public format: if macOS changes it, the answer is simply no.
    static var isChosen: Bool {
        let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        return (try? Data(contentsOf: store))?.range(of: Data("iLiveWally.saver".utf8)) != nil
    }

    /// Copies the saver bundled inside the app to ~/Library/Screen Savers.
    static func install() throws {
        let fm = FileManager.default
        guard let bundled else { throw CocoaError(.fileNoSuchFile) }
        try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: installed.path) { try fm.removeItem(at: installed) }
        try fm.copyItem(at: bundled, to: installed)
        Store.shared.save()
    }

    /// A newer app brings a newer saver: replace an installed copy that is out of date.
    static func updateInstalled() {
        let binary = "Contents/MacOS/iLiveWally", fm = FileManager.default
        guard let bundled, fm.fileExists(atPath: installed.path),
              !fm.contentsEqual(atPath: bundled.appendingPathComponent(binary).path, andPath: installed.appendingPathComponent(binary).path) else { return }
        try? install()
    }

    static func openSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")!) }
}
