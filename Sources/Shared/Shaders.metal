#include <metal_stdlib>
using namespace metal;

// Mirrors the 12 × float4 block packed in WallView.encode (all float4, so layouts agree).
struct U {
    float4 a;      // width, height, time (speed-scaled), real time
    float4 audio;  // bass, mid, treble, level (reactivity-scaled)
    float4 b;      // beat
    float4 g[2];   // brightness, contrast, saturation, hue | vignette, grain
    float4 p[3];   // 12 wallpaper sliders, in the order Wallpapers.swift lists them
    float4 c[4];   // 4 colors
};

struct VOut { float4 pos [[position]]; float2 uv; };

#define ARGS VOut in [[stage_in]], constant U& u [[buffer(0)]], constant float* sp [[buffer(1)]], constant float* wv [[buffer(2)]]
#define T u.a.z
#define RT u.a.w
#define BASS u.audio.x
#define MID u.audio.y
#define TREBLE u.audio.z
#define LEVEL u.audio.w
#define BEAT u.b.x
#define P(i) u.p[(i) / 4][(i) % 4]
#define C(i) u.c[i].rgb
#define SPEC(x) lookup(sp, x)
#define WAVE(x) lookup(wv, x)
#define TAU 6.2831853

vertex VOut vsQuad(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2 - 1, 0, 1);
    o.uv = p; // y up
    return o;
}

// Centered coordinates: y in -1…1, x scaled by the aspect ratio.
float2 pos(VOut in, constant U& u) { return (in.uv - 0.5) * 2 * float2(u.a.x / u.a.y, 1); }

float lookup(constant float* a, float x) {
    float f = saturate(x) * 255;
    int i = int(f);
    return mix(a[i], a[min(i + 1, 255)], f - i);
}

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3 - 2 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
}

float fbm(float2 p) {
    float v = 0, a = 0.5;
    for (int i = 0; i < 5; i++) { v += a * noise(p); p = float2x2(1.6, 1.2, -1.2, 1.6) * p; a *= 0.5; }
    return v;
}

float2x2 rot(float a) { float c = cos(a), s = sin(a); return float2x2(c, s, -s, c); }

float3 hueRotate(float3 c, float a) {
    const float3 k = float3(0.57735);
    float ca = cos(a);
    return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1 - ca);
}

float3 grad3(float3 a, float3 b, float3 c, float t) {
    t = saturate(t) * 2;
    return t < 1 ? mix(a, b, t) : mix(b, c, t - 1);
}

// ACES fit: stacked glows roll off to white instead of clipping.
float3 tone(float3 c) { return (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14); }

float stars(float2 p, float density, float bright) {
    float2 g = p * density;
    return step(0.985, hash21(floor(g))) * (1 - smoothstep(0.0, 0.25, length(fract(g) - 0.5))) * bright;
}

// One twinkling dot per grid cell; `radius` must stay below 0.15 to fit its cell.
float sparkle(float2 g, float seed, float radius, float rt) {
    float2 id = floor(g), gv = fract(g) - 0.5;
    float h = hash21(id + seed);
    float2 off = (float2(fract(h * 34.1), fract(h * 91.7)) - 0.5) * 0.7;
    float tw = 0.5 + 0.5 * sin(rt * (1 + h * 4) + h * 60);
    return step(0.6, h) * tw * (1 - smoothstep(0.0, radius, length(gv - off)));
}

// The "Look" sliders every wallpaper shares.
float4 finish(float3 col, VOut in, constant U& u) {
    col = hueRotate(max(col, 0.0), u.g[0].w);
    col = mix(float3(dot(col, float3(0.2126, 0.7152, 0.0722))), col, u.g[0].z);
    col = ((col - 0.5) * u.g[0].y + 0.5) * u.g[0].x;
    col *= 1 - u.g[1].x * smoothstep(0.35, 1.0, length(in.uv - 0.5) * 1.4);
    float n = hash21(in.pos.xy + fract(RT) * 100) - 0.5;
    col += n * (u.g[1].y * 0.15 + 1.0 / 255); // grain, plus one bit of dither so gradients don't band
    return float4(saturate(col), 1);
}

// ───────────────────────────── music reactive ─────────────────────────────

// P: 0 bars, 1 height, 2 gap, 3 segments, 4 mirror, 5 baseline, 6 reflection, 7 glow, 8 bass wash
fragment float4 fsBars(ARGS) {
    float2 uv = in.uv;
    float nb = floor(P(0));
    bool mirror = P(4) > 0.5;
    float x = mirror ? abs(uv.x * 2 - 1) : uv.x;
    float id = min(floor(x * nb), nb - 1), cell = fract(x * nb);
    float s = max(SPEC(id / nb), 0.03 + 0.02 * sin(id * 0.6 + RT * 1.5)); // idle ripple when nothing plays
    float h = s * 0.62 * P(1);
    float y = uv.y - P(5);
    float aa = nb / u.a.x * (mirror ? 3.0 : 1.5), g = P(2) * 0.5;
    float gap = smoothstep(g - aa, g + aa, cell) * (1 - smoothstep(1 - g - aa, 1 - g + aa, cell));
    float seg = P(3) < 1 ? 1.0 : smoothstep(0.15, 0.3, fract(y * P(3)));
    float3 c = mix(C(0), C(1), id / nb);
    float3 col = C(3);
    col += y > 0 ? c * step(y, h) * gap * seg * (0.6 + s)
                 : c * step(-y, h * 0.5) * gap * P(6) * (1 - smoothstep(0.0, h * 0.5, -y));
    col += C(2) * 0.004 / (abs(y - h) + 0.004) * gap * s * P(7);
    col += c * 0.002 / (abs(y) + 0.002) * (0.3 + BASS) * P(7);
    col += C(2) * (0.1 * (1 - uv.y) * BASS + 0.05 * BEAT) * P(8);
    return finish(tone(col), in, u);
}

// P: 0 bars, 1 radius, 2 length, 3 gap, 4 spin, 5 waveform, 6 core glow, 7 sparks, 8 beat punch
fragment float4 fsRadial(ARGS) {
    float2 p = rot(T * P(4)) * pos(in, u);
    float r = length(p), ang = atan2(p.x, p.y) / TAU + 0.5;
    float x = abs(ang * 2 - 1);
    float nb = floor(P(0));
    float id = floor(x * nb) / nb, cell = fract(x * nb);
    float s = max(SPEC(id), 0.03 + 0.02 * sin(id * 40 + RT * 1.5));
    float base = P(1) + (BASS * 0.06 + BEAT * 0.03) * P(8);
    float top = base + 0.03 + s * 0.55 * P(2);
    float g = P(3) * 0.5;
    float gap = smoothstep(g, g + 0.1, cell) * (1 - smoothstep(0.9 - g, 1 - g, cell));
    float bar = smoothstep(base, base + 0.005, r) * (1 - smoothstep(top, top + 0.005, r)) * gap;
    float3 col = C(3);
    col += mix(C(0), C(1), saturate((r - base) / (0.58 * P(2) + 0.001))) * bar * (0.6 + s * 1.5);
    col += C(1) * 0.006 / (abs(r - top) + 0.002) * s * gap;
    float wr = base - 0.06 + WAVE(x) * 0.05 * P(5);
    col += C(0) * 0.003 / (abs(r - wr) + 0.001) * (0.4 + LEVEL) * min(P(5), 1.0);
    col += C(2) * (1 - smoothstep(base - 0.25, base - 0.1, r)) * (0.1 + BEAT * 0.6 + BASS * 0.3) * P(6);
    float2 gp = float2(ang * 60, r * 6 - T * 1.5);
    float h = hash21(floor(gp));
    col += step(0.93, h) * (1 - smoothstep(0.0, 0.12, length(fract(gp) - 0.5))) * mix(C(0), C(1), h)
         * (0.3 + TREBLE * 2) * smoothstep(base, base + 0.3, r) * P(7);
    return finish(tone(col), in, u);
}

// P: 0 grid speed, 1 grid density, 2 horizon, 3 sun size, 4 sun stripes, 5 mountains, 6 glow, 7 stars, 8 beat pulse
fragment float4 fsSynth(ARGS) {
    float2 p = pos(in, u);
    float hz = P(2);
    float dz = max(hz - p.y, 0.001), z = 0.25 / dz;
    float2 gp = float2(p.x * z, z + T * P(0)) * P(1);
    float2 fw = fwidth(gp); // outside the branch: derivatives need uniform control flow
    float3 col;
    if (p.y > hz) {
        col = mix(C(3), C(3) * 0.08, saturate((p.y - hz) * 1.2));
        col += stars(p, 50, 0.7) * P(7) * smoothstep(hz, hz + 0.5, p.y);
        float2 sc = float2(0, hz + 0.43);
        float sr = P(3) + (BASS * 0.05 + BEAT * 0.03) * P(8);
        float d = length(p - sc), sy = (p.y - sc.y) / sr;
        float visible = (sy > 0 || P(4) < 0.5) ? 1.0 : step(saturate(-sy) * 0.6, fract(sy * P(4) + T * 0.4));
        col = mix(col, mix(C(1), C(0), sy * 0.5 + 0.5) * 1.6, (1 - smoothstep(sr - 0.005, sr, d)) * visible);
        col += C(1) * 0.03 / (abs(d - sr) + 0.03) * (0.3 + BASS * 0.8) * P(6);
        float m = hz + 0.05 + (SPEC(saturate(abs(p.x) * 0.5)) * 0.35 * smoothstep(0.0, 0.6, abs(p.x)) + noise(float2(p.x * 6, 0)) * 0.08) * P(5);
        if (p.y < m) col = C(3) * 0.1;
        col += C(2) * 0.002 / (abs(p.y - m) + 0.002) * 0.6 * P(6);
    } else {
        float2 dl = 0.5 - abs(fract(gp) - 0.5);
        float lx = 1 - smoothstep(0.0, fw.x * 1.5, dl.x), lz = 1 - smoothstep(0.0, fw.y * 1.5, dl.y);
        col = C(2) * max(lx, lz) * exp(-z * 0.08) * (0.6 + BASS * 1.5 * P(8)) + C(3) * 0.6 * exp(-dz * 6);
    }
    return finish(tone(col), in, u);
}

// ───────────────────────────── ambient ─────────────────────────────

// P: 0 bands, 1 height, 2 wave, 3 rays, 4 falloff, 5 stars, 6 star density, 7 position, 8 intensity
fragment float4 fsAurora(ARGS) {
    float2 p = pos(in, u);
    float3 col = C(3) * (1.2 - in.uv.y);
    col += stars(p, P(6), 0.6 * (0.6 + 0.4 * sin(RT * 2 + p.x * 40 + p.y * 23))) * P(5);
    int n = int(P(0));
    for (int i = 0; i < n; i++) {
        float fi = i;
        // Plain noise, not fbm, per band: fbm here cost 18 ms a frame at Retina size.
        float2 a = float2(p.x * 0.8 + T * 0.05 * (1 + fi * 0.3), fi * 3.1 + T * 0.02);
        float yc = P(7) - 0.15 + fi * 0.12 + (noise(a) * 0.65 + noise(a * 2.3 + 7) * 0.35 - 0.5) * 0.8 * P(2);
        float dy = (p.y - yc) / P(1);
        float rays = mix(1.0, 0.4 + 0.6 * noise(float2(p.x * 30 + fi * 10, T * 0.4 + fi)), P(3));
        float band = smoothstep(-0.2, 0.0, dy) * exp(-max(dy, 0.0) * P(4))
                   * smoothstep(0.3, 0.7, noise(float2(p.x * 1.2 + fi * 7 - T * 0.03, fi + T * 0.01))); // curtains come in patches
        col += grad3(C(0), C(1), C(2), fi / max(n - 1, 1) + 0.15 * sin(p.x * 0.7 + T * 0.05 + fi)) * band * rays * 0.9 * P(8);
    }
    return finish(col, in, u);
}

// P: 0 scale, 1 warp, 2 softness, 3 blob travel, 4 sheen, 5 sheen scale
fragment float4 fsLiquid(ARGS) {
    float2 p = pos(in, u) * P(0);
    for (int i = 1; i < 4; i++) // a few rounds of swirl: smoother than noise, so the gradient stays clean
        p += P(1) * 0.35 / i * float2(sin(p.y * 1.3 * i + T * 0.21 + i * 1.7), cos(p.x * 1.1 * i - T * 0.17 + i * 2.3));
    float3 col = 0;
    float wsum = 0;
    for (int i = 0; i < 4; i++) { // each color is a soft blob; the pixel is their weighted blend
        float fi = i;
        float2 c = P(3) * float2(1.2 * sin(T * (0.21 + fi * 0.05) + fi * 1.7), 0.8 * cos(T * (0.17 + fi * 0.04) + fi * 2.3));
        float w = exp(-dot(p - c, p - c) / (P(2) * P(2))) + 1e-4;
        col += C(i) * w;
        wsum += w;
    }
    col /= wsum;
    col += P(4) * 0.3 * pow(0.5 + 0.5 * sin(dot(p, float2(0.8, 0.6)) * P(5) * 2 + T * 0.2), 4.0); // silky highlight bands that follow the swirl
    return finish(col, in, u);
}

// P: 0 layers, 1 star size, 2 density, 3 streaks, 4 twinkle, 5 spin, 6 core glow, 7 nebula
fragment float4 fsHyper(ARGS) {
    float2 p = rot(T * P(5) * 0.2) * pos(in, u);
    float r = length(p), a = abs(atan2(p.y, p.x)); // abs: no seam where the angle wraps
    float3 col = C(3);
    col += mix(C(1), C(2), fbm(p * 1.5 + T * 0.02)) * pow(fbm(p * 2 - T * 0.03), 3.0) * P(7) * 0.8;
    int n = int(P(0));
    for (int i = 0; i < n; i++) {
        float depth = fract(float(i) / n + T * 0.4);
        float fade = depth * (1 - smoothstep(0.85, 1.0, depth));
        float2 q = rot(i * 1.7) * p * mix(18.0, 0.6, depth) * P(2) + i * 31.7;
        float2 gv = fract(q) - 0.5;
        float h = hash21(floor(q));
        float d = length(gv - (float2(h, fract(h * 34.1)) - 0.5) * 0.7);
        float tw = 1 + P(4) * 0.5 * sin(RT * (2 + h * 6) + h * 100);
        col += mix(C(0), C(1), fract(h * 7.3)) * 0.01 * P(1) * tw / d * (1 - smoothstep(0.05, 0.35, d)) * fade * fade;
    }
    col += C(0) * pow(noise(float2(a * 30, r * 2 - T * 4)), 6.0) * smoothstep(0.1, 1.2, r) * P(3) * 2;
    col += C(2) * 0.03 / (r + 0.03) * P(6);
    return finish(tone(col), in, u);
}

// P: 0 columns, 1 speed variation, 2 trail, 3 flicker, 4 glow, 5 head, 6 density
fragment float4 fsRain(ARGS) {
    float cols = floor(P(0)), rows = max(floor(cols * u.a.y / u.a.x / 1.4), 1.0);
    float2 g = float2(in.uv.x * cols, (1 - in.uv.y) * rows); // row 0 at the top
    float2 id = floor(g), gp = floor(fract(g) * float2(5, 7));
    // Glyph: a 3×5 block of random bits inside a 5×7 cell, reshuffled now and then.
    float tick = floor(RT * 4 * P(3) * (0.3 + hash21(id + 3.3)) + hash21(id) * 10);
    float bit = step(0.5, hash21(id * 17.31 + gp * 3.7 + tick * 1.13))
              * step(1.0, gp.x) * step(gp.x, 3.0) * step(1.0, gp.y) * step(gp.y, 5.0);
    float3 col = C(2);
    for (int k = 0; k < 2; k++) { // two drops share each column
        float h = hash21(float2(id.x, 7.0 + k * 3.1));
        float head = fract(T * 0.25 * mix(1.0, 0.4 + 1.2 * h, P(1)) / (1.5 + h) + h * 7.0) * rows * (1.5 + h);
        float dist = head - id.y; // rows behind the head
        float trail = dist >= 0 ? exp(-dist / (rows * 0.5 * P(2))) : 0.0;
        float lead = 1 - smoothstep(0.0, 1.5, abs(dist));
        float on = step(hash21(float2(id.x, 91.0 + k)), P(6));
        col += on * (C(0) * (bit * trail + trail * 0.12 * P(4)) + C(1) * bit * lead * P(5));
    }
    return finish(col, in, u);
}

// P: 0 scale, 1 warp, 2 density, 3 highlights, 4 stars, 5 drift x, 6 drift y
fragment float4 fsFlow(ARGS) {
    float2 p = pos(in, u);
    float t = T * 0.08;
    float2 q = p * P(0) + float2(P(5), P(6)) * T * 0.1;
    float2 w = float2(fbm(q + float2(0, t)), fbm(q + float2(5.2, 1.3) - t));
    float2 r = float2(fbm(q + P(1) * w + float2(1.7, 9.2) + t * 1.5), fbm(q + P(1) * w + float2(8.3, 2.8) - t * 1.2));
    float f = fbm(q + P(1) * r);
    float3 col = C(3) + grad3(C(0), C(1), C(2), smoothstep(0.3, 0.8, f) + (length(r) - 0.7) * 0.5) * pow(f * 1.3, P(2)) * 1.6;
    col += C(2) * pow(saturate(f * 1.25), 8.0) * P(3);
    col += stars(p, 40, 0.5 + 0.3 * sin(RT * 3 + p.x * 50)) * P(4);
    return finish(tone(col), in, u);
}

// ───────────────────────────── console classics ─────────────────────────────

// A silk ribbon between two wandering edges; it thins and brightens where they cross.
float ribbon(float2 p, float t, float s, float amp, float width, float strands, float px) {
    float a = sin(p.x * 0.9 + t * 0.6 + s) * 0.5 + sin(p.x * 1.7 - t * 0.4 + s * 2.1) * 0.25 + sin(p.x * 3.1 + t * 0.9 + s * 0.7) * 0.08;
    float b = sin(p.x * 0.7 - t * 0.5 + s * 1.3 + 1.0) * 0.5 + sin(p.x * 1.9 + t * 0.3 + s) * 0.25;
    float top = a * amp + width * (0.6 + 0.4 * sin(p.x * 0.5 + t * 0.2 + s));
    float bot = b * amp - width * (0.6 + 0.4 * cos(p.x * 0.4 - t * 0.15 + s));
    float lo = min(top, bot), hi = max(top, bot), span = max(hi - lo, 1e-3);
    float v = (p.y - lo) / span;
    float inside = smoothstep(lo - px, lo + px, p.y) * (1 - smoothstep(hi - px, hi + px, p.y));
    float shade = 0.25 + 0.75 * pow(abs(v * 2 - 1), 2.5);
    return inside * shade * (1 + 0.25 * sin(v * strands * TAU)) * (0.4 + 0.6 * smoothstep(0.0, 0.08, span));
}

// PS3-style: P: 0 wave height, 1 ribbon width, 2 ribbons, 3 position, 4 opacity, 5 strand lines, 6 sparkles, 7 sparkle size, 8 gradient angle, 9 stretch
fragment float4 fsWave3(ARGS) {
    float2 p = pos(in, u);
    float ang = P(8) * TAU / 360;
    float3 col = mix(C(0), C(1), smoothstep(0.0, 1.0, dot(in.uv - 0.5, float2(cos(ang), sin(ang))) + 0.5));
    float2 q = float2(p.x * P(9), p.y - P(3));
    int n = int(P(2));
    for (int i = 0; i < n; i++) {
        float fi = i;
        col += C(2) * ribbon(float2(q.x, q.y + fi * 0.03), T * (1 + fi * 0.13), fi * 1.9, P(0), P(1) * (1 - fi * 0.12), P(5), 2 / u.a.y)
             * P(4) / (1 + fi * 0.5);
    }
    float spk = 0;
    for (int i = 0; i < 3; i++) {
        float fi = i;
        spk += sparkle(p * (10 + fi * 7) + float2(T * (0.3 + fi * 0.1), T * 0.12 + fi * 5), fi * 17, 0.05 * P(7), RT);
    }
    col += C(3) * spk * exp(-abs(q.y) * 2.5) * P(6); // sparkles gather around the wave
    return finish(col, in, u);
}

// PS4-style: P: 0 lines, 1 spread, 2 amplitude, 3 frequency, 4 thickness, 5 glow, 6 twist, 7 position, 8 backlight, 9 dust
fragment float4 fsFlow4(ARGS) {
    float2 p = pos(in, u);
    float3 col = mix(C(1), C(0), smoothstep(-1.0, 1.0, p.y + 0.3 * sin(p.x * 0.6 + T * 0.05)));
    col += C(3) * 0.35 * P(8) * exp(-length((p - float2(0.5 * sin(T * 0.07), P(7))) * float2(0.5, 1.4)) * 1.8);
    int n = int(P(0));
    float w = 1.5 / u.a.y * P(4);
    float tw = sin(p.x * 0.8 * P(3) + T * 0.25) * P(6); // the bundle's spread flips sign along x, so it twists like a ribbon
    float3 acc = 0;
    for (int i = 0; i < n; i++) {
        float k = float(i) / max(n - 1, 1) - 0.5;
        float y = P(7) + P(2) * (sin(p.x * P(3) + T * 0.3 + k * 0.6) * 0.6 + sin(p.x * P(3) * 0.47 - T * 0.21 + 1.7) * 0.4)
                + k * P(1) * cos(tw + k * 2.0);
        float d = abs(p.y - y);
        float fade = 0.35 + 0.65 * (0.5 + 0.5 * sin(p.x * 1.3 + k * 9.0 + T * 0.4)); // each line breathes along its length
        acc += mix(C(2), C(3), 0.5 + 0.5 * sin(k * 6.0 + T * 0.1))
             * ((1 - smoothstep(0.0, w * 2, d)) * 0.6 + 0.0025 * P(5) / (d + 0.0025) * 0.35) * fade;
    }
    col += 1 - exp(-acc); // where the lines bunch up they glow instead of clipping
    float dust = 0;
    for (int i = 0; i < 2; i++) dust += sparkle(p * (9 + i * 8) + float2(T * 0.15, T * (0.2 + i * 0.1) + i * 5), i * 17, 0.06, RT);
    col += C(3) * dust * 0.5 * P(9);
    return finish(col, in, u);
}

// PS5-style: P: 0 density, 1 particle size, 2 layers, 3 direction, 4 wander, 5 twinkle, 6 bokeh, 7 ambient glow, 8 glow drift
fragment float4 fsDrift5(ARGS) {
    float2 p = pos(in, u);
    float3 col = C(3);
    float gt = T * P(8);
    float2 g1 = p - float2(sin(gt * 0.05) * 0.9, cos(gt * 0.04) * 0.4 - 0.2);
    float2 g2 = p - float2(cos(gt * 0.045 + 2) * 1.0, sin(gt * 0.06 + 1) * 0.5 + 0.2);
    col += (C(2) * 0.5 * exp(-dot(g1, g1) * 1.2) + C(0) * 0.12 * exp(-dot(g2, g2) * 2.0)) * P(7);
    float ang = P(3) * TAU / 360;
    float2 dir = float2(cos(ang), sin(ang));
    int n = int(P(2));
    for (int i = 0; i < n; i++) {
        float fi = i, depth = (fi + 0.5) / n; // 0 far … 1 near
        float2 q = rot(fi * 1.3) * (p * mix(16.0, 4.0, depth) * P(0) - dir * T * mix(0.15, 0.6, depth)) + fi * 19.7; // rotated per layer so the grids never line up
        float2 gv = fract(q) - 0.5;
        float h = hash21(floor(q) + fi * 7.1);
        float2 off = (float2(fract(h * 34.1), fract(h * 91.7)) - 0.5) * 0.5
                   + P(4) * 0.06 * float2(sin(T * 0.3 + h * 40), cos(T * 0.25 + h * 30)); // each particle wanders on its own loop
        float d = length(gv - off);
        float blur = saturate(abs(depth - 0.5) * 2 * P(6)); // nearest and farthest layers fall out of focus
        float rad = min((0.03 + 0.1 * blur) * P(1) * (0.5 + h), 0.13); // offset + wander + radius must stay inside the cell
        float tw = mix(1.0, 0.5 + 0.5 * sin(RT * (0.5 + h * 3) + h * 80), P(5));
        float disc = (1 - smoothstep(rad * 0.8 * blur, rad, d)) * 1.5 / (1 + blur * 3); // sharp glow in focus, dim flat disc out of it
        col += mix(C(0), C(1), step(0.75, fract(h * 9.1))) * step(0.45, h) * tw * disc * mix(0.5, 1.0, depth);
    }
    return finish(col, in, u);
}
