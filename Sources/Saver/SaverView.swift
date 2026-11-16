import ScreenSaver

/// The screen saver: the same Metal view as the desktop wallpaper, with the settings the app copied into this bundle.
@objc(ILWSaverView)
final class SaverView: ScreenSaverView {
    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        let cfg = Config.load(Bundle(for: SaverView.self).url(forResource: "config", withExtension: "json").flatMap { try? Data(contentsOf: $0) })
        // While the Mac is locked the saver is the lock screen's moving wallpaper, so it shows the lock screen's choice.
        let view = WallView(frame: bounds, place: cfg.locked ? "lock" : "saver") { cfg }
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        // Since macOS 14 the host keeps a dismissed saver alive and drawing; leaving is the only way to stop.
        if !isPreview {
            DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screensaver.willstop"), object: nil, queue: .main) { _ in exit(0) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}
