import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// A Sony Picture Profile recipe (what you'd dial into PP1–PP11), in the camera's own units.
///
/// Rendered from a LINEAR RAW decode (the decoder's tone curve is bypassed), then:
/// gamma + black level + black gamma + knee (per channel), then colour mode / saturation / phase /
/// colour depth (one 3D LUT), then detail. S-Log2/S-Log3 follow Sony's published formulas; Sony's
/// Still/Movie/Cine curves and colour matrices aren't public, so those are approximations.
struct PictureProfile: Codable, Hashable, Sendable {
    enum Gamma: String, Codable, CaseIterable, Identifiable, Sendable {
        case movie = "Movie", still = "Still", cine1 = "Cine1", cine2 = "Cine2", cine3 = "Cine3", cine4 = "Cine4",
             itu709 = "ITU709", itu709x800 = "ITU709(800%)", slog2 = "S-Log2", slog3 = "S-Log3", hlg = "HLG"
        var id: String { rawValue }
    }
    enum BlackGammaRange: String, Codable, CaseIterable, Identifiable, Sendable {
        case wide = "Wide", middle = "Middle", narrow = "Narrow"
        var id: String { rawValue }
        var reach: Double { self == .wide ? 0.55 : self == .middle ? 0.35 : 0.18 }
    }
    enum ColorMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case movie = "Movie", still = "Still", cinema = "Cinema", pro = "Pro", itu709Matrix = "ITU709 Matrix",
             bw = "Black & White", sGamut = "S-Gamut", sGamut3 = "S-Gamut3", sGamut3Cine = "S-Gamut3.Cine"
        var id: String { rawValue }
        /// Overall chroma relative to Movie; wide gamuts look flatter when viewed without conversion.
        var chroma: Double {
            switch self {
            case .movie, .itu709Matrix: 1
            case .still: 1.1
            case .cinema: 0.86
            case .pro: 0.95
            case .bw: 0
            case .sGamut: 0.72
            case .sGamut3: 0.76
            case .sGamut3Cine: 0.82
            }
        }
    }

    var blackLevel = 0                   // −15…+15
    var gamma = Gamma.still
    var blackGammaRange = BlackGammaRange.middle
    var blackGammaLevel = 0              // −7…+7
    var kneeAuto = true
    var kneePoint = 90.0                 // 75…105 % (manual)
    var kneeSlope = 0                    // −5…+5 (manual)
    var colorMode = ColorMode.movie
    var saturation = 0                   // −32…+32
    var colorPhase = 0                   // −7…+7
    var colorDepth = [0, 0, 0, 0, 0, 0]  // R G B C M Y, −7…+7 each
    var detail = 0                       // −7…+2

    static let depthNames = ["R", "G", "B", "C", "M", "Y"]

    var settingsLine: String {
        var p = ["\(gamma.rawValue)", "Black \(signed(blackLevel))",
                 "BG \(blackGammaRange.rawValue) \(signed(blackGammaLevel))",
                 kneeAuto ? "Knee Auto" : "Knee \(fmt(kneePoint))% \(signed(kneeSlope))",
                 colorMode.rawValue, "Sat \(signed(saturation))", "Phase \(signed(colorPhase))"]
        let d = zip(Self.depthNames, colorDepth).filter { $0.1 != 0 }.map { "\($0.0)\(signed($0.1))" }
        if !d.isEmpty { p.append("Depth " + d.joined(separator: " ")) }
        if detail != 0 { p.append("Detail \(signed(detail))") }
        return p.joined(separator: " · ")
    }

    private func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }
    private func fmt(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v) }
}

enum ProfileEngine {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let domainMax = 16.0   // scene-linear headroom fed to the tone curve

    /// `input` is scene-linear (RAW decode with the camera tone curve bypassed).
    static func apply(_ input: CIImage, _ p: PictureProfile) -> CIImage {
        let extent = input.extent
        var img = input

        // 1. Tone: per channel, scene-linear → display code value. Stored back as LINEAR values
        //    (sRGB-decoded) so Core Image's display encoding reproduces the code value exactly.
        let curve = CIFilter.colorCurves()
        curve.inputImage = img
        curve.curvesData = toneLUT(p)
        curve.curvesDomain = CIVector(x: 0, y: domainMax)
        curve.colorSpace = linearSRGB
        img = curve.outputImage ?? img

        // 2. Colour: mode, saturation, phase, per-hue depth — one 3D LUT on encoded values.
        if let cube = colorCube(p) {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = img
            f.cubeDimension = Float(cubeSize)
            f.cubeData = cube
            f.colorSpace = sRGB
            img = f.outputImage ?? img
        }

        // 3. Detail: Sony's default (0) already has some sharpening.
        let amount = max(0, 0.25 + 0.06 * Double(p.detail))
        if amount > 0 {
            let s = CIFilter.sharpenLuminance()
            s.inputImage = img.clampedToExtent()
            s.sharpness = Float(amount)
            img = s.outputImage?.cropped(to: extent) ?? img
        }
        return img.cropped(to: extent)
    }

    // MARK: Tone

    /// Display code value (0…~1.1) for scene-linear reflectance L (0.18 = mid grey).
    static func gamma(_ L: Double, _ g: PictureProfile.Gamma) -> Double {
        let x = max(0, L)
        switch g {
        case .slog3:
            let cv = x >= 0.01125 ? 420 + log10((x + 0.01) / 0.19) * 261.5 : x * (171.2102946929 - 95) / 0.01125 + 95
            return cv / 1023
        case .slog2:
            let r = x / 0.9
            let v = r >= 0 ? (0.432699 * log10(155 * r / 219 + 0.037584) + 0.616596) + 0.03 : r * 3.53881278538813 + 0.030001222851889303
            return (v * 876 + 64) / 1023
        case .itu709, .itu709x800:
            let y = x < 0.018 ? 4.5 * x : 1.099 * pow(x, 0.45) - 0.099
            return g == .itu709x800 ? min(1.09, y * 0.86) : y
        case .hlg:
            let e = x / 3.5
            return e <= 1.0 / 12 ? sqrt(3 * e) : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
        default:
            // Filmic family: exposure scale, shoulder (headroom), mid-tone contrast.
            let (scale, white, contrast): (Double, Double, Double) = {
                switch g {
                case .still: return (1.0, 3.5, 1.12)
                case .movie: return (1.0, 4.5, 1.0)
                case .cine1: return (0.95, 9, 0.92)
                case .cine2: return (0.95, 6, 0.92)
                case .cine3: return (0.97, 7, 1.05)
                case .cine4: return (0.97, 7, 1.12)
                default: return (1, 4, 1)
                }
            }()
            let v = x * scale
            // Linear through the mid-tones (18% grey ≈ 0.46 code, like a camera's Still gamma), then a
            // smooth shoulder that reaches 1.0 at `white` stops of headroom.
            let t = 0.5
            let shoulder = v <= t ? v : t + (1 - t) * (1 - exp(-(v - t) / max(0.1, (white - t) / 3)))
            let enc = shoulder <= 0.0031308 ? 12.92 * shoulder : 1.055 * pow(shoulder, 1 / 2.4) - 0.055
            // Mid-tone contrast pivot at ~0.45 code value.
            return 0.45 + (enc - 0.45) * contrast
        }
    }

    static func toneLUT(_ p: PictureProfile, n: Int = 2048) -> Data {
        var out = [Float](repeating: 0, count: n * 3)
        let bgLevel = Double(p.blackGammaLevel) / 7, reach = p.blackGammaRange.reach
        let kneeP = p.kneeAuto ? 0.88 : p.kneePoint / 100
        let kneeK = p.kneeAuto ? 0.35 : max(0.05, 0.35 + 0.06 * Double(p.kneeSlope))
        for i in 0..<n {
            let L = Double(i) / Double(n - 1) * domainMax
            var y = gamma(L, p.gamma)
            // Black gamma: lift (+) or deepen (−) the shadows within its range.
            if y < reach {
                let t = 1 - y / reach
                y += 0.06 * bgLevel * t * t * (y / reach + 0.15)
            }
            // Knee: compress highlights above the knee point (not for log/HLG, which have no knee).
            if ![.slog2, .slog3, .hlg].contains(p.gamma), y > kneeP {
                y = kneeP + (y - kneeP) * kneeK
            }
            // Black level: master pedestal.
            y += Double(p.blackLevel) * 0.0035
            y = min(1, max(0, y))
            // Store as linear so display encoding returns y.
            let lin = y <= 0.04045 ? y / 12.92 : pow((y + 0.055) / 1.055, 2.4)
            for c in 0..<3 { out[i * 3 + c] = Float(lin) }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: Colour

    static let cubeSize = 33

    static func colorCube(_ p: PictureProfile) -> Data? {
        let chroma = p.colorMode.chroma * max(0, 1 + Double(p.saturation) * 0.02)
        let phase = Double(p.colorPhase) * 1.5          // degrees per step (Sony steps are subtle)
        if chroma == 1 && phase == 0 && p.colorDepth.allSatisfy({ $0 == 0 }) { return nil }
        let n = cubeSize
        var data = [Float](repeating: 0, count: n * n * n * 4)
        // Hue centres (degrees) for R G B C M Y.
        let centres: [Double] = [0, 120, 240, 180, 300, 60]
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    var R = Double(r) / Double(n - 1), G = Double(g) / Double(n - 1), B = Double(b) / Double(n - 1)
                    var (h, s, v) = hsv(R, G, B)
                    // Colour depth: + = deeper (darker, richer) for that hue, − = lighter/thinner.
                    var d = 0.0
                    for k in 0..<6 where p.colorDepth[k] != 0 {
                        var dh = abs(h - centres[k]).truncatingRemainder(dividingBy: 360)
                        if dh > 180 { dh = 360 - dh }
                        let w = max(0, 1 - dh / 60)
                        d += w * Double(p.colorDepth[k]) / 7
                    }
                    d *= s   // neutrals unaffected
                    v *= max(0.2, 1 - 0.22 * d)
                    s = min(1, s * max(0, 1 + 0.25 * d))
                    // Phase rotates hue; colour mode + saturation scale chroma.
                    h = (h + phase + 360).truncatingRemainder(dividingBy: 360)
                    s = min(1, s * chroma)
                    (R, G, B) = rgb(h, s, v)
                    let i = ((b * n + g) * n + r) * 4
                    data[i] = Float(R); data[i + 1] = Float(G); data[i + 2] = Float(B); data[i + 3] = 1
                }
            }
        }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    private static func rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double) = switch h {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}
