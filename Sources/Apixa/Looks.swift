import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Sony's in-camera Creative Looks. Sony's exact processing is proprietary; these are Apixa's
/// approximations of each look's published character, built from the same controls the camera exposes.
enum CreativeLook: String, Codable, CaseIterable, Identifiable, Sendable {
    case ST, PT, NT, VV, VV2, FL, FL2, FL3, IN, SH, BW, SE
    var id: String { rawValue }

    /// FL2 / FL3 exist on newer bodies (α7R VI, RX10 V help guides; reportedly α7 V).
    var isNewer: Bool { self == .FL2 || self == .FL3 }
    var isMono: Bool { self == .BW || self == .SE }

    var title: String {
        switch self {
        case .ST: "Standard"
        case .PT: "Portrait"
        case .NT: "Neutral"
        case .VV: "Vivid"
        case .VV2: "Vivid 2"
        case .FL: "Film"
        case .FL2: "Film 2"
        case .FL3: "Film 3"
        case .IN: "Instant"
        case .SH: "Soft High-key"
        case .BW: "Black & White"
        case .SE: "Sepia"
        }
    }

    /// Sony's own one-line descriptions (Help Guide, "Creative Look").
    var summary: String {
        switch self {
        case .ST: "Standard finish for a wide range of subjects and scenes."
        case .PT: "Skin in a soft tone, ideally suited for portraits."
        case .NT: "Saturation and sharpness lowered for subdued tones; good for later editing."
        case .VV: "Saturation and contrast heightened for colourful scenes, greenery, sky and sea."
        case .VV2: "Bright and vivid colours with rich clarity."
        case .FL: "Moody finish: sharp contrast on calm colouring, impressive sky and greens."
        case .FL2: "A nostalgic look through high-contrast, calm colouring."
        case .FL3: "A lighthearted look: clear colouring with slightly suppressed contrast."
        case .IN: "Matte textures from suppressed contrast and saturation."
        case .SH: "Bright, transparent, soft and vivid mood."
        case .BW: "Black-and-white monotone."
        case .SE: "Sepia monotone."
        }
    }

    /// The look's built-in character expressed on the camera's slider scales. On the camera these are
    /// invisible (every look starts at 0); Apixa shows them so you can see what a look does.
    var isLearned: Bool { LookCalibration.lut(self) != nil || LookCalibration.table("\(rawValue).rel") != nil }
    var baseContrast: Int { isLearned ? 0 : Int((base.contrast / 0.035).rounded()) }
    var baseSaturation: Int { isLearned || isMono ? 0 : Int((base.saturation / 0.055).rounded()) }
    var baseFade: Int { isLearned ? 0 : Int((base.fade / 0.012).rounded()) }
    var baseHighlights: Int { isLearned ? 0 : Int((-base.highlightRolloff / 0.04).rounded()) }

    /// The look's own character in Apixa's terms (applied before the recipe's Sony-style settings).
    /// Looks whose parameters are a change from Standard (fitted to Sony's ST → look renders, or hand-tuned),
    /// as opposed to fitted directly from Apixa's neutral render to the camera's JPEGs.
    var relativeToStandard: Bool { ![.PT, .NT, .VV, .VV2, .FL, .SE].contains(self) }

    var base: LookBase {
        switch self {
        case .ST: LookBase()
        // Fitted to camera JPEGs.
        case .PT: LookBase(exposure: -0.081, contrast: -0.07, saturation: -0.1, vibrance: -0.138, fade: 0.004, warmth: -0.011,
                           shadowTint: (-0.004, -0.006, -0.002), highlightTint: (0.031, 0.012, 0.007), highlightRolloff: 0.003)
        // Fitted to camera JPEGs.
        case .NT: LookBase(exposure: -0.125, contrast: -0.013, saturation: -0.225, vibrance: -0.087, fade: 0.007, warmth: 0.003,
                           shadowTint: (0.002, 0.002, -0.002), highlightTint: (0.032, 0.034, 0.034), highlightRolloff: 0)
        // Fitted to camera JPEGs.
        case .VV: LookBase(exposure: -0.106, contrast: 0.027, saturation: 0.019, vibrance: -0.195, fade: 0, warmth: -0.002,
                           shadowTint: (-0.023, -0.019, -0.016), highlightTint: (0.024, 0.026, 0.024), highlightRolloff: 0)
        // Fitted to camera JPEGs.
        case .VV2: LookBase(exposure: 0.645, contrast: -0.045, saturation: -0.105, vibrance: -0.038, fade: 0.002, warmth: 0.032,
                           shadowTint: (-0.021, -0.019, -0.017), highlightTint: (-0.044, -0.02, -0.002), highlightRolloff: 0.5)
        // Fitted to camera JPEGs.
        case .FL: LookBase(exposure: 0.556, contrast: 0.262, saturation: -0.255, vibrance: -0.306, fade: 0.015, warmth: 0.007,
                           shadowTint: (-0.001, 0.013, 0.007), highlightTint: (-0.036, -0.023, -0.03), highlightRolloff: 0.353)
        case .FL2: LookBase(contrast: 0.24, saturation: -0.32, fade: 0.015, warmth: 0.035,
                            shadowTint: (0.01, 0.005, -0.01), highlightTint: (0.03, 0.02, -0.02), highlightRolloff: 0.05)
        case .FL3: LookBase(exposure: 0.06, contrast: -0.1, saturation: 0.04, vibrance: 0.12,
                            shadowTint: (-0.01, 0.005, 0.02), highlightTint: (0, 0.005, 0.01))
        // Fitted to Sony Imaging Edge renders.
        case .IN: LookBase(exposure: 0.575, contrast: 0.025, saturation: -0.013, vibrance: -0.406, fade: 0.092, warmth: 0.016,
                           shadowTint: (-0.009, -0.007, 0.001), highlightTint: (-0.052, -0.029, -0.019), highlightRolloff: 0.494)
        // Fitted to Sony Imaging Edge renders.
        case .SH: LookBase(exposure: 0.762, contrast: -0.325, saturation: 0.1, vibrance: 0.125, fade: 0.15, warmth: 0.05,
                           shadowTint: (-0.056, -0.036, -0.017), highlightTint: (0.003, 0.034, 0.049), highlightRolloff: 0.5)
        // Fitted to Sony Imaging Edge renders.
        case .BW: LookBase(exposure: -0.15, contrast: 0.244, saturation: 0, vibrance: 0, fade: 0.03, warmth: 0,
                           shadowTint: (0, 0, 0), highlightTint: (0, 0, 0), highlightRolloff: 0, mono: true)
        // Fitted to camera JPEGs.
        case .SE: LookBase(exposure: -0.05, contrast: -0.057, saturation: 0, vibrance: 0, fade: 0, warmth: 0.069,
                           shadowTint: (0.067, -0.101, -0.149), highlightTint: (0.15, -0.004, -0.064), highlightRolloff: 0.166, mono: true)
        }
    }
}

struct LookBase: Sendable {
    var exposure = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var vibrance = 0.0
    var fade = 0.0                       // black lift (0…0.15)
    var warmth = 0.0                     // red+ / blue− balance
    var shadowTint: (Double, Double, Double) = (0, 0, 0)
    var highlightTint: (Double, Double, Double) = (0, 0, 0)
    var highlightRolloff = 0.0
    var mono = false
    var sepia = 0.0
}

/// A Creative Look recipe in Sony's own terms (what you'd dial into the camera).
struct LookRecipe: Codable, Hashable, Identifiable, Sendable {
    var id: String { group + "/" + name }
    var name: String
    var group: String                    // "Sony Creative Looks", "My Looks", …
    var base: CreativeLook
    // Sony's scales: Contrast/Highlights/Shadows/Saturation −9…+9, Fade 0…9, Sharpness 0…9,
    // Sharpness Range 1…5, Clarity 0…9.
    var contrast = 0, highlights = 0, shadows = 0, fade = 0, saturation = 0, sharpness = 0, clarity = 0
    var sharpnessRange = 3
    var wb = WhiteBalance.auto           // Sony WB mode
    var kelvin: Int? = nil               // only for .colorTemp
    var shiftAB = 0.0                    // +Amber / −Blue steps (−7…7, 0.25 steps on newer bodies)
    var shiftGM = 0.0                    // +Magenta / −Green steps (−7…7)
    /// A Picture Profile recipe; when set, it replaces the Creative Look settings.
    var profile: PictureProfile? = nil
    var dro = 0                          // 0 = off, 1…5 = Lv1…Lv5
    var notes: String? = nil
    var credit: String? = nil            // photographer / source
    /// An Apple photo filter (Core Image name, e.g. "CIPhotoEffectChrome") used instead of a Creative Look.
    var appleFilter: String? = nil

    /// Kelvin the decoder should use, or nil for as-shot (AWB).
    var effectiveKelvin: Int? { wb == .colorTemp ? (kelvin ?? 5500) : wb.kelvin }

    init(name: String, group: String, base: CreativeLook, contrast: Int = 0, highlights: Int = 0, shadows: Int = 0,
         fade: Int = 0, saturation: Int = 0, sharpness: Int = 0, sharpnessRange: Int = 3, clarity: Int = 0,
         wb: WhiteBalance = .auto, kelvin: Int? = nil, shiftAB: Double = 0, shiftGM: Double = 0, dro: Int = 0,
         notes: String? = nil, credit: String? = nil, profile: PictureProfile? = nil, appleFilter: String? = nil) {
        self.appleFilter = appleFilter
        self.name = name; self.group = group; self.base = base
        self.contrast = contrast; self.highlights = highlights; self.shadows = shadows; self.fade = fade
        self.saturation = saturation; self.sharpness = sharpness; self.sharpnessRange = sharpnessRange; self.clarity = clarity
        self.wb = wb; self.kelvin = kelvin; self.shiftAB = shiftAB; self.shiftGM = shiftGM; self.dro = dro
        self.notes = notes; self.credit = credit; self.profile = profile
    }

    // Tolerant decoding so saved looks survive model changes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func i(_ k: CodingKeys, _ d: Int = 0) -> Int { (try? c.decodeIfPresent(Int.self, forKey: k)) ?? d }
        name = (try? c.decode(String.self, forKey: .name)) ?? "Look"
        group = (try? c.decode(String.self, forKey: .group)) ?? "My Looks"
        base = (try? c.decode(CreativeLook.self, forKey: .base)) ?? .ST
        contrast = i(.contrast); highlights = i(.highlights); shadows = i(.shadows); fade = i(.fade)
        saturation = i(.saturation); sharpness = i(.sharpness); sharpnessRange = i(.sharpnessRange, 3); clarity = i(.clarity)
        kelvin = try? c.decodeIfPresent(Int.self, forKey: .kelvin)
        wb = (try? c.decodeIfPresent(WhiteBalance.self, forKey: .wb)) ?? (kelvin != nil ? .colorTemp : .auto)
        shiftAB = (try? c.decodeIfPresent(Double.self, forKey: .shiftAB)) ?? 0
        shiftGM = (try? c.decodeIfPresent(Double.self, forKey: .shiftGM)) ?? 0
        dro = i(.dro)
        profile = try? c.decodeIfPresent(PictureProfile.self, forKey: .profile)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        credit = try? c.decodeIfPresent(String.self, forKey: .credit)
        appleFilter = try? c.decodeIfPresent(String.self, forKey: .appleFilter)
    }

    static let presets: [LookRecipe] = CreativeLook.allCases.map {
        LookRecipe(name: "\($0.rawValue) · \($0.title)", group: "Sony Creative Looks", base: $0,
                   notes: $0.summary + ($0.isNewer ? " (newer bodies)" : ""))
    }

    /// Recipes Sony publishes on its Alpha Recipes site (settings as shown on the site).
    static let sonyAlphaRecipes: [LookRecipe] = [
        LookRecipe(name: "Jonpoon", group: "Sony Alpha Recipes", base: .VV2, contrast: 1, highlights: 1, shadows: 2,
                   fade: 1, saturation: 0, sharpness: 4, sharpnessRange: 4, clarity: 8, wb: .auto, shiftAB: 1, shiftGM: -1,
                   credit: "Jonpoon, Singapore — Sony Alpha Recipes"),
    ]

    /// Apple's own photo filters (the ones Core Image offers to every app). They are applied to the
    /// developed photo, and the look's sliders still work on top.
    static let appleFilters: [LookRecipe] = [
        ("Chrome", "CIPhotoEffectChrome", "Punchy colour with a little extra contrast."),
        ("Fade", "CIPhotoEffectFade", "Soft, low-contrast colour."),
        ("Instant", "CIPhotoEffectInstant", "Warm, faded instant-film colour."),
        ("Process", "CIPhotoEffectProcess", "Cool, cross-processed colour."),
        ("Transfer", "CIPhotoEffectTransfer", "Warm, vintage colour."),
        ("Mono", "CIPhotoEffectMono", "Plain black and white."),
        ("Tonal", "CIPhotoEffectTonal", "Black and white with smooth, gentle tones."),
        ("Noir", "CIPhotoEffectNoir", "High-contrast black and white."),
    ].map { LookRecipe(name: $0.0, group: "Apple Photo Filters", base: .ST, notes: $0.2, appleFilter: $0.1) }

    static let builtIn: [LookRecipe] = presets + sonyAlphaRecipes + appleFilters

    /// Totals (look character + recipe), what the sliders show.
    var totalContrast: Int { base.baseContrast + contrast }
    var totalSaturation: Int { base.baseSaturation + saturation }
    var totalFade: Int { base.baseFade + fade }
    var totalHighlights: Int { base.baseHighlights + highlights }

    var isProfile: Bool { profile != nil }

    /// Settings summary like the camera shows them (offsets on the look).
    private func fmtShift(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%g", v) }

    var settingsLine: String {
        let shift = [shiftAB != 0 ? "\(shiftAB > 0 ? "A" : "B")\(fmtShift(abs(shiftAB)))" : nil,
                     shiftGM != 0 ? "\(shiftGM > 0 ? "M" : "G")\(fmtShift(abs(shiftGM)))" : nil].compactMap { $0 }.joined(separator: "-")
        if let p = profile {
            let wbs = wb == .colorTemp ? "\(kelvin ?? 5500)K" : wb.short
            return p.settingsLine + " · " + wbs + (shift.isEmpty ? "" : " \(shift)")
        }
        var parts = [appleFilter != nil ? "Apple filter" : base.rawValue]
        for (k, v) in [("Contrast", contrast), ("Highlights", highlights), ("Shadows", shadows), ("Fade", fade),
                       ("Saturation", saturation), ("Sharpness", sharpness), ("Clarity", clarity)] where v != 0 {
            let signed = ["Contrast", "Highlights", "Shadows", "Saturation"].contains(k)
            parts.append("\(k) \(v > 0 && signed ? "+" : "")\(v)")
        }
        if sharpness != 0 && sharpnessRange != 3 { parts.append("Range \(sharpnessRange)") }
        parts.append(wb == .colorTemp ? "WB \(kelvin ?? 5500)K" : "WB \(wb.short)")
        if !shift.isEmpty { parts.append("Shift " + shift) }
        if dro > 0 { parts.append("DRO Lv\(dro)") }
        return parts.joined(separator: " · ")
    }
}

/// Applying a recipe. White balance and DRO are decoder settings for RAWs (see `Develop`); everything
/// else is the look stage, applied after the user's own edits and before crop.
enum LookEngine {
    /// Absolute white balance for the RAW decoder: recipe Kelvin (or as-shot) with A–B / G–M shifts.
    /// One shift step ≈ 5 mired, like Sony's WB fine-tune grid.
    static func whiteBalance(_ r: LookRecipe, asShotK: Double, asShotTint: Double) -> (k: Double, tint: Double) {
        let k = Double(r.effectiveKelvin ?? Int(asShotK))
        let mired = 1_000_000 / max(1000, k) - r.shiftAB * 5
        return (1_000_000 / max(20, mired), asShotTint + r.shiftGM * 6)
    }

    static func needsDecoder(_ r: LookRecipe) -> Bool { r.effectiveKelvin != nil || r.shiftAB != 0 || r.shiftGM != 0 || r.dro != 0 }

    /// For non-RAW sources: approximate the WB shift as a relative white-point move.
    static func approximateWB(_ img: CIImage, _ r: LookRecipe) -> CIImage {
        guard r.shiftAB != 0 || r.shiftGM != 0 else { return img }
        let f = CIFilter.temperatureAndTint()
        f.inputImage = img
        f.neutral = CIVector(x: 6500, y: 0)
        f.targetNeutral = CIVector(x: 6500 - r.shiftAB * 180, y: -r.shiftGM * 6)
        return f.outputImage ?? img
    }

    static func apply(_ input: CIImage, _ r: LookRecipe, isRaw: Bool, baseOverride: LookBase? = nil) -> CIImage {
        var b = baseOverride ?? r.base.base
        var img = isRaw ? input : approximateWB(input, r)
        let extent = input.extent

        // Learned from the camera's own JPEGs (Settings ▸ Calibrate Looks): use it as the look itself.
        // Otherwise start from the learned Standard rendering (Sony's base) and add the hand-tuned character.
        // Learned from Sony's own renders (Standard → look): the closest match, applied to Apixa's Standard.
        if baseOverride == nil, let name = r.appleFilter, let f = CIFilter(name: name) {
            f.setValue(img, forKey: kCIInputImageKey)
            img = f.outputImage?.cropped(to: extent) ?? img
            b = LookBase()
        } else if baseOverride == nil, r.base != .ST, let rel = LookCalibration.table("\(r.base.rawValue).rel") {
            img = LookCalibration.apply(img, lut: rel)
            b = LookBase()
        } else if baseOverride != nil {
            // Explicit parameters (fitting / comparisons): no learned tables.
        } else if let lut = LookCalibration.lut(r.base) {
            img = LookCalibration.apply(img, lut: lut)
            b = LookBase()
        } else if r.base.relativeToStandard, let st = LookCalibration.lut(.ST) {
            img = LookCalibration.apply(img, lut: st)
        }

        if b.exposure != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(b.exposure); img = f.outputImage ?? img
        }
        // Clarity: large-radius local contrast.
        if r.clarity > 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = img.clampedToExtent()
            f.radius = Float(max(extent.width, extent.height) / 80)
            f.intensity = Float(r.clarity) * 0.05
            img = f.outputImage?.cropped(to: extent) ?? img
        }
        // Saturation (look base + recipe). Contrast lives in the tone curve, pivoting at mid-grey,
        // so it doesn't change overall brightness.
        let saturation = b.mono ? 0 : max(0, 1 + b.saturation + Double(r.saturation) * 0.055)   // Sony: no saturation for BW/SE
        if saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.saturation = Float(saturation)
            img = f.outputImage ?? img
        }
        if b.vibrance != 0 && !b.mono {
            let f = CIFilter.vibrance(); f.inputImage = img; f.amount = Float(b.vibrance); img = f.outputImage ?? img
        }
        // Tone + tint curves in one LUT.
        let f = CIFilter.colorCurves()
        f.inputImage = img
        f.curvesData = lut(r, b)
        f.curvesDomain = CIVector(x: 0, y: 1)
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        img = f.outputImage ?? img
        if b.sepia > 0 {
            let s = CIFilter.sepiaTone(); s.inputImage = img; s.intensity = Float(b.sepia); img = s.outputImage ?? img
        }
        if r.sharpness > 0 {
            // Sharpness Range 1 (fine detail) … 5 (broad edges) sets the sharpening radius.
            let s = CIFilter.sharpenLuminance()
            s.inputImage = img.clampedToExtent()
            s.sharpness = Float(r.sharpness) * 0.06
            s.radius = Float(0.8 + 0.6 * Double(min(5, max(1, r.sharpnessRange)) - 1))
            img = s.outputImage?.cropped(to: extent) ?? img
        }
        return img.cropped(to: extent)
    }

    /// Highlights / Shadows / Fade (Sony scales) + the look's tints, as per-channel curves.
    private static func lut(_ r: LookRecipe, _ b: LookBase, n: Int = 512) -> Data {
        var out = [Float](repeating: 0, count: n * 3)
        let hi = Double(r.highlights) / 9, sh = Double(r.shadows) / 9
        let fade = b.fade + Double(r.fade) * 0.012
        let contrast = max(0.3, 1 + b.contrast + Double(r.contrast) * 0.035)
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            var y = ToneMath.contrast(x, contrast)
            y += 0.18 * hi * exp(-pow((x - 0.78) / 0.16, 2))
            y += 0.18 * sh * exp(-pow((x - 0.22) / 0.16, 2))
            if b.highlightRolloff > 0 { y -= b.highlightRolloff * 0.25 * pow(max(0, x - 0.7) / 0.3, 2) * (1 - x * 0.3) }
            y = fade + y * (1 - fade)
            y = min(1, max(0, y))
            let sw = pow(1 - y, 2), hw = pow(y, 2)
            let warm = b.warmth
            let rr = y + b.shadowTint.0 * sw + b.highlightTint.0 * hw + warm * 0.5 * (1 - abs(2 * y - 1))
            let gg = y + b.shadowTint.1 * sw + b.highlightTint.1 * hw
            let bb = y + b.shadowTint.2 * sw + b.highlightTint.2 * hw - warm * 0.5 * (1 - abs(2 * y - 1))
            out[i * 3] = Float(min(1, max(0, rr)))
            out[i * 3 + 1] = Float(min(1, max(0, gg)))
            out[i * 3 + 2] = Float(min(1, max(0, bb)))
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Sony's white balance modes (approximate colour temperatures for the presets).
enum WhiteBalance: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "AWB", daylight = "Daylight", shade = "Shade", cloudy = "Cloudy", incandescent = "Incandescent",
         fluorWarm = "Fluor. Warm White", fluorCool = "Fluor. Cool White", fluorDay = "Fluor. Day White",
         fluorDaylight = "Fluor. Daylight", flash = "Flash", colorTemp = "C.Temp"
    var id: String { rawValue }
    var short: String { self == .auto ? "AWB" : rawValue }

    var kelvin: Int? {
        switch self {
        case .auto, .colorTemp: nil
        case .daylight: 5500
        case .shade: 7500
        case .cloudy: 6500
        case .incandescent: 3200
        case .fluorWarm: 3000
        case .fluorCool: 4000
        case .fluorDay: 5000
        case .fluorDaylight: 6500
        case .flash: 5500
        }
    }
}

enum ToneMath {
    /// sRGB code value of 18% grey — the pivot photographers expect contrast to turn around.
    static let midGrey = 0.4614

    /// Contrast as a smooth S-curve around mid-grey on encoded values: black stays black, white stays
    /// white, mid-grey stays put, so overall brightness doesn't drift.
    static func contrast(_ x: Double, _ k: Double) -> Double {
        guard k != 1 else { return x }
        let p = midGrey
        // Power curves on each side of the pivot (gamma < 1 lifts, > 1 deepens), mirrored for highlights.
        if x <= p {
            return p * pow(x / p, k)
        } else {
            return 1 - (1 - p) * pow((1 - x) / (1 - p), k)
        }
    }

    /// Per-channel LUT for `CIColorCurves` applying `contrast` only.
    static func contrastLUT(_ k: Double, n: Int = 512) -> Data {
        var out = [Float](repeating: 0, count: n * 3)
        for i in 0..<n {
            let y = Float(contrast(Double(i) / Double(n - 1), k))
            out[i * 3] = y; out[i * 3 + 1] = y; out[i * 3 + 2] = y
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
