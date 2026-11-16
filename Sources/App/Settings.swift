import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var place = NSScreen.main?.key ?? "saver" // the display, screen saver or lock screen being set up
    @State private var engine = false

    var body: some View {
        // Picking a wallpaper in the sidebar puts it on the current place at once; "_engine" is the app-wide page.
        let selection = Binding<String?>(get: { engine ? "_engine" : store.cfg.wallpaper(place).id }, set: {
            guard let id = $0 else { return }
            engine = id == "_engine"
            if !engine { store.cfg.places[place] = id }
        })
        NavigationSplitView {
            List(selection: selection) {
                ForEach(groups, id: \.self) { g in
                    Section(g) {
                        ForEach(wallpapers.filter { $0.group == g }) { w in Label(w.name, systemImage: w.symbol).tag(w.id) }
                    }
                }
                Section("App") { Label("Engine, Saver & Lock", systemImage: "gearshape.fill").tag("_engine") }
            }
            .navigationSplitViewColumnWidth(230)
        } detail: {
            if engine { EngineView() } else { WallpaperView(w: store.cfg.wallpaper(place), place: $place).id(place + store.cfg.wallpaper(place).id) }
        }
    }
}

/// Where the wallpaper shows, a live preview, and every option of it: colors, its own sliders and the shared "Look" sliders.
struct WallpaperView: View {
    @EnvironmentObject var store: Store
    let w: Wallpaper
    @Binding var place: String
    @State private var exporting = false
    @State private var exported: [URL] = []
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show on", selection: $place) {
                ForEach(places(), id: \.key) { Text($0.name).tag($0.key) }
            }.pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top])
            Preview(place: place).aspectRatio(16 / 9, contentMode: .fit).frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14)).padding([.horizontal, .top])
            Form {
                if w.reactive {
                    Section {
                        Text(store.audioError.map { "No system audio: \($0). Allow iLiveWally under System Settings › Privacy & Security › Screen & System Audio Recording." }
                             ?? "Moves with whatever your Mac is playing. As a screen saver and in Live Photos it plays to a built-in beat.")
                            .foregroundStyle(store.audioError == nil ? Color.secondary : Color.red)
                    }
                }
                Section("Colors") {
                    ForEach(Array(w.colors.enumerated()), id: \.offset) { i, c in
                        ColorPicker(c.name, selection: color(i), supportsOpacity: false)
                    }
                }
                Section(w.name) { ForEach(w.params.indices, id: \.self) { row($0 + commonParams.count) } }
                Section("Look") { ForEach(0..<(w.reactive ? commonParams.count : commonParams.count - 1), id: \.self) { row($0) } }
                Section("Match Your Devices") {
                    HStack {
                        ForEach(Export.devices, id: \.name) { d in Button("Live Photo for \(d.name)") { export(d) } }
                        if exporting { ProgressView().controlSize(.small) }
                    }.disabled(exporting)
                    if !status.isEmpty {
                        HStack {
                            Text(status)
                            if !exported.isEmpty {
                                Spacer()
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(exported) }
                                Button("Add to Photos") { Export.addToPhotos(exported) { s in DispatchQueue.main.async { status = s } } }
                            }
                        }
                    }
                    Text("Makes a 3-second Live Photo of this wallpaper with the settings above. Add it to Photos (iCloud Photos carries it to your iPhone and Watch) or AirDrop both files together, then set it as the iPhone wallpaper or choose it for a Photos watch face.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Use \(w.name) Everywhere") { store.cfg.selected = w.id; store.cfg.places = [:] }
                    Button("Reset \(w.name) to Defaults") { store.cfg.values[w.id] = nil; store.cfg.colors[w.id] = nil }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func export(_ device: (name: String, size: CGSize)) {
        exporting = true; exported = []; status = "Rendering…"
        let c = store.cfg, w = w
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Export.livePhoto(c, w, size: device.size, to: Export.folder.appendingPathComponent("\(w.name) \(device.name)")) }
            DispatchQueue.main.async {
                exporting = false
                switch result {
                case .success(let files): exported = files; status = "Saved to Pictures › iLiveWally."
                case .failure(let error): status = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder private func row(_ i: Int) -> some View {
        let p = w.all[i]
        let value = Binding<Float>(get: { store.cfg.values(w)[i] }, set: {
            var v = store.cfg.values(w)
            v[i] = p.step > 0 ? ($0 / p.step).rounded() * p.step : $0 // rounded here: a stepped Slider would draw a tick per step
            store.cfg.values[w.id] = v
        })
        if p.step == 1 && p.range == 0...1 {
            Toggle(p.name, isOn: Binding(get: { value.wrappedValue > 0.5 }, set: { value.wrappedValue = $0 ? 1 : 0 }))
        } else {
            SliderRow(name: p.name, value: value, range: p.range, whole: p.step >= 1)
        }
    }

    private func color(_ i: Int) -> Binding<Color> {
        Binding(get: {
            let c = store.cfg.colors(w)[i]
            return Color(.sRGB, red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
        }, set: {
            guard let n = NSColor($0).usingColorSpace(.sRGB) else { return }
            var all = store.cfg.colors(w)
            all[i] = [Float(n.redComponent), Float(n.greenComponent), Float(n.blueComponent)]
            store.cfg.colors[w.id] = all
        })
    }
}

struct SliderRow: View {
    let name: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var whole = false

    var body: some View {
        LabeledContent(name) {
            Slider(value: $value, in: range).frame(minWidth: 220)
            Text(whole ? String(Int(value)) : String(format: "%.2f", value)).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}

struct Preview: NSViewRepresentable {
    let place: String
    func makeNSView(context: Context) -> WallView { WallView(frame: .zero, place: place) { Store.shared.cfg } }
    func updateNSView(_ view: WallView, context: Context) {}
}

/// App-wide settings: performance, music input, the macOS wallpaper and lock screen, the screen saver.
struct EngineView: View {
    @EnvironmentObject var store: Store
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var saverChosen = Saver.isChosen
    @State private var status = ""

    var body: some View {
        Form {
            Section("Performance") {
                Picker("Frame Rate", selection: $store.cfg.fps) {
                    ForEach([24, 30, 60, 120], id: \.self) { Text("\($0) fps").tag($0) }
                }
                SliderRow(name: "Render Scale", value: $store.cfg.renderScale, range: 0.25...1)
                Toggle("Pause Wallpaper", isOn: $store.cfg.paused)
                Toggle("Launch at Login", isOn: Binding(get: { login }, set: { on in
                    do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister(); login = on }
                    catch { status = error.localizedDescription }
                }))
                note("Drawing stops by itself whenever windows cover the whole desktop.")
            }
            Section("Music") {
                SliderRow(name: "Input Gain", value: $store.cfg.gain, range: 0.2...3)
                if let e = store.audioError { Text(e).foregroundStyle(.red) }
            }
            Section("Menu Bar & Lock Screen") {
                Toggle("Match the macOS Wallpaper", isOn: Binding(get: { store.cfg.matchSystem }, set: { on in
                    store.cfg.matchSystem = on
                    if on { SystemWallpaper.sync() } else { SystemWallpaper.restore() }
                }))
                note("macOS tints the menu bar and paints the lock screen from its own wallpaper, which sits hidden under the live one. With this on, that wallpaper is kept as a still of the live one: the menu bar matches, and the lock screen shows your Lock Screen choice behind the clock and password field. Turning it off puts your old wallpaper back.")
                Toggle("Start the Screen Saver When the Mac Locks", isOn: $store.cfg.saverOnLock)
                note("macOS lets nothing draw between its lock-screen wallpaper and the clock, so the moving lock screen is the screen saver, which macOS itself shows behind the clock. It needs iLiveWally as your screen saver; press a key and the password field appears over the still.")
            }
            Section("Screen Saver") {
                LabeledContent(saverChosen ? "iLiveWally is your screen saver." : "iLiveWally is not your screen saver yet.") {
                    Button("Install & Choose…") {
                        do { try Saver.install(); Saver.openSettings(); status = "Installed. Pick iLiveWally in System Settings › Screen Saver." }
                        catch { status = error.localizedDescription }
                    }
                }
                note("Shows your Screen Saver choice while the Mac is idle, and your Lock Screen choice while it is locked. macOS does not let a screen saver hear system audio, so music-reactive wallpapers play to a built-in beat there.")
            }
            if !status.isEmpty { Text(status) }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in saverChosen = Saver.isChosen }
    }

    private func note(_ text: String) -> some View { Text(text).font(.footnote).foregroundStyle(.secondary) }
}
