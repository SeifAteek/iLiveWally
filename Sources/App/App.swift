import Combine
import MetalKit
import SwiftUI

final class Store: ObservableObject {
    static let shared = Store()
    @Published var cfg: Config { didSet { if cfg != oldValue { save() } } }
    @Published var audioError: String?

    private init() { cfg = Config.load(UserDefaults.standard.data(forKey: "config")) }

    /// Saves, and hands the same settings to the installed screen saver (it is sandboxed and can only read its own bundle).
    func save() {
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        UserDefaults.standard.set(data, forKey: "config")
        if FileManager.default.fileExists(atPath: Saver.installed.path) { try? data.write(to: Saver.config) }
    }
}

@main
struct iLiveWallyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = Store.shared

    var body: some Scene {
        MenuBarExtra("iLiveWally", systemImage: "sparkles.tv.fill") {
            ForEach(places(), id: \.key) { place in // one submenu per display, plus screen saver and lock screen
                Picker(place.name, selection: Binding(get: { store.cfg.wallpaper(place.key).id }, set: { store.cfg.places[place.key] = $0 })) {
                    ForEach(wallpapers) { Text($0.name).tag($0.id) }
                }
            }
            Divider()
            Toggle("Pause", isOn: $store.cfg.paused)
            Button("Customize…") { delegate.showSettings() }
            Divider()
            Button("Quit iLiveWally") { NSApp.terminate(nil) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var walls: [NSWindow] = []
    private var settings: NSWindow?
    private let audio = SystemAudio()
    private var audioStarted = false
    private var subs: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ note: Notification) {
        let store = Store.shared
        store.cfg.locked = false
        Saver.updateInstalled()
        Engine.shared.samples = { [audio] in audio.latest(2048) }
        rebuild()
        let nc = NotificationCenter.default, dnc = DistributedNotificationCenter.default()
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild(); SystemWallpaper.sync() }
        nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in self?.apply(store.cfg) }
        // setDesktopImageURL only reaches the Space on screen, so each Space is matched as it comes up.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in SystemWallpaper.sync() }
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.lock() }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in store.cfg.locked = false; SystemWallpaper.sync() }
        store.$cfg.receive(on: RunLoop.main).sink { [weak self] in self?.apply($0) }.store(in: &subs)
        store.$cfg.debounce(for: .seconds(1), scheduler: RunLoop.main).sink { _ in SystemWallpaper.sync() }.store(in: &subs) // not on every slider tick

        // Started by macOS at login: stay in the menu bar. Started by the user: show the settings.
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue != keyAELaunchedAsLogInItem { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    /// One borderless window per screen, between the system wallpaper and the desktop icons.
    private func rebuild() {
        walls.forEach { $0.close() }
        walls = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.backgroundColor = .black
            w.contentView = WallView(frame: CGRect(origin: .zero, size: screen.frame.size), place: screen.key) { Store.shared.cfg }
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            return w
        }
        apply(Store.shared.cfg)
    }

    private func apply(_ c: Config) {
        // Nothing is drawn while paused or while other windows cover the whole desktop.
        for w in walls { (w.contentView as? WallView)?.isPaused = c.paused || !w.occlusionState.contains(.visible) }
        // The audio tap asks for permission, so it only starts once a music-reactive wallpaper is on a display.
        if !audioStarted, NSScreen.screens.contains(where: { c.wallpaper($0.key).reactive }) {
            audioStarted = true
            // Off the main thread: start() blocks for as long as the macOS permission prompt stays open.
            DispatchQueue.global().async { [audio] in
                do {
                    try audio.start()
                    DispatchQueue.main.async { Engine.shared.sampleRate = audio.sampleRate }
                } catch {
                    DispatchQueue.main.async { Store.shared.audioError = error.localizedDescription }
                }
            }
        }
    }

    /// The lock screen is painted by macOS from its own wallpaper and (once idle) the screen saver; both are ours to set.
    private func lock() {
        let store = Store.shared
        store.cfg.locked = true // also saved into the screen saver, which now shows the lock screen's wallpaper
        SystemWallpaper.sync()
        guard store.cfg.saverOnLock, Saver.isChosen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { // not if a quick Touch ID already unlocked it
            if store.cfg.locked { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")) }
        }
    }

    func showSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "iLiveWally"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(Store.shared))
            w.setContentSize(NSSize(width: 980, height: 760))
            w.center()
            settings = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}
