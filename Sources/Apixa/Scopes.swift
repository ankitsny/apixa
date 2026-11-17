import Foundation
import CoreGraphics

/// Histogram, waveform and vectorscope of the currently displayed (edited) preview.
struct Scopes: @unchecked Sendable {
    /// 256 bins each, normalized so the tallest bin of any channel is 1.
    var red: [Double]
    var green: [Double]
    var blue: [Double]
    var luma: [Double]
    var clippedHighlights: Double   // fraction with any channel at 255
    var clippedShadows: Double      // fraction with all channels at 0
    var waveform: CGImage?
    var vectorscope: CGImage?

    /// Computed from a downscaled copy (~400px wide) — cheap enough to run after every preview render.
    static func compute(_ src: CGImage) -> Scopes? {
        let scale = min(1, 520 / Double(max(src.width, src.height)))
        let w = max(1, Int(Double(src.width) * scale)), h = max(1, Int(Double(src.height) * scale))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))

        var r = [Double](repeating: 0, count: 256), g = r, b = r, l = r
        // No wider than the image (or columns would be left empty), and coarse enough that each cell gets several pixels.
        let wfW = min(256, w), wfH = 128, vsS = 320
        var wfR = [Double](repeating: 0, count: wfW * wfH), wfG = wfR, wfB = wfR
        var vs = [Double](repeating: 0, count: vsS * vsS)
        var hi = 0, lo = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let R = Int(px[i]), G = Int(px[i + 1]), B = Int(px[i + 2])
                r[R] += 1; g[G] += 1; b[B] += 1
                let Y = (2126 * R + 7152 * G + 722 * B) / 10000
                l[Y] += 1
                if R == 255 || G == 255 || B == 255 { hi += 1 }
                if R == 0 && G == 0 && B == 0 { lo += 1 }
                // Waveform: x = image column, y = level of each channel (0 at the bottom, 255 at the top).
                let wx = x * (wfW - 1) / max(1, w - 1)
                wfR[((wfH - 1) - R * (wfH - 1) / 255) * wfW + wx] += 1
                wfG[((wfH - 1) - G * (wfH - 1) / 255) * wfW + wx] += 1
                wfB[((wfH - 1) - B * (wfH - 1) / 255) * wfW + wx] += 1
                // Vectorscope: BT.709 Cb/Cr, centred.
                let cb = (-0.1146 * Double(R) - 0.3854 * Double(G) + 0.5 * Double(B)) / 255
                let cr = (0.5 * Double(R) - 0.4542 * Double(G) - 0.0458 * Double(B)) / 255
                // The scope's edge is `vectorRadius` of chroma (not the full 0.5), so ordinary photos fill it.
                let k = 0.5 / vectorRadius
                let vx = Int((cb * k + 0.5) * Double(vsS - 1)), vy = Int((0.5 - cr * k) * Double(vsS - 1))
                if vx >= 0, vx < vsS, vy >= 0, vy < vsS { vs[vy * vsS + vx] += 1 }
            }
        }
        // Ignore the extreme end bins when normalizing so a clipped sky doesn't flatten the rest.
        let peak = max(1, [r, g, b, l].map { $0[1..<255].max() ?? 1 }.max() ?? 1)
        func norm(_ a: [Double]) -> [Double] { a.map { min(1, $0 / peak) } }
        let n = Double(w * h)
        return Scopes(red: norm(r), green: norm(g), blue: norm(b), luma: norm(l),
                      clippedHighlights: Double(hi) / n, clippedShadows: Double(lo) / n,
                      waveform: rgbDensity(wfR, wfG, wfB, w: wfW, h: wfH),
                      vectorscope: hueDensity(vs, size: vsS))
    }

    /// Chroma (Cb/Cr, 0…0.5) at the vectorscope's edge.
    static let vectorRadius = 0.36

    /// Cb/Cr of an RGB colour (BT.709), for placing the vectorscope's colour targets.
    static func chroma(_ r: Double, _ g: Double, _ b: Double) -> (cb: Double, cr: Double) {
        (-0.1146 * r - 0.3854 * g + 0.5 * b, 0.5 * r - 0.4542 * g - 0.0458 * b)
    }

    /// Red, green and blue traces drawn over each other: where they overlap the trace turns white
    /// (neutral), where one leads you see its colour (a colour cast).
    private static func rgbDensity(_ r: [Double], _ g: [Double], _ b: [Double], w: Int, h: Int) -> CGImage? {
        let peak = log1p(max(r.max() ?? 1, g.max() ?? 1, b.max() ?? 1))
        guard peak > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where r[i] > 0 || g[i] > 0 || b[i] > 0 {
            func v(_ c: Double) -> Double { c > 0 ? min(1, 0.1 + 0.9 * (log1p(c) / peak)) : 0 }
            let vr = v(r[i]), vg = v(g[i]), vb = v(b[i])
            out[i * 4] = UInt8(255 * vr); out[i * 4 + 1] = UInt8(255 * vg); out[i * 4 + 2] = UInt8(255 * vb)
            out[i * 4 + 3] = UInt8(255 * max(vr, vg, vb))
        }
        return image(&out, w: w, h: h)
    }

    /// Density plot where each point is drawn in the colour it stands for.
    private static func hueDensity(_ a: [Double], size s: Int) -> CGImage? {
        let peak = log1p(a.max() ?? 1)
        guard peak > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: s * s * 4)
        let k = 0.5 / vectorRadius
        for y in 0..<s { for x in 0..<s {
            let i = y * s + x
            guard a[i] > 0 else { continue }
            let v = min(1, 0.4 + 0.6 * pow(log1p(a[i]) / peak, 0.6))
            let cb = (Double(x) / Double(s - 1) - 0.5) / k, cr = (0.5 - Double(y) / Double(s - 1)) / k
            let l = 0.62
            let r = l + 1.5748 * cr, g = l - 0.1873 * cb - 0.4681 * cr, b = l + 1.8556 * cb
            func c(_ t: Double) -> UInt8 { UInt8(255 * min(1, max(0, t)) * v) }
            out[i * 4] = c(r); out[i * 4 + 1] = c(g); out[i * 4 + 2] = c(b); out[i * 4 + 3] = UInt8(255 * v)
        } }
        return image(&out, w: s, h: s)
    }

    private static func image(_ out: inout [UInt8], w: Int, h: Int) -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    /// Log-scaled density plot as an RGBA image on a transparent background.
    private static func density(_ a: [Double], w: Int, h: Int, tint: (Double, Double, Double)) -> CGImage? {
        let peak = log1p(a.max() ?? 1)
        guard peak > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where a[i] > 0 {
            let v = log1p(a[i]) / peak
            out[i * 4] = UInt8(255 * tint.0 * v)
            out[i * 4 + 1] = UInt8(255 * tint.1 * v)
            out[i * 4 + 2] = UInt8(255 * tint.2 * v)
            out[i * 4 + 3] = UInt8(255 * min(1, 0.25 + v))
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }
}
