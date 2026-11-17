import Foundation

struct Param {
    let name: String, range: ClosedRange<Float>, def: Float, step: Float
    init(_ name: String, _ range: ClosedRange<Float>, _ def: Float, step: Float = 0) {
        self.name = name; self.range = range; self.def = def; self.step = step
    }
}

struct Wallpaper: Identifiable {
    let id, name, group, symbol: String
    let params: [Param]                        // ≤ 12, in the order the shader reads them as P(0)…
    let colors: [(name: String, hex: UInt32)]  // ≤ 4, read as C(0)…
    var frag: String { "fs" + id }
    var reactive: Bool { group == groups[0] }
    var all: [Param] { commonParams + params } // a wallpaper's saved values follow this order
}

let groups = ["Music Reactive", "Ambient", "Console Classics"]

/// Sliders every wallpaper has. The last one only shows on music-reactive wallpapers.
let commonParams = [
    Param("Speed", 0...3, 1), Param("Brightness", 0...2, 1), Param("Contrast", 0.5...1.5, 1), Param("Saturation", 0...2, 1),
    Param("Hue Shift", 0...360, 0, step: 1), Param("Vignette", 0...1, 0.25), Param("Film Grain", 0...1, 0),
    Param("Audio Reactivity", 0...3, 1),
]

let wallpapers = [
    Wallpaper(id: "Bars", name: "Equalizer", group: groups[0], symbol: "chart.bar.fill", params: [
        Param("Bars", 8...128, 48, step: 1), Param("Height", 0.1...1.5, 1), Param("Bar Gap", 0...0.9, 0.3),
        Param("Segments", 0...120, 60, step: 1), Param("Mirror", 0...1, 1, step: 1), Param("Baseline", 0...0.8, 0.32),
        Param("Reflection", 0...1, 0.25), Param("Glow", 0...2, 1), Param("Bass Wash", 0...2, 1),
    ], colors: [("Low", 0x00E5FF), ("High", 0xFF2BD6), ("Peaks", 0xFFFFFF), ("Background", 0x05030F)]),

    Wallpaper(id: "Radial", name: "Pulse Ring", group: groups[0], symbol: "circle.dashed", params: [
        Param("Bars", 16...180, 72, step: 1), Param("Radius", 0.1...0.8, 0.32), Param("Bar Length", 0...1.5, 1),
        Param("Bar Gap", 0...0.8, 0.2), Param("Spin", -1...1, 0.05), Param("Waveform", 0...2, 1),
        Param("Core Glow", 0...2, 1), Param("Sparks", 0...2, 1), Param("Beat Punch", 0...3, 1),
    ], colors: [("Inner", 0xFF3D81), ("Outer", 0x7B5CFF), ("Core", 0x39D0FF), ("Background", 0x04020A)]),

    Wallpaper(id: "Synth", name: "Synthwave", group: groups[0], symbol: "sun.horizon.fill", params: [
        Param("Grid Speed", 0...4, 1.5), Param("Grid Density", 0.3...3, 1), Param("Horizon", -0.6...0.4, -0.15),
        Param("Sun Size", 0.1...1, 0.48), Param("Sun Stripes", 0...20, 10, step: 1), Param("Mountains", 0...2, 1),
        Param("Glow", 0...2, 1), Param("Stars", 0...2, 1), Param("Beat Pulse", 0...3, 1),
    ], colors: [("Sun Top", 0xFFD319), ("Sun Bottom", 0xFF2975), ("Grid", 0xF222FF), ("Sky", 0x2B0F54)]),

    Wallpaper(id: "Aurora", name: "Aurora", group: groups[1], symbol: "sparkles", params: [
        Param("Bands", 1...8, 5, step: 1), Param("Height", 0.2...2, 1), Param("Wave", 0...2, 1), Param("Rays", 0...1, 1),
        Param("Falloff", 1...8, 3.5), Param("Stars", 0...2, 1), Param("Star Density", 10...120, 60),
        Param("Position", -0.6...0.6, 0), Param("Intensity", 0...3, 1),
    ], colors: [("Low", 0x1AFFA0), ("Middle", 0x18B4FF), ("High", 0xB44CFF), ("Sky", 0x020818)]),

    Wallpaper(id: "Liquid", name: "Liquid Gradient", group: groups[1], symbol: "drop.fill", params: [
        Param("Scale", 0.3...3, 1), Param("Warp", 0...3, 1), Param("Softness", 0.2...2, 0.7), Param("Blob Travel", 0...1.5, 0.8),
        Param("Sheen", 0...1, 0.2), Param("Sheen Scale", 0.5...6, 2),
    ], colors: [("Color 1", 0xFF5F6D), ("Color 2", 0xFFC371), ("Color 3", 0x6A5BFF), ("Color 4", 0x21D4FD)]),

    Wallpaper(id: "Hyper", name: "Hyperspace", group: groups[1], symbol: "moon.stars.fill", params: [
        Param("Layers", 2...10, 6, step: 1), Param("Star Size", 0.2...3, 1), Param("Density", 0.3...3, 1),
        Param("Warp Streaks", 0...2, 0.25), Param("Twinkle", 0...2, 1), Param("Spin", -1...1, 0.25),
        Param("Core Glow", 0...2, 1), Param("Nebula", 0...2, 0.5),
    ], colors: [("Stars", 0xFFFFFF), ("Star Tint", 0x8FB8FF), ("Core", 0x4D6BFF), ("Background", 0x000004)]),

    Wallpaper(id: "Rain", name: "Digital Rain", group: groups[1], symbol: "terminal.fill", params: [
        Param("Columns", 20...200, 80, step: 1), Param("Speed Variation", 0...1, 0.8), Param("Trail Length", 0.1...1.5, 0.6),
        Param("Glyph Flicker", 0...3, 1), Param("Glow", 0...3, 1), Param("Head Brightness", 0...2, 1),
        Param("Rain Density", 0.1...1, 0.9),
    ], colors: [("Glyphs", 0x00FF66), ("Heads", 0xD8FFE4), ("Background", 0x000A03)]),

    Wallpaper(id: "Flow", name: "Cosmic Flow", group: groups[1], symbol: "hurricane", params: [
        Param("Scale", 0.3...4, 1.4), Param("Warp", 0...6, 3.5), Param("Density", 0.5...4, 2), Param("Highlights", 0...3, 1),
        Param("Stars", 0...2, 1), Param("Drift X", -1...1, 0.2), Param("Drift Y", -1...1, 0),
    ], colors: [("Deep", 0x1B1464), ("Mid", 0xC2185B), ("Highlight", 0xFFB347), ("Background", 0x05010D)]),

    Wallpaper(id: "Wave3", name: "PS3-Style Wave", group: groups[2], symbol: "water.waves", params: [
        Param("Wave Height", 0...1, 0.35), Param("Ribbon Width", 0.02...0.6, 0.22), Param("Ribbons", 1...6, 3, step: 1),
        Param("Position", -0.7...0.7, -0.15), Param("Wave Opacity", 0...1.5, 0.5), Param("Strand Lines", 0...60, 0, step: 1),
        Param("Sparkles", 0...3, 1), Param("Sparkle Size", 0.3...3, 1), Param("Gradient Angle", 0...360, 35, step: 1),
        Param("Wave Stretch", 0.3...3, 1),
    ], colors: [("Background Dark", 0x06122B), ("Background Light", 0x2C6FD6), ("Wave", 0xBFDFFF), ("Sparkles", 0xFFFFFF)]),

    Wallpaper(id: "Flow4", name: "PS4-Style Flow", group: groups[2], symbol: "wind", params: [
        Param("Lines", 4...48, 24, step: 1), Param("Spread", 0...1, 0.35), Param("Amplitude", 0...1, 0.3),
        Param("Frequency", 0.3...4, 1.2), Param("Thickness", 0.3...4, 1), Param("Glow", 0...3, 1), Param("Twist", 0...3, 1),
        Param("Position", -0.7...0.7, 0), Param("Backlight", 0...2, 1), Param("Dust", 0...3, 0.6),
    ], colors: [("Background Top", 0x0A3D91), ("Background Bottom", 0x00143C), ("Lines", 0x4FA8FF), ("Highlight", 0xBFE3FF)]),

    Wallpaper(id: "Drift5", name: "PS5-Style Particles", group: groups[2], symbol: "gamecontroller.fill", params: [
        Param("Density", 0.3...3, 1), Param("Particle Size", 0.3...3, 1), Param("Layers", 2...10, 6, step: 1),
        Param("Direction", 0...360, 60, step: 1), Param("Wander", 0...2, 1), Param("Twinkle", 0...1, 0.7),
        Param("Bokeh", 0...2, 1), Param("Ambient Glow", 0...3, 1), Param("Glow Drift", 0...4, 1),
    ], colors: [("Particles", 0xFFD9A0), ("Accent", 0xFFFFFF), ("Glow", 0x1E3A8A), ("Background", 0x02040A)]),
]

/// Everything the user can change. The app saves it to UserDefaults and copies it into the installed screen saver.
struct Config: Codable, Equatable {
    var selected = "Drift5"                 // the wallpaper of every place that has no choice of its own
    var places: [String: String] = [:]      // a display's UUID, "saver" or "lock" → wallpaper id
    var values: [String: [Float]] = [:]     // wallpaper id → slider values; missing = defaults
    var colors: [String: [[Float]]] = [:]   // wallpaper id → rgb triples; missing = defaults
    var fps = 60
    var renderScale: Float = 1
    var gain: Float = 1
    var paused = false
    var pauseUnfocused = false              // draw only while the desktop (Finder) is in front
    var matchSystem = true                  // keep the macOS wallpaper a still of the live one
    var saverOnLock = true                  // start the screen saver the moment the Mac locks
    var locked = false                      // set by the app while the screen is locked: the saver then shows the "lock" wallpaper
    var originalWallpapers: [String: String] = [:] // display UUID → the macOS wallpaper from before matchSystem took over

    func wallpaper(_ place: String) -> Wallpaper {
        let id = places[place] ?? selected
        return wallpapers.first { $0.id == id } ?? wallpapers[0]
    }

    /// Reads saved settings, keeping the defaults for anything a newer version added.
    static func load(_ data: Data?) -> Config {
        guard let data, let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var all = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any] else { return Config() }
        all.merge(saved) { $1 }
        return (try? JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: all))) ?? Config()
    }

    // A saved list of the wrong length comes from an older version of that wallpaper: fall back to defaults.
    func values(_ w: Wallpaper) -> [Float] {
        if let v = values[w.id], v.count == w.all.count { return v }
        return w.all.map(\.def)
    }

    func colors(_ w: Wallpaper) -> [[Float]] {
        if let c = colors[w.id], c.count == w.colors.count, c.allSatisfy({ $0.count == 3 }) { return c }
        return w.colors.map { [Float($0.hex >> 16 & 255) / 255, Float($0.hex >> 8 & 255) / 255, Float($0.hex & 255) / 255] }
    }
}
