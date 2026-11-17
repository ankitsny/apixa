import Foundation
import CoreImage
import ImageIO

/// Fits a look's few `LookBase` parameters so that Sony's Standard render becomes Sony's render of
/// that look (both from Imaging Edge, same RAW). A handful of parameters generalize from one photo
/// where a full colour LUT would just memorize it.
enum LookFit {
    static let names = ["exposure", "contrast", "saturation", "vibrance", "fade", "warmth",
                        "shadowR", "shadowG", "shadowB", "highR", "highG", "highB", "rolloff"]
    static let lower: [Double] = [-1, -0.6, -1, -1, 0, -0.2, -0.15, -0.15, -0.15, -0.15, -0.15, -0.15, 0]
    static let upper: [Double] = [1, 0.8, 1, 1, 0.15, 0.2, 0.15, 0.15, 0.15, 0.15, 0.15, 0.15, 0.5]
    static let steps: [Double] = [0.2, 0.2, 0.2, 0.2, 0.03, 0.04, 0.03, 0.03, 0.03, 0.03, 0.03, 0.03, 0.1]

    static func vector(_ b: LookBase) -> [Double] {
        [b.exposure, b.contrast, b.saturation, b.vibrance, b.fade, b.warmth,
         b.shadowTint.0, b.shadowTint.1, b.shadowTint.2, b.highlightTint.0, b.highlightTint.1, b.highlightTint.2, b.highlightRolloff]
    }

    static func base(_ v: [Double], mono: Bool) -> LookBase {
        LookBase(exposure: v[0], contrast: v[1], saturation: v[2], vibrance: v[3], fade: v[4], warmth: v[5],
                 shadowTint: (v[6], v[7], v[8]), highlightTint: (v[9], v[10], v[11]), highlightRolloff: v[12], mono: mono, sepia: 0)
    }

    static func load(_ u: URL, maxPixel: Int) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary)
    }

    /// Render `src` through the look with parameters `b`, as sRGB pixels.
    static func render(_ src: CIImage, _ look: CreativeLook, _ b: LookBase, w: Int, h: Int) -> [SIMD3<Float>] {
        let r = LookRecipe(name: "fit", group: "fit", base: look)
        let out = LookEngine.apply(src, r, isRaw: false, baseOverride: b)
        guard let cg = RAWDecoder.context.createCGImage(out, from: src.extent, format: .RGBA8,
                                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return [] }
        return LookCalibration.pixels(cg, w: w, h: h)
    }

    struct Result { var params: LookBase; var eStart: Double; var eFit: Double; var eTestStart: Double; var eTestFit: Double }

    /// One reference scene: Sony's Standard render as input, Sony's look render as target.
    struct Scene {
        let src: CIImage, tgt: [SIMD3<Float>], idx: [Int], w: Int, h: Int
        init(st: CGImage, target: CGImage) {
            w = st.width; h = st.height
            src = CIImage(cgImage: st)
            tgt = LookCalibration.pixels(target, w: w, h: h)
            let p = LookCalibration.pixels(st, w: w, h: h)
            var idx: [Int] = []
            for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                let i = y * w + x
                let dx: SIMD3<Float> = p[i + 1] - p[i - 1], dy: SIMD3<Float> = p[i + w] - p[i - w]
                let g: Float = max(abs(dx.x), abs(dx.y), abs(dx.z)) + max(abs(dy.x), abs(dy.y), abs(dy.z))
                if g < 0.12 { idx.append(i) }   // skip edges (tiny misalignment)
            } }
            self.idx = idx
        }
    }

    static func error(_ v: [Double], _ look: CreativeLook, _ scenes: [Scene]) -> Double {
        let b = base(v, mono: look.base.mono)
        var e = 0.0
        for s in scenes {
            let px = render(s.src, look, b, w: s.w, h: s.h)
            guard !px.isEmpty else { return .infinity }
            e += LookCalibration.deltaE(s.idx.map { px[$0] }, s.idx.map { s.tgt[$0] })
        }
        return e / Double(max(1, scenes.count))
    }

    /// Coordinate descent on mean ΔE across scenes, starting from `start`.
    static func descend(_ start: [Double], _ look: CreativeLook, _ scenes: [Scene]) -> [Double] {
        let mono = look.base.mono
        var v = start, step = steps, best = error(v, look, scenes)
        let active = (0..<v.count).filter { !(mono && ($0 == 2 || $0 == 3)) }
        for _ in 0..<30 {
            var improved = false
            for k in active {
                for dir in [1.0, -1.0] {
                    var t = v; t[k] = min(upper[k], max(lower[k], v[k] + dir * step[k]))
                    let e = error(t, look, scenes)
                    if e < best - 1e-4 { best = e; v = t; improved = true; break }
                }
            }
            if !improved { step = step.map { $0 / 2 }; if step[0] < 0.005 { break } }
        }
        return v
    }

    static func startVector(_ look: CreativeLook) -> [Double] {
        var v = vector(look.base)
        if look == .SE { v[4] = 0 }   // Sony's sepia is red-brown: expressed as tints on mono, not CISepiaTone
        return v
    }

    /// Fit on all scenes; with 2+ scenes, also leave-one-scene-out (fit on the others, score the one left out).
    static func fit(look: CreativeLook, scenes: [Scene]) -> Result {
        let start = startVector(look)
        var testStart = 0.0, testFit = 0.0
        if scenes.count >= 2 {
            for k in scenes.indices {
                let rest = scenes.enumerated().filter { $0.offset != k }.map(\.element)
                let v = descend(start, look, rest)
                testStart += error(start, look, [scenes[k]]); testFit += error(v, look, [scenes[k]])
            }
            testStart /= Double(scenes.count); testFit /= Double(scenes.count)
        }
        let v = descend(start, look, scenes)
        return Result(params: base(v, mono: look.base.mono), eStart: error(start, look, scenes), eFit: error(v, look, scenes),
                      eTestStart: testStart, eTestFit: testFit)
    }
}
