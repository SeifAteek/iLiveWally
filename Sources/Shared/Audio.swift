import Accelerate
import QuartzCore

/// FFT → 256 log-spaced bands, band energies, beat detection, stabilized waveform. (From MacVisualiser.)
final class Analyzer {
    static let bands = 256
    let n = 2048
    private let fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 2048, isHalfWindow: false)
    private var real = [Float](repeating: 0, count: 1024)
    private var imag = [Float](repeating: 0, count: 1024)
    private var mags = [Float](repeating: 0, count: 1024)

    var spectrum = [Float](repeating: 0, count: bands)
    var wave = [Float](repeating: 0, count: bands)
    var bass: Float = 0, mid: Float = 0, treble: Float = 0, level: Float = 0
    var beat: Float = 0

    private var peak: Float = 0.5
    private var wavePeak: Float = 0.1
    private var bassAvg: Float = 0
    private var sinceBeat: Float = 1

    func update(_ samples: [Float], sampleRate: Double, dt: Float, gain: Float) {
        let windowed = vDSP.multiply(samples, window)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, 1024) }
                fft.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &mags, 1, 1024)
            }
        }

        // Log-spaced bands 30 Hz – 16 kHz, in dB with a +3 dB/octave tilt so highs aren't invisible.
        let binHz = Float(sampleRate) / Float(n)
        let lo: Float = 30, hi: Float = 16000
        var raw = [Float](repeating: 0, count: Self.bands)
        var frameMax: Float = 0
        for i in 0..<Self.bands {
            let f0 = lo * pow(hi / lo, Float(i) / Float(Self.bands))
            let f1 = lo * pow(hi / lo, Float(i + 1) / Float(Self.bands))
            let b0 = f0 / binHz, b1 = f1 / binHz
            var m: Float
            if b1 - b0 < 1 {
                let k = min(Int(b0), 1022), t = b0 - Float(k)
                m = mags[k] * (1 - t) + mags[k + 1] * t
            } else {
                m = 0
                for k in Int(b0)...min(Int(b1), 1023) { m = max(m, mags[k]) }
            }
            let db = 20 * log10(m / Float(n) + 1e-9) + 3 * log2(f0 / 1000)
            let v = max(0, (db + 75) / 65)
            raw[i] = v
            frameMax = max(frameMax, v)
        }
        // Slow auto-gain so quiet and loud tracks both fill the screen.
        peak = max(peak * (1 - 0.15 * dt), frameMax, 0.35)
        for i in 0..<Self.bands {
            let v = min(1.5, raw[i] / peak * gain)
            spectrum[i] += (v - spectrum[i]) * (v > spectrum[i] ? 0.7 : 0.25)
        }

        func avg(_ a: Int, _ b: Int, _ src: [Float]) -> Float { src[a..<b].reduce(0, +) / Float(b - a) }
        bass = avg(0, 65, spectrum); mid = avg(65, 171, spectrum); treble = avg(171, 256, spectrum)
        level = (bass + mid + treble) / 3

        // Beat: raw bass energy jumps above its running average.
        let rawBass = avg(0, 50, raw) / peak * gain
        sinceBeat += dt
        if rawBass > bassAvg * 1.2 && rawBass > 0.25 && sinceBeat > 0.25 { beat = 1; sinceBeat = 0 }
        bassAvg += (rawBass - bassAvg) * min(1, dt * 3)
        beat *= exp(-dt * 6)

        // Oscilloscope: start at a rising zero crossing so the wave stands still.
        var start = 0
        for i in 1..<(n - 1024) where samples[i - 1] < 0 && samples[i] >= 0 { start = i; break }
        var wp: Float = 0
        for i in 0..<Self.bands {
            wave[i] = samples[start + i * 4]
            wp = max(wp, abs(wave[i]))
        }
        wavePeak = max(wavePeak * (1 - 0.5 * dt), wp, 0.02)
        for i in 0..<Self.bands { wave[i] = wave[i] / wavePeak * min(gain, 1.5) }
    }
}

/// The one clock and audio analysis that every view on every screen draws from.
final class Engine {
    static let shared = Engine()
    let analyzer = Analyzer()
    var samples: (() -> [Float])?  // the app plugs in the system-audio tap; without it a synthesized beat plays (screen saver)
    var sampleRate: Double = 48000
    private(set) var now = 0.0     // seconds drawn so far; each view advances its own speed-scaled time from this
    private var last = CACurrentMediaTime(), heard = 0.0

    func tick() {
        let t = CACurrentMediaTime(), dt = t - last
        guard dt > 0.004 else { return } // several views share this clock; only the first draw of a frame advances it
        last = t
        now += min(dt, 0.1)
    }

    /// Music-reactive views call this every frame; the analysis still runs once per frame however many ask.
    func listen(gain: Float) {
        guard now > heard else { return }
        analyzer.update(samples?() ?? Engine.synth(at: now, count: analyzer.n), sampleRate: sampleRate, dt: Float(min(now - heard, 0.1)), gain: gain)
        heard = now
    }

    /// A 120 BPM kick, a slow pad and a hi-hat, for places where no audio can be captured (screen saver, Live Photos).
    static func synth(at start: Double, count: Int) -> [Float] {
        (0..<count).map { i in
            let t = start + Double(i) / 48000
            let b = t.truncatingRemainder(dividingBy: 0.5)
            let kick = sin(2 * .pi * 55 * b) * exp(-b * 14)
            let pad = 0.25 * sin(2 * .pi * 220 * t) * (0.5 + 0.5 * sin(t * 0.7)) + 0.15 * sin(2 * .pi * 1760 * t) * (0.5 + 0.5 * sin(t * 1.3))
            let hat = b > 0.25 && b < 0.29 ? Double.random(in: -0.3...0.3) : 0
            return Float(kick + pad + hat)
        }
    }
}
